---In-process parallel HTTP via LuaJIT FFI + libcurl (multi interface).
---
---Bypasses Millennium's blocking parent-RPC http path entirely: requests run
---inside the plugin's lua-host process, many at once, driven by one
---curl_multi pump loop. This is what turns provider latency from "sum of
---all round-trips" into "slowest single provider".
---
---Two entry points:
---  * session()  — persistent pump session (used by the coordinator). A
---    session survives across IPC route calls: transfers left in flight when
---    a call's budget expires keep their curl state and resume on the next
---    pump. Request ids are caller-tagged; completed results are drained
---    with take_completed().
---  * fetch_all() — one-shot batch (used by tests / simple callers).
---
---Design notes / invariants:
---  * All C interaction happens on the Lua thread that pumps; LuaJIT FFI
---    callbacks are only safe on the owning thread, and the pump never
---    yields to other Lua code mid-transfer.
---  * Every easy handle, body buffer and slist stays referenced from the
---    transfer table until curl is done with it (GC safety).
---  * Callers must pcall-guard availability: if FFI or libcurl cannot load,
---    available() returns false and the plugin falls back to the legacy
---    serial RPC path.
local ffi = require("ffi")

local M = {}

local C = {} -- curl library bindings, filled by ensure_loaded()
local load_error = nil
local loaded = false

-- ---------------------------------------------------------------------------
-- libcurl loader
-- ---------------------------------------------------------------------------

---Steam roots the child may inherit (Steam runs inside pressure-vessel; the
---system /usr may be invisible but Steam's own runtime is always mounted).
local function steam_roots()
    local roots = {}
    local function add(p)
        if p and p ~= "" then
            for _, r in ipairs(roots) do
                if r == p then return end
            end
            roots[#roots + 1] = p
        end
    end
    add(os.getenv("STEAM_PATH"))
    add(os.getenv("STEAMROOT"))
    local home = os.getenv("HOME") or ""
    add(home .. "/.local/share/Steam")
    add(home .. "/.steam/root")
    return roots
end

---Candidate library names/paths. Short dlopen names first, then absolute
---host paths, then Steam-runtime paths (always mounted in the sandbox).
local CANDIDATES = {
    "curl",            -- LuaJIT adds lib/.so on Linux
    "libcurl.so.4",
    "libcurl.so",
    "/usr/lib/libcurl.so.4",
    "/usr/lib/libcurl.so",
    "/usr/lib64/libcurl.so.4",
    "/lib/x86_64-linux-gnu/libcurl.so.4",
    "/lib/libcurl.so.4",
}

for _, root in ipairs(steam_roots()) do
    CANDIDATES[#CANDIDATES + 1] =
        root .. "/steamapps/common/SteamLinuxRuntime/var/steam-runtime/pinned_libs_64/libcurl.so.4"
    CANDIDATES[#CANDIDATES + 1] =
        root .. "/steamapps/common/SteamLinuxRuntime/var/steam-runtime/usr/lib/x86_64-linux-gnu/libcurl.so.4"
    CANDIDATES[#CANDIDATES + 1] =
        root .. "/ubuntu12_64/steam-runtime/pinned_libs_64/libcurl.so.4"
    CANDIDATES[#CANDIDATES + 1] =
        root .. "/steamapps/common/SteamLinuxRuntime_sniper/files/lib/x86_64-linux-gnu/libcurl.so.4"
end

local CURLDEF = [[
    const char *curl_version(void);

    typedef void CURL;
    typedef void CURLM;
    typedef int CURLcode;
    typedef int CURLMcode;
    typedef int CURLoption;
    typedef int64_t curl_off_t;

    CURL *curl_easy_init(void);
    CURLcode curl_easy_setopt(CURL *handle, CURLoption option, ...);
    CURLcode curl_easy_perform(CURL *handle);
    void curl_easy_cleanup(CURL *handle);
    CURLcode curl_easy_getinfo(CURL *handle, int info, ...);
    const char *curl_easy_strerror(CURLcode code);

    struct curl_slist {
        char *data;
        struct curl_slist *next;
    };
    struct curl_slist *curl_slist_append(struct curl_slist *list, const char *value);
    void curl_slist_free_all(struct curl_slist *list);

    CURLM *curl_multi_init(void);
    CURLMcode curl_multi_add_handle(CURLM *multi_handle, CURL *easy_handle);
    CURLMcode curl_multi_remove_handle(CURLM *multi_handle, CURL *easy_handle);
    CURLMcode curl_multi_perform(CURLM *multi_handle, int *running_handles);
    CURLMcode curl_multi_cleanup(CURLM *multi_handle);
    const char *curl_multi_strerror(CURLMcode code);

    struct curl_waitfd {
        int fd;
        short events;
        short revents;
    };
    CURLMcode curl_multi_poll(CURLM *multi_handle,
                              struct curl_waitfd extra_fds[],
                              unsigned int extra_nfds,
                              int timeout_ms,
                              int *numfds);

    typedef enum {
        CURLMSG_NONE = 0,
        CURLMSG_DONE = 1,
        CURLMSG_LAST = 2
    } CURLMSG;

    typedef struct {
        CURLMSG msg;
        CURL *easy_handle;
        union {
            void *whatever;
            CURLcode result;
        } data;
    } CURLMsg;

    CURLMsg *curl_multi_info_read(CURLM *multi_handle, int *msgs_in_queue);

    int clock_gettime(int clk_id, void *tp);
]]

function M.available()
    return loaded
end

function M.load_error()
    return load_error
end

function M.version()
    if loaded then
        return ffi.string(C.curl_version())
    end
    return nil
end

local function ensure_loaded()
    if loaded then
        return true
    end
    if load_error then
        return false, load_error
    end

    local lib, err
    for _, name in ipairs(CANDIDATES) do
        local ok, res = pcall(ffi.load, name)
        if ok and res then
            lib = res
            break
        end
        err = res
    end

    if not lib then
        load_error = "libcurl load failed: " .. tostring(err)
        return false, load_error
    end

    local ok_cdef, cdef_err = pcall(ffi.cdef, CURLDEF)
    if not ok_cdef then
        load_error = "curl cdef failed: " .. tostring(cdef_err)
        return false, load_error
    end

    C = lib
    loaded = true
    return true
end

-- ---------------------------------------------------------------------------
-- Shared callbacks (module-lifetime — never GC'd while in use)
-- ---------------------------------------------------------------------------

---LuaJIT's tonumber() returns nil for pointer cdata — convert explicitly.
local function pkey(p)
    return tonumber(ffi.cast("intptr_t", p))
end

---registry[pkey(easy)] = transfer table
local registry = {}

local write_cb, header_cb

---Per-function JIT off for FFI callback bodies. LuaJIT's JIT compiler can
---panic "bad callback" when GC runs during a compiled callback trampoline
---under allocation pressure (verified: fires with standalone luajit's
---default-on JIT; never fires interpreted). Millennium's lua-host disables
---the engine by default, but a co-tenant plugin enabling jit.on() must not
---be able to crash this module — so the callbacks are pinned interpreted.
local function pin_interpreted(fn)
    local ok, j = pcall(require, "jit")
    if ok and type(j) == "table" and type(j.off) == "function" then
        pcall(j.off, fn, true)
    end
end

local function ensure_callbacks()
    if write_cb then
        return
    end
    local write_fn = function(ptr, size, nmemb, ud)
        local t = registry[pkey(ud)]
        local n = size * nmemb
        if t and n > 0 then
            t.buf[#t.buf + 1] = ffi.string(ptr, n)
        end
        return n
    end
    local header_fn = function(ptr, size, nmemb, ud)
        local t = registry[pkey(ud)]
        local n = size * nmemb
        if t and n > 0 then
            local line = ffi.string(ptr, n)
            -- A status line starts a new header block (redirects fold
            -- several blocks into one callback stream).
            if line:sub(1, 5) == "HTTP/" then
                t.hdrs = {}
            elseif line:find(":") then
                local k, v = line:match("^([^:]+):%s*(.-)\r?\n?$")
                if k then
                    t.hdrs[k:lower()] = v
                end
            end
        end
        return n
    end
    pin_interpreted(write_fn)
    pin_interpreted(header_fn)
    write_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)", write_fn)
    header_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)", header_fn)
    -- Anchor the callback cdata in the module table: LuaJIT invalidates a
    -- function->C-pointer cast once its cdata is GC'd ("bad callback"
    -- panic if curl invokes it afterwards). Module-lifetime storage makes
    -- that impossible.
    M._callbacks = { write = write_cb, header = header_cb, write_fn = write_fn, header_fn = header_fn }
end

-- ---------------------------------------------------------------------------
-- CURLoption / CURLINFO constants (stable curl.h values)
-- ---------------------------------------------------------------------------

local CO = {
    WRITEDATA          = 10001,
    URL                = 10002,
    POSTFIELDS         = 10015,
    REFERER            = 10016,
    USERAGENT          = 10018,
    HTTPHEADER         = 10023,
    CUSTOMREQUEST      = 10036,
    ACCEPT_ENCODING    = 10102,
    WRITEFUNCTION      = 20011,
    HEADERFUNCTION     = 20079,
    HEADERDATA         = 10029,
    POST               = 47,
    FOLLOWLOCATION     = 52,
    POSTFIELDSIZE      = 60,
    SSL_VERIFYPEER     = 64,
    SSL_VERIFYHOST     = 81,
    NOSIGNAL           = 99,
    TIMEOUT_MS         = 155,
    CONNECTTIMEOUT_MS  = 156,
    VERBOSE            = 41,
}
local CURL_VERBOSE = os.getenv("MILL_CURL_VERBOSE") ~= nil
local CURLINFO_RESPONSE_CODE = 0x200002
local CURLMSG_DONE = 1

---Monotonic wall clock (canonical void* signature — typed timespec
---redeclarations conflict in ffi.C; long[2] = {tv_sec, tv_nsec} on LP64 and
---ILP32, tonumber because long[] elements are int64 cdata).
local wall_now
do
    local ok_cdef = pcall(ffi.cdef, "int clock_gettime(int clk_id, void *tp);")
    if ok_cdef then
        local ts = ffi.new("long[2]")
        wall_now = function()
            ffi.C.clock_gettime(1, ffi.cast("void*", ts))
            return tonumber(ts[0]) * 1000 + tonumber(ts[1]) / 1e6
        end
    else
        wall_now = function() return os.time() * 1000 end
    end
end

M.wall_ms = wall_now

---Env-gated internal tracing (MILL_DEBUG=1) for hang diagnosis.
local DEBUG = os.getenv("MILL_DEBUG") ~= nil
local function dlog(fmt, ...)
    if DEBUG then
        print(string.format("[ffi %6.0fms] " .. fmt, wall_now(), ...))
    end
end
M._dlog = dlog

-- ---------------------------------------------------------------------------
-- Session — persistent multi-handle pump
-- ---------------------------------------------------------------------------

local function build_slist(headers)
    if not headers then
        return nil
    end
    local head = nil
    local count = 0
    for k, v in pairs(headers) do
        local line
        if v == true or v == nil then
            line = tostring(k) .. ";"
        else
            line = tostring(k) .. ": " .. tostring(v)
        end
        local ok, res = pcall(C.curl_slist_append, head, line)
        if not ok or res == nil then
            break
        end
        head = res
        count = count + 1
    end
    if count == 0 then
        return nil
    end
    return head
end

local Session = {}
Session.__index = Session

---Prepare transfer state for one request. `req` fields:
---  id (caller tag, required for routing), url (required), method, headers,
---  body, timeout_ms, connect_timeout_ms, user_agent, referer, insecure
local function prepare_transfer(req)
    local easy = C.curl_easy_init()
    if easy == nil then
        return nil, "curl_easy_init returned NULL"
    end

    local t = {
        req = req,
        easy = easy,
        buf = {},
        hdrs = {},
        done = false,
        code = nil,
        added = false,
        body_buf = nil,
        slist = nil,
        started_ms = nil,
        session = nil,
    }
    registry[pkey(easy)] = t

    C.curl_easy_setopt(easy, CO.URL, ffi.cast("void*", req.url))
    C.curl_easy_setopt(easy, CO.WRITEFUNCTION, write_cb)
    C.curl_easy_setopt(easy, CO.WRITEDATA, ffi.cast("void*", easy))
    C.curl_easy_setopt(easy, CO.HEADERFUNCTION, header_cb)
    C.curl_easy_setopt(easy, CO.HEADERDATA, ffi.cast("void*", easy))
    -- "" = accept all encodings curl supports and decompress transparently.
    C.curl_easy_setopt(easy, CO.ACCEPT_ENCODING, ffi.cast("void*", ""))
    C.curl_easy_setopt(easy, CO.NOSIGNAL, ffi.cast("long", 1))
    C.curl_easy_setopt(easy, CO.FOLLOWLOCATION, ffi.cast("long", 1))
    if CURL_VERBOSE then
        C.curl_easy_setopt(easy, CO.VERBOSE, ffi.cast("long", 1))
    end

    if req.user_agent then
        C.curl_easy_setopt(easy, CO.USERAGENT, ffi.cast("void*", req.user_agent))
    end
    if req.referer then
        C.curl_easy_setopt(easy, CO.REFERER, ffi.cast("void*", req.referer))
    end
    if req.timeout_ms then
        C.curl_easy_setopt(easy, CO.TIMEOUT_MS, ffi.cast("long", req.timeout_ms))
    end
    if req.connect_timeout_ms then
        C.curl_easy_setopt(easy, CO.CONNECTTIMEOUT_MS,
            ffi.cast("long", req.connect_timeout_ms))
    end
    if req.insecure then
        C.curl_easy_setopt(easy, CO.SSL_VERIFYPEER, ffi.cast("long", 0))
        C.curl_easy_setopt(easy, CO.SSL_VERIFYHOST, ffi.cast("long", 0))
    end

    local method = (req.method or "GET"):upper()
    if req.body and req.body ~= "" then
        -- Anchor the body buffer: a ffi.cast pointer to a Lua string does
        -- NOT keep the string alive across the C call.
        t.body_buf = ffi.new("char[?]", #req.body + 1, req.body)
        C.curl_easy_setopt(easy, CO.POSTFIELDS, ffi.cast("void*", t.body_buf))
        C.curl_easy_setopt(easy, CO.POSTFIELDSIZE, ffi.cast("long", #req.body))
        if method == "GET" then
            method = "POST"
        end
    end
    if method ~= "GET" then
        C.curl_easy_setopt(easy, CO.CUSTOMREQUEST, ffi.cast("void*", method))
    end

    t.slist = build_slist(req.headers)
    if t.slist then
        C.curl_easy_setopt(easy, CO.HTTPHEADER, ffi.cast("struct curl_slist*", t.slist))
    end

    return t
end

local function result_for(t)
    local r = { id = t.req.id, ms = math.floor(t.ms or 0), req = t.req }
    if t.code == 0 then
        local code_ref = ffi.new("long[1]")
        C.curl_easy_getinfo(t.easy, CURLINFO_RESPONSE_CODE, code_ref)
        r.ok = true
        r.status = tonumber(code_ref[0])
        r.body = table.concat(t.buf)
        r.headers = t.hdrs
    else
        r.ok = false
        r.curl_code = t.code
        r.error = (t.code and t.code >= 0)
            and ffi.string(C.curl_easy_strerror(t.code))
            or (t.prep_error or "unknown error")
        r.status = t.status -- may exist on HTTP-level failures with body
        r.body = table.concat(t.buf)
        r.headers = t.hdrs
    end
    return r
end

local function destroy_transfer(t, multi)
    registry[pkey(t.easy)] = nil
    if t.added then
        pcall(C.curl_multi_remove_handle, multi, t.easy)
        t.added = false
    end
    pcall(C.curl_easy_cleanup, t.easy)
    if t.slist then
        pcall(C.curl_slist_free_all, t.slist)
        t.slist = nil
    end
    t.easy = nil
    t.body_buf = nil
end

---Create a persistent pump session.
function M.session()
    local ok_load, err_load = ensure_loaded()
    if not ok_load then
        return nil, err_load
    end
    ensure_callbacks()

    local multi = C.curl_multi_init()
    if multi == nil then
        return nil, "curl_multi_init returned NULL"
    end

    local s = setmetatable({
        multi = multi,
        active = 0,          -- transfers added to multi and not yet DONE
        transfers = {},      -- all live transfer tables
        completed = {},      -- drained via take_completed()
        destroyed = false,
    }, Session)
    return s
end

---Submit one request. Returns the request id, or nil + error.
function Session:submit(req)
    if self.destroyed then
        return nil, "session destroyed"
    end
    if not req.id or not req.url then
        return nil, "request requires id and url"
    end
    if not req.timeout_ms then
        req.timeout_ms = 15000
    end

    local t, perr = prepare_transfer(req)
    if not t then
        return nil, perr
    end
    t.session = self
    self.transfers[#self.transfers + 1] = t

    local rc = C.curl_multi_add_handle(self.multi, t.easy)
    if rc ~= 0 then
        t.done = true
        t.code = -2
        t.prep_error = "curl_multi_add_handle: " ..
            ffi.string(C.curl_multi_strerror(rc))
        t.ms = 0
        self.completed[#self.completed + 1] = result_for(t)
        destroy_transfer(t, self.multi)
        return req.id, t.prep_error
    end

    t.added = true
    t.started_ms = wall_now()
    self.active = self.active + 1
    dlog("submit ok id=%s url=%s timeout=%s active=%d", tostring(req.id), req.url, tostring(req.timeout_ms), self.active)
    return req.id
end

---Number of transfers currently in flight.
function Session:pending()
    return self.active
end

---Drain completed results (array of result tables with .id).
function Session:take_completed()
    local out = self.completed
    self.completed = {}
    return out
end

function Session:_drain()
    while true do
        local q = ffi.new("int[1]")
        local msg = C.curl_multi_info_read(self.multi, q)
        if msg == nil or msg[0].msg ~= CURLMSG_DONE then
            break
        end
        local easy = msg[0].easy_handle
        local t = registry[pkey(easy)]
        if t and t.session == self then
            t.done = true
            t.code = tonumber(msg[0].data.result)
            C.curl_multi_remove_handle(self.multi, easy)
            t.added = false
            t.ms = (t.started_ms and (wall_now() - t.started_ms)) or 0
            self.active = self.active - 1
            dlog("drain DONE id=%s code=%d ms=%.0f body=%d active=%d",
                tostring(t.req.id), t.code, t.ms, #t.buf, self.active)
            self.completed[#self.completed + 1] = result_for(t)
            destroy_transfer(t, self.multi)
        else
            dlog("drain DONE for foreign/unknown easy %s", tostring(pkey(easy)))
        end
    end
end

---Pump until at least one transfer completes, all active transfers finish,
---or deadline_ms (monotonic) passes. Returns the number of newly completed
---results. Deadline expiry does NOT cancel in-flight transfers — curl's
---own per-request timeout applies, and pumping resumes on the next call.
function Session:run_slice(deadline_ms)
    if self.destroyed then
        return 0
    end
    if self.active == 0 then
        self:_drain()
        return #self.completed
    end

    local before = #self.completed
    local poll_ms = 50
    local loops = 0

    while self.active > 0 do
        loops = loops + 1
        local now = wall_now()
        if deadline_ms and now >= deadline_ms then
            dlog("run_slice deadline hit (loops=%d active=%d)", loops, self.active)
            break
        end

        local still = ffi.new("int[1]")
        local rc = C.curl_multi_perform(self.multi, still)
        if rc ~= 0 then
            dlog("run_slice perform rc=%d — breaking", rc)
            break
        end
        if DEBUG and loops <= 3 then
            dlog("run_slice loop=%d still=%d active=%d completed=%d", loops, tonumber(still[0]), self.active, #self.completed)
        end

        self:_drain()
        if #self.completed > before then
            return #self.completed - before
        end

        if self.active > 0 then
            local wait = poll_ms
            if deadline_ms then
                wait = math.min(poll_ms, math.max(1, math.floor(deadline_ms - now)))
            end
            C.curl_multi_poll(self.multi, ffi.cast("struct curl_waitfd*", 0),
                ffi.cast("unsigned int", 0), ffi.cast("int", wait),
                ffi.cast("int*", 0))
        end
    end

    -- Final drain in case the last poll delivered completions.
    self:_drain()
    dlog("run_slice exit loops=%d active=%d new=%d", loops, self.active, #self.completed - before)
    return #self.completed - before
end

---Pump until all active transfers finish or deadline_ms passes.
function Session:run(deadline_ms)
    while self.active > 0 do
        if deadline_ms == nil then
            self:run_slice(nil)
        else
            local n = self:run_slice(deadline_ms)
            if n == 0 and self.active > 0 then
                break -- deadline hit with work still in flight
            end
        end
    end
    -- Final drain in case the last poll delivered completions.
    self:_drain()
end

---Destroy the session: abort/clean everything still in flight.
function Session:destroy()
    if self.destroyed then
        return
    end
    for _, t in ipairs(self.transfers) do
        if not t.done then
            t.done = true
            t.code = -3
            t.prep_error = "session destroyed"
            t.ms = (t.started_ms and (wall_now() - t.started_ms)) or 0
        end
        destroy_transfer(t, self.multi)
    end
    self.transfers = {}
    self.active = 0
    pcall(C.curl_multi_cleanup, self.multi)
    self.multi = nil
    self.destroyed = true
end

-- ---------------------------------------------------------------------------
-- fetch_all — one-shot batch over a throwaway session
-- ---------------------------------------------------------------------------

---Fetch many requests concurrently.
---  requests: array of request tables (id required for result routing)
---  opts: { max_wait_ms (default 120000), default_timeout_ms (15000) }
---Returns array of result tables aligned with requests:
---  { id, ok, status, body, headers, error, curl_code, ms }
function M.fetch_all(requests, opts)
    opts = opts or {}
    local max_wait_ms = opts.max_wait_ms or 120000

    local s, serr = M.session()
    if not s then
        return nil, serr
    end

    for i, req in ipairs(requests) do
        if not req.id then
            req.id = i
        end
        if not req.timeout_ms then
            req.timeout_ms = opts.default_timeout_ms or 15000
        end
        s:submit(req)
    end

    s:run(wall_now() + max_wait_ms)

    -- Map results by request id.
    local by_id = {}
    for _, r in ipairs(s:take_completed()) do
        by_id[r.id] = r
    end

    -- Anything never completed gets an error entry.
    local results = {}
    for i, req in ipairs(requests) do
        local r = by_id[req.id]
        if r == nil then
            r = { id = req.id, ok = false, error = "no completion before deadline", ms = 0 }
        end
        results[i] = r
    end

    s:destroy()
    return results
end

---Convenience: single request.
function M.fetch_one(req, opts)
    local results, err = M.fetch_all({ req }, opts)
    if not results then
        return nil, err
    end
    return results[1]
end

return M
