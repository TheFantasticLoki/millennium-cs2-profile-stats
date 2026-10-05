---Coordinator smoke — exercises the REAL production pump loop (all providers
---in ONE shared ffi_http session) with Millennium modules stubbed.
---    luajit tests/coordinator_smoke.lua [steam_id]
---Simulates the frontend firing provider routes: the first coordinator.get
---must fan out every unfinished provider concurrently; later calls should
---hit cache and return instantly. Wall time ≈ slowest provider, not the sum.
package.path = "backend/?.lua;tests/?.lua;" .. package.path
pcall(function() require("jit").off(true) end)

local mock_config = { flaresolverr_url = "http://10.9.0.128:8191" }
package.preload["json"] = function() return require("purejson") end
package.preload["logger"] = function()
    return setmetatable({}, { __index = function() return function() end end })
end
package.preload["millennium"] = function()
    return {
        config = {
            get = function(k) return mock_config[k] end,
            set = function(k, v) mock_config[k] = v end,
        },
        version = function() return "coord-smoke" end,
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
local reg = require("providers/init")

require("providers.leetify")
require("providers.faceit")
require("providers.cstracker")
require("providers.csrep")
require("providers.csstats")

local STEAM_ID = arg[1] or "76561197960265728"
local ORDER = { "leetify", "faceit", "csrep", "cstracker", "csstats" }

print("== coordinator smoke (steam_id=" .. STEAM_ID .. ") ==")
print("parallel_available: " .. tostring(coordinator.parallel_available()))

---Simulate the frontend: fire every provider route back-to-back, timing
---each call — exactly what webkit/index.tsx does. With the target-aware
---pump each call returns when ITS provider completes; earlier calls'
---pumps advanced the other pipelines, so later calls are fast.
local first_call_ms = 0
for i, name in ipairs(ORDER) do
    local t0 = ffi_http.wall_ms()
    local result = coordinator.get(name, STEAM_ID)
    local dt = ffi_http.wall_ms() - t0
    if i == 1 then first_call_ms = dt end

    local ok, decoded = pcall(purejson.decode, result)
    local status = ok and type(decoded) == "table" and tostring(decoded.status) or "?"
    local msg = ok and type(decoded) == "table" and tostring(decoded.message or ""):sub(1, 60) or ""
    print(string.format("%-10s call=%7.0fms status=%-22s %s", name, dt, status, msg))
end

print(string.format("progressive: calls resolve as each provider completes (first=%.0fms);", first_call_ms))
print("total wall ≈ slowest provider; UI segments fill in as data arrives")
