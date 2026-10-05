---FFI + libcurl feasibility probe for the parallel-HTTP experiment.
---
---Run from on_load. Every step is pcall-guarded: a failure here must never
---prevent the plugin from loading. Results are logged AND written to the
---plugin config key "ffi_probe_result" so they can be read back from
---~/.config/millennium/config.json without needing the log console.
local logger = require("logger")
local millennium = require("millennium")

local M = {}

local TAG = "[ffi-probe]"
local CONFIG_KEY = "ffi_probe_result"

local summary_lines = {}

local function report(level, msg)
    local line = TAG .. " " .. msg
    if level == "error" then
        logger:error(line)
    else
        logger:info(line)
    end
    summary_lines[#summary_lines + 1] = msg
end

---Wall-clock milliseconds (os.clock is CPU time — wrong for network waits).
---Canonical signature: every module in this plugin declares clock_gettime
---as (int, void*) — typed timespec redeclarations conflict in ffi.C.
local function wall_ms_clock(ffi)
    local ok = pcall(ffi.cdef, "int clock_gettime(int clk_id, void *tp);")
    if not ok then
        return function() return os.time() * 1000 end
    end
    local ts = ffi.new("long[2]") -- {tv_sec, tv_nsec} on LP64
    return function()
        ffi.C.clock_gettime(1, ffi.cast("void*", ts)) -- CLOCK_MONOTONIC
        return tonumber(ts[0]) * 1000 + tonumber(ts[1]) / 1e6
    end
end

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

---Absolute libcurl locations to try after the dlopen short names. Steam runs
---inside a pressure-vessel sandbox, so in-container paths may differ from the
---host's; the candidate list covers both worlds.
local function libcurl_candidates()
    local list = {
        "/usr/lib/libcurl.so.4",
        "/usr/lib/libcurl.so",
        "/usr/lib64/libcurl.so.4",
        "/lib/x86_64-linux-gnu/libcurl.so.4",
        "/lib/libcurl.so.4",
    }
    for _, root in ipairs(steam_roots()) do
        list[#list + 1] = root .. "/steamapps/common/SteamLinuxRuntime/var/steam-runtime/pinned_libs_64/libcurl.so.4"
        list[#list + 1] = root .. "/steamapps/common/SteamLinuxRuntime/var/steam-runtime/usr/lib/x86_64-linux-gnu/libcurl.so.4"
        list[#list + 1] = root .. "/ubuntu12_64/steam-runtime/pinned_libs_64/libcurl.so.4"
    end
    return list
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

---Try to load libcurl through FFI, then prove a real C call works.
local function probe_libcurl(ffi)
    local names = { "curl", "libcurl.so.4", "libcurl.so" }
    for _, p in ipairs(libcurl_candidates()) do
        if file_exists(p) then
            names[#names + 1] = p
        end
    end

    local lib, load_err
    for _, name in ipairs(names) do
        local ok, res = pcall(ffi.load, name)
        if ok and res then
            lib = res
            report("info", "libcurl loaded via '" .. name .. "'")
            break
        end
        load_err = res
    end

    if not lib then
        report("error", "libcurl load FAILED: " .. tostring(load_err))
        return nil
    end

    local ok_cdef, cdef_err = pcall(ffi.cdef, [[
        const char *curl_version(void);
        typedef void CURL;
        typedef int CURLcode;
        typedef int CURLoption;
        CURL *curl_easy_init(void);
        CURLcode curl_easy_setopt(CURL *handle, CURLoption option, ...);
        CURLcode curl_easy_perform(CURL *handle);
        void curl_easy_cleanup(CURL *handle);
        CURLcode curl_easy_getinfo(CURL *handle, int info, ...);
        const char *curl_easy_strerror(CURLcode code);
    ]])
    if not ok_cdef then
        report("error", "curl cdef FAILED: " .. tostring(cdef_err))
        return nil
    end

    local ok_ver, ver = pcall(function()
        return ffi.string(lib.curl_version())
    end)
    if not ok_ver then
        report("error", "curl_version() FAILED: " .. tostring(ver))
        return nil
    end
    report("info", "curl_version(): " .. ver)

    return lib
end

---Fire one real HTTPS request through the easy interface. Any HTTP status
---(even 4xx) proves DNS + TLS + callbacks work in this process.
local function probe_easy_request(ffi, lib, wall_ms)
    local chunks = {}
    local write_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
        function(ptr, size, nmemb, _ud)
            local n = size * nmemb
            if n > 0 then
                chunks[#chunks + 1] = ffi.string(ptr, n)
            end
            return n
        end)

    local easy = lib.curl_easy_init()
    if easy == nil then
        report("error", "curl_easy_init returned NULL")
        write_cb:free()
        return
    end

    local CURLOPT_URL = 10002
    local CURLOPT_WRITEFUNCTION = 20011
    local CURLOPT_WRITEDATA = 10001
    local CURLOPT_USERAGENT = 10018
    local CURLOPT_ACCEPT_ENCODING = 10102
    local CURLOPT_TIMEOUT_MS = 155
    local CURLOPT_NOSIGNAL = 99
    local CURLOPT_FOLLOWLOCATION = 52
    local CURLINFO_RESPONSE_CODE = 0x200002

    local url = "https://api-public.cs-prod.leetify.com/v3/profile?steam64_id=76561197960265728"
    lib.curl_easy_setopt(easy, CURLOPT_URL, ffi.cast("void*", url))
    lib.curl_easy_setopt(easy, CURLOPT_USERAGENT,
        ffi.cast("void*", "millennium-cs2-profile-stats/0.5.0 ffi-probe"))
    lib.curl_easy_setopt(easy, CURLOPT_ACCEPT_ENCODING, ffi.cast("void*", ""))
    lib.curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb)
    lib.curl_easy_setopt(easy, CURLOPT_WRITEDATA, ffi.cast("void*", 0))
    lib.curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, ffi.cast("long", 10000))
    lib.curl_easy_setopt(easy, CURLOPT_NOSIGNAL, ffi.cast("long", 1))
    lib.curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, ffi.cast("long", 1))

    local t0 = wall_ms()
    local rc = lib.curl_easy_perform(easy)
    local dt = wall_ms() - t0

    if rc ~= 0 then
        report("error", "easy request FAILED rc=" .. tostring(rc) ..
            " (" .. ffi.string(lib.curl_easy_strerror(rc)) ..
            ") after " .. string.format("%.0f", dt) .. "ms")
    else
        local code_ref = ffi.new("long[1]")
        lib.curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, code_ref)
        local body = table.concat(chunks)
        report("info", "easy request OK: HTTP " .. tostring(code_ref[0]) ..
            " body_bytes=" .. tostring(#body) ..
            " in " .. string.format("%.0f", dt) .. "ms")
    end

    lib.curl_easy_cleanup(easy)
    write_cb:free()
end

local function write_config_summary(ok)
    pcall(function()
        local quoted = {}
        for i = 1, #summary_lines do
            quoted[i] = string.format("%q", summary_lines[i])
        end
        millennium.config.set(CONFIG_KEY, string.format(
            '{"ok":%s,"ts":%d,"lines":[%s]}',
            ok and "true" or "false",
            os.time(),
            table.concat(quoted, ",")))
    end)
end

---Entry point: safe to call from on_load.
function M.run()
    summary_lines = {}
    report("info", "starting (Millennium lua-host probe)")

    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then
        report("error", "require('ffi') FAILED: " .. tostring(ffi))
        write_config_summary(false)
        return false
    end
    report("info", "require('ffi') OK; ffi.os=" .. tostring(ffi.os) ..
        " ffi.arch=" .. tostring(ffi.arch))

    local ok_jit, jit = pcall(require, "jit")
    if ok_jit and type(jit) == "table" and type(jit.status) == "function" then
        local ok_st, on = pcall(jit.status)
        report("info", "jit compiler enabled: " .. tostring(ok_st and on or "?"))
    end

    local wall_ms = wall_ms_clock(ffi)

    local lib = probe_libcurl(ffi)
    if not lib then
        write_config_summary(false)
        return false
    end

    probe_easy_request(ffi, lib, wall_ms)
    report("info", "done")
    write_config_summary(true)
    return true
end

return M
