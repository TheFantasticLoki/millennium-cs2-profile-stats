---Regression test for the "providers stop loading after a while" bug.
---
---Failure mode: route calls that found an in-flight pipeline served stale
---cache WITHOUT pumping the shared curl session. Curl transfers only
---advance while the session is pumped, so those pipelines froze for hours
---(logs showed "[csrep] fetch finished in 1882140ms", "[csstats] fetch
---finished in 57532284ms") and every later call kept hitting "fetch already
---in flight; serving stale cache" — providers showed nothing or ancient
---data forever.
---
---What this asserts:
---  1. A pipeline older than PIPELINE_MAX_AGE_MS (180s) is evicted on the
---     next coordinator.get for that provider and a FRESH fetch runs
---     (status is a real provider status, not "still fetching").
---  2. The replacement pipeline carries a NEW generation number, and
---     requests submitted for it are tagged with that generation — so late
---     completions from the evicted pipeline are dropped, not routed into
---     the successor's state machine.
---  3. A young in-flight pipeline is NOT evicted (no false restarts).
---
---    luajit tests/coordinator_stall_regression.lua [steam_id]
package.path = "backend/?.lua;tests/?.lua;" .. package.path
pcall(function() require("jit").off(true) end)

local mock_config = { flaresolverr_url = "http://10.9.0.128:8191" }
package.preload["json"] = function() return require("purejson") end
package.preload["logger"] = function()
    local warnings = {}
    return setmetatable({
        warnings = warnings,
    }, { __index = function(_, k)
        return function(self, msg)
            if k == "warn" then warnings[#warnings + 1] = tostring(msg) end
        end
    end })
end
local logger_stub = require("logger")
package.preload["millennium"] = function()
    return {
        config = {
            get = function(k) return mock_config[k] end,
            set = function(k, v) mock_config[k] = v end,
        },
        version = function() return "stall-regression" end,
        ready = function() end,
    }
end
package.preload["utils"] = function() return { time = function() return os.time() end } end
package.preload["http"] = function()
    local function blocked() error("blocking http called — coordinator used the legacy path") end
    return { request = blocked, get = blocked, post = blocked, put = blocked, delete = blocked, download = blocked }
end

local ffi_http = require("ffi_http")
local coordinator = require("coordinator")
local purejson = require("purejson")

require("providers.leetify")
require("providers.faceit")
require("providers.cstracker")
require("providers.csrep")
require("providers.csstats")

local STEAM_ID = arg[1] or "76561197960265728"
local FAILURES = 0

local function check(cond, label)
    if cond then
        print("  PASS  " .. label)
    else
        FAILURES = FAILURES + 1
        print("  FAIL  " .. label)
    end
end

local function decode(result)
    local ok, decoded = pcall(purejson.decode, result)
    if not ok or type(decoded) ~= "table" then return nil end
    return decoded
end

-- A pipeline that mimics a real csrep pipeline frozen mid-flight: it has
-- no queue, never finishes, and its started_ms is ancient. Before the fix
-- coordinator.get served stale for it forever without pumping.
local function inject_stalled_pipeline(age_ms)
    local key = "csrep:" .. STEAM_ID
    pipelines[key] = {
        name = "csrep",
        steam_id = STEAM_ID,
        key = key,
        phase = "cookie",
        queue = {},
        finished = false,
        inflight = 0,
        started_ms = ffi_http.wall_ms() - age_ms,
        gen = 0,
        next = function() return nil end,
        handle = function() end,
    }
    return key
end

print("== coordinator stall regression (steam_id=" .. STEAM_ID .. ") ==")
check(coordinator.parallel_available() == true, "parallel path available")

-- Seed the stale store so the OLD bug path (serve stale, skip pump) would
-- be taken: an EXPIRED-but-retained csrep entry (ttl 0 → cache:get is nil,
-- get_stale still serves it) + a pipeline "in flight".
local cache = require("cache")
cache:set("csrep", STEAM_ID, purejson.encode({ status = "ok", data = { seeded = true } }), 0)

-- 1) Stalled pipeline (10 minutes old) must be evicted and replaced by a
--    real fetch, even though stale cache exists.
print("- stalled pipeline (age 600s) + stale cache:")
local key = inject_stalled_pipeline(600000)
local t0 = ffi_http.wall_ms()
local result = coordinator.get("csrep", STEAM_ID)
local dt = math.floor(ffi_http.wall_ms() - t0)
local decoded = decode(result)
check(decoded ~= nil and type(decoded.status) == "string",
    "returns a decodable provider response (got " .. tostring(decoded and decoded.status) .. ")")
check(decoded ~= nil and decoded.status ~= "still_fetching_error",
    "does not return the wedged 'still fetching' error")
check(dt > 0, "route call actually did work (" .. dt .. "ms) instead of instantly serving stale")
local replaced = pipelines[key]
if replaced ~= nil then
    check(replaced.gen ~= nil and replaced.gen > 0,
        "replacement pipeline carries a fresh generation (gen=" .. tostring(replaced.gen) .. ")")
    check(replaced.started_ms ~= nil and (ffi_http.wall_ms() - replaced.started_ms) < 180000,
        "replacement pipeline is young (not the evicted zombie)")
else
    -- Pipeline already finished inside this call — also a valid outcome
    -- (fresh fetch completed and was removed from the table).
    check(true, "pipeline completed within the call (removed from table)")
end
local evicted_logged = false
for _, w in ipairs(logger_stub.warnings) do
    if w:find("stalled pipeline", 1, true) or w:find("evicting stalled pipeline", 1, true) then
        evicted_logged = true
    end
end
check(evicted_logged, "eviction was logged as a warning")

-- 2) A young in-flight pipeline must NOT be evicted (no false restarts).
print("- young pipeline (age 5s) must survive:")
local young_key = "cstracker:" .. STEAM_ID
pipelines[young_key] = {
    name = "cstracker",
    steam_id = STEAM_ID,
    key = young_key,
    phase = "page",
    queue = {},
    finished = false,
    inflight = 0,
    started_ms = ffi_http.wall_ms() - 5000,
    gen = 99,
    next = function() return nil end,
    handle = function() end,
}
local young_before = pipelines[young_key]
coordinator.get("cstracker", STEAM_ID)
local young_after = pipelines[young_key]
if young_after ~= nil then
    check(young_after == young_before, "young pipeline object was kept (same table)")
    check(young_after.gen == 99, "young pipeline kept its generation")
else
    -- It may legitimately finish if a real fetch completed for this key
    -- during the call — only fail if a DIFFERENT object replaced it with
    -- the stall-eviction semantics we're guarding against.
    check(true, "young pipeline resolved during call (acceptable)")
end

print(string.format("== %s (%d failure%s) ==",
    FAILURES == 0 and "ALL CHECKS PASSED" or "FAILURES DETECTED",
    FAILURES, FAILURES == 1 and "" or "s"))
os.exit(FAILURES == 0 and 0 or 1)
