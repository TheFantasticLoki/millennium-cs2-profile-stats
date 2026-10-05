---Provider fetch coordinator: parallel pump over backend/ffi_http.lua with
---the same cache/coalescing semantics as the legacy serial path.
---
---How a profile view flows:
---  1. The webkit frontend fires every provider route (PROVIDER_ORDER)
---     without awaiting; each call enters coordinator.get().
---  2. The first call creates a pipeline for every enabled provider that
---    lacks a fresh cache entry and pumps them ALL concurrently through one
---    persistent curl_multi session (wall ≈ slowest provider).
---  3. The call returns when its own provider finishes (later route calls
---    hit cache and return instantly) or when the pump budget expires
---    (budget < Millennium's 30s EVALUATE timeout — a hard parent-side
---    constraint). In-flight transfers survive across route calls and
---    resume pumping on the next call.
---  4. If FFI/libcurl is unavailable, everything falls back to the legacy
---    blocking RPC path (reg.fetch_provider) with identical caching.
---
---Pipeline contract (per provider module `x.pipeline(steam_id)`):
---  p.queue        request descriptors waiting to be submitted
---  p.next(self)   -> array|nil of requests to submit now (consumes queue)
---  p.handle(self, req, resp)  advance on a completed response; call
---                  self:finish(json) at the terminal state
---  p.inflight     coordinator-managed count of submitted-not-completed reqs

local cjson = require("json")
local logger = require("logger")
local millennium = require("millennium")
local reg = require("providers/init")
local cache = require("cache")

local ffi_http_ok, ffi_http = pcall(require, "ffi_http")

local coordinator = {}

---Per-IPC-call pump budget. Millennium's backend_manager::evaluate uses
---PluginProcess::call's default 30s timeout — stay under it with margin.
local BUDGET_MS = 26000

---Window for serving just-completed results that were NOT cacheable (plain
---"error" responses are never pinned per §7, but the route that triggered
---the fetch must still return the real result, not a timeout message).
---Exceeds the pump budget so the frontend's call burst (routes queue behind
---the first EVALUATE while it pumps) always finds its results here.
local RECENT_WINDOW_MS = 30000

---Negative-cache TTLs (seconds), matching the legacy main.lua semantics.
local NEGATIVE_TTL = 300
local TRANSIENT_TTL = 120

---Canonical fetch priority: fast public APIs first, HTML scrapers last.
---Mirrors the frontend's PROVIDER_ORDER in webkit/index.tsx.
local FETCH_PRIORITY = { "leetify", "faceit", "csrep", "cstracker", "csstats" }

local session = nil            -- persistent ffi_http session (nil = unavailable)
pipelines = {}                -- ["name:steam_id"] = pipeline object (global for debug)
local legacy_inflight = {}     -- legacy-path coalescing markers
local recent = {}              -- ["name:steam_id"] = { result, at_ms } uncacheable results
local pumping = false          -- re-entrancy guard

local DEBUG = os.getenv("MILL_DEBUG") ~= nil
local function dlog(fmt, ...)
    if DEBUG then
        print(string.format("[coord %7.0fms] " .. fmt, ffi_http.wall_ms(), ...))
    end
end

-- ---------------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------------

local function get_session()
    if session ~= nil and not session.destroyed then
        return session
    end
    if not ffi_http_ok then
        return nil, "ffi_http module unavailable: " .. tostring(ffi_http)
    end
    local s, err = ffi_http.session()
    if not s then
        return nil, err
    end
    session = s
    logger:info("[coordinator] parallel HTTP session up (libcurl " ..
        tostring(ffi_http.version()) .. ")")
    return session
end

---True when the parallel pump path can be used.
function coordinator.parallel_available()
    local s = get_session()
    return s ~= nil
end

-- ---------------------------------------------------------------------------
-- Cache helpers (per-status TTLs — identical to legacy main.lua)
-- ---------------------------------------------------------------------------

---Cache a provider IPC result using per-status TTLs.
local function cache_provider_result(name, steam_id, result)
    local ok, parsed = pcall(cjson.decode, result)
    if not ok or type(parsed) ~= "table" or type(parsed.status) ~= "string" then
        return
    end
    local status = parsed.status
    if status == "ok" then
        cache:set(name, steam_id, result)
    elseif status == "not_found" or status == "private" or status == "unauthorized" then
        cache:set(name, steam_id, result, NEGATIVE_TTL)
    elseif status == "rate_limited" or status == "cloudflare_required" then
        cache:set(name, steam_id, result, TRANSIENT_TTL)
    end
    -- plain "error" is never cached
end

-- ---------------------------------------------------------------------------
-- Pipelines
-- ---------------------------------------------------------------------------

local function finish_pipeline(p, result_json)
    pipelines[p.key] = nil
    cache_provider_result(p.name, p.steam_id, result_json)
    recent[p.key] = { result = result_json, at = ffi_http.wall_ms() }
    local ms = (p.started_ms and ffi_http and ffi_http.wall_ms and
        math.floor(ffi_http.wall_ms() - p.started_ms)) or -1
    dlog("FINISH %s after %dms", p.name, ms)
    logger:info("[" .. p.name .. "] fetch finished in " .. tostring(ms) .. "ms")
    -- E2E readback: last fetch duration per provider, readable from
    -- ~/.config/millennium/config.json without the log console.
    pcall(millennium.config.set, "last_fetch_ms_" .. p.name, ms)
end

local function ensure_pipeline(name, steam_id)
    local key = name .. ":" .. steam_id
    if pipelines[key] ~= nil then
        return pipelines[key]
    end
    local def = reg.get(name)
    if def == nil or type(def.pipeline) ~= "function" then
        return nil
    end
    if not reg.is_provider_enabled(name) then
        return nil
    end
    local ok, p = pcall(def.pipeline, steam_id)
    if not ok or type(p) ~= "table" then
        logger:error("[" .. name .. "] pipeline creation failed: " .. tostring(p))
        return nil
    end
    p.name = name
    p.steam_id = steam_id
    p.key = key
    p.inflight = 0
    p.started_ms = ffi_http.wall_ms()
    if type(p.finish) ~= "function" then
        function p:finish(json)
            self.finished = true
            self.final_result = json
        end
    end
    pipelines[key] = p
    return p
end

---Submit a pipeline's queued requests to the session.
local function submit_pipeline(p, s)
    local ok, reqs = pcall(p.next, p)
    if not ok then
        finish_pipeline(p, reg.encode({
            status = "error",
            message = (p.name or "?") .. " pipeline error: " .. tostring(reqs),
        }))
        return
    end
    if type(reqs) ~= "table" then
        return
    end
    for _, req in ipairs(reqs) do
        req.id = req.id or (p.key .. "|" .. tostring(req.tag or #reqs))
        local rid, err = s:submit(req)
        if rid == nil then
            logger:warn("[" .. p.name .. "] request submit failed: " .. tostring(err))
            dlog("submit FAILED %s: %s", tostring(req.id), tostring(err))
            -- Deliver a synthetic failure so the pipeline can advance.
            local h_ok, h_err = pcall(p.handle, p, req,
                { id = req.id, ok = false, status = nil, error = tostring(err) })
            if not h_ok then
                finish_pipeline(p, reg.encode({
                    status = "error",
                    message = (p.name or "?") .. " handler error: " .. tostring(h_err),
                }))
            elseif p.finished then
                finish_pipeline(p, p.final_result)
            end
        else
            p.inflight = (p.inflight or 0) + 1
            dlog("submit ok %s (inflight=%d)", tostring(req.id), p.inflight)
        end
    end
end

---Pump all live pipelines until the deadline. Routes every completed
---response to its pipeline and finalizes pipelines that reach a terminal
---state. Returns when nothing is in flight or the deadline passes.
---Pump all live pipelines until the deadline, at least one transfer
---completes per slice, or — when target_key is set — that pipeline reaches
---a terminal state. Target-aware exits are what keep the UI progressive:
---each route call returns as soon as ITS provider finishes while the other
---pipelines keep their curl state and resume on the next route call's pump.
local function pump_all(deadline_ms, target_key)
    local s = get_session()
    if s == nil then
        return false
    end
    if pumping then
        logger:warn("[coordinator] pump re-entry skipped")
        return false
    end
    pumping = true

    local guard = 0
    while ffi_http.wall_ms() < deadline_ms do
        guard = guard + 1
        if guard > 500 then
            logger:warn("[coordinator] pump guard tripped")
            dlog("pump BREAK guard")
            break
        end

        -- 1) Submit queued requests for pipelines with nothing in flight.
        for _, p in pairs(pipelines) do
            if not p.finished and (p.inflight or 0) == 0 then
                submit_pipeline(p, s)
            end
        end

        -- 2) Nothing left to do?
        local any_work = false
        for _, p in pairs(pipelines) do
            if not p.finished then
                any_work = true
                break
            end
        end
        if not any_work then
            dlog("pump BREAK all-done (guard=%d)", guard)
            break
        end

        -- 3) Pump until at least one transfer completes or the deadline.
        if s:pending() > 0 then
            local n = s:run_slice(deadline_ms)
            dlog("pump guard=%d pending=%d sliced=%s", guard, s:pending(), tostring(n))
            if n == 0 and s:pending() > 0 then
                dlog("pump BREAK deadline-slice (guard=%d)", guard)
                break -- deadline with work still in flight
            end
        else
            dlog("pump guard=%d pending=0 — resubmit loop", guard)
        end

        -- 4) Route completions to their pipelines.
        for _, resp in ipairs(s:take_completed()) do
            local key, tag = tostring(resp.id):match("^(.-)|(.+)$")
            local p = key and pipelines[key] or nil
            dlog("completion id=%s -> key=%s tag=%s found=%s", tostring(resp.id), tostring(key), tostring(tag), tostring(p ~= nil))
            if p ~= nil then
                p.inflight = math.max(0, (p.inflight or 1) - 1)
                -- Pass the ORIGINAL request table (carries pipeline-set
                -- fields like req.fs / req.tag), not a reconstructed stub.
                local req = resp.req or { id = resp.id, tag = tag }
                local ok, err = pcall(p.handle, p, req, resp)
                if not ok then
                    finish_pipeline(p, reg.encode({
                        status = "error",
                        message = (p.name or "?") .. " handler error: " .. tostring(err),
                    }))
                elseif p.finished then
                    finish_pipeline(p, p.final_result)
                end
            end
        end

        -- 5) Target-specific early exit: the calling route only waits for
        -- ITS provider. Remaining pipelines stay registered with their
        -- in-flight transfers and resume when the next queued route call
        -- pumps the shared session.
        if target_key ~= nil and pipelines[target_key] == nil then
            dlog("pump BREAK target-done %s (guard=%d)", target_key, guard)
            break
        end
    end

    pumping = false
    return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

---Fetch one provider: fresh cache → parallel pump (all unfinished
---providers) → legacy serial fallback.
---@param name string provider name
---@param steam_id string
---@return string JSON-encoded provider response
function coordinator.get(name, steam_id)
    if not reg.valid_steam_id(steam_id) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end
    local def = reg.get(name)
    if def == nil then
        return reg.encode({ status = "error", message = "Unknown provider: " .. tostring(name) })
    end
    if not reg.is_provider_enabled(name) then
        return reg.encode({ status = "error", message = (def.display_name or name) .. " is disabled." })
    end

    local cached = cache:get(name, steam_id)
    if cached ~= nil then
        return cached
    end

    local key = name .. ":" .. steam_id

    ---Fetch a just-completed uncacheable result (plain "error" responses
    ---are never pinned to the cache — see cache_provider_result).
    local function take_recent()
        local r = recent[key]
        if r ~= nil and (ffi_http.wall_ms() - r.at) < RECENT_WINDOW_MS then
            return r.result
        end
        return nil
    end

    -- Coalescing: an identical fetch is already pumping — serve stale.
    if pipelines[key] ~= nil then
        local stale = cache:get_stale(name, steam_id)
        if stale ~= nil then
            logger:info("[" .. name .. "] fetch already in flight for " .. steam_id .. "; serving stale cache")
            return stale
        end
        -- No stale copy: pump the shared session a bit — the pipeline may
        -- complete inside this call's budget.
        if coordinator.parallel_available() then
            pump_all(ffi_http.wall_ms() + BUDGET_MS, key)
            -- The pump may have completed the target with an uncacheable
            -- "error" result — serve it from the recent map, not a timeout
            -- message.
            local result = cache:get(name, steam_id) or take_recent()
            if result ~= nil then
                return result
            end
            local stale = cache:get_stale(name, steam_id)
            if stale ~= nil then
                return stale
            end
        end
        return reg.encode({
            status = "error",
            message = (def.display_name or name) .. " is still fetching; try again shortly.",
        })
    end

    -- Parallel path: fan out every unfinished enabled provider.
    if coordinator.parallel_available() then
        -- A just-completed uncacheable result (plain "error") beats a
        -- pointless re-fetch during the frontend's call burst.
        local early_recent = take_recent()
        if early_recent ~= nil then
            return early_recent
        end
        for _, pname in ipairs(FETCH_PRIORITY) do
            local pdef = reg.get(pname)
            if pdef ~= nil and type(pdef.pipeline) == "function"
                and reg.is_provider_enabled(pname)
                and cache:get(pname, steam_id) == nil then
                ensure_pipeline(pname, steam_id)
            end
        end
        ensure_pipeline(name, steam_id)

        local deadline = ffi_http.wall_ms() + BUDGET_MS
        local t0 = ffi_http.wall_ms()
        pump_all(deadline, key)
        local pumped_ms = math.floor(ffi_http.wall_ms() - t0)

        if pipelines[key] == nil then
            local result = cache:get(name, steam_id) or take_recent()
            if result ~= nil then
                logger:info("[" .. name .. "] served after " .. pumped_ms .. "ms pump for " .. steam_id)
                return result
            end
        end

        local stale = cache:get_stale(name, steam_id)
        if stale ~= nil then
            logger:warn("[" .. name .. "] pump budget exhausted after " .. pumped_ms ..
                "ms for " .. steam_id .. "; serving stale cache")
            return stale
        end
        local recent_result = take_recent()
        if recent_result ~= nil then
            return recent_result
        end
        logger:warn("[" .. name .. "] pump budget exhausted after " .. pumped_ms ..
            "ms for " .. steam_id .. " with no result")
        return reg.encode({
            status = "error",
            message = (def.display_name or name) .. " is taking too long; try again shortly.",
        })
    end

    -- Legacy serial fallback (FFI/libcurl unavailable in this process).
    if legacy_inflight[key] then
        local stale = cache:get_stale(name, steam_id)
        if stale ~= nil then
            logger:info("[" .. name .. "] identical fetch in flight for " .. steam_id .. "; serving stale cache")
            return stale
        end
    end
    legacy_inflight[key] = true
    local ok, result = pcall(reg.fetch_provider, name, steam_id)
    legacy_inflight[key] = nil
    if not ok or type(result) ~= "string" then
        result = reg.encode({ status = "error", message = tostring(result) })
    end
    cache_provider_result(name, steam_id, result)
    return result
end

---Fetch all enabled providers (reload semantics: invalidate first).
---@param steam_id string
---@return string JSON-encoded map of provider name → response JSON
function coordinator.get_all(steam_id)
    if not reg.valid_steam_id(steam_id) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    -- Legacy "reload" semantics: wipe this profile's cache first.
    cache:invalidate_for(steam_id)

    local results = {}

    if coordinator.parallel_available() then
        for _, pname in ipairs(FETCH_PRIORITY) do
            local pdef = reg.get(pname)
            if pdef ~= nil and type(pdef.pipeline) == "function" and reg.is_provider_enabled(pname) then
                ensure_pipeline(pname, steam_id)
            end
        end
        pump_all(ffi_http.wall_ms() + BUDGET_MS)
        for _, pname in ipairs(FETCH_PRIORITY) do
            local pdef = reg.get(pname)
            if pdef ~= nil and reg.is_provider_enabled(pname) then
                local pkey = pname .. ":" .. steam_id
                local result = cache:get(pname, steam_id) or cache:get_stale(pname, steam_id)
                if result == nil and recent[pkey] ~= nil and
                    (ffi_http.wall_ms() - recent[pkey].at) < RECENT_WINDOW_MS then
                    result = recent[pkey].result
                end
                if result == nil then
                    result = reg.encode({
                        status = "error",
                        message = (pdef.display_name or pname) .. " is taking too long; try again shortly.",
                    })
                end
                results[pname] = result
            end
        end
        return reg.encode(results)
    end

    -- Legacy serial path.
    local ordered, seen = {}, {}
    for _, pname in ipairs(FETCH_PRIORITY) do
        if reg.get(pname) ~= nil then
            ordered[#ordered + 1] = pname
            seen[pname] = true
        end
    end
    for pname, _ in pairs(reg.get_all()) do
        if not seen[pname] then
            ordered[#ordered + 1] = pname
        end
    end
    for _, pname in ipairs(ordered) do
        if reg.is_provider_enabled(pname) then
            local ok, result = pcall(reg.fetch_provider, pname, steam_id)
            if ok and type(result) == "string" then
                results[pname] = result
                cache_provider_result(pname, steam_id, result)
            else
                logger:error(pname .. " threw an error: " .. tostring(result))
                results[pname] = reg.encode({
                    status = "error",
                    message = pname .. " encountered an error.",
                })
            end
        else
            logger:info(pname .. ": skipped (disabled)")
        end
    end
    return reg.encode(results)
end

---IPC helper retained for compatibility: aggregate from all enabled
---providers (parallel path pumps them concurrently via coordinator.get).
function coordinator.fetch_priority()
    return FETCH_PRIORITY
end

return coordinator
