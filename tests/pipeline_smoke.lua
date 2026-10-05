---Pipeline smoke test — run from the repo root:
---    luajit tests/pipeline_smoke.lua [steam_id]
---Stubs Millennium-specific modules, loads the real provider modules, and
---drives each provider's pipeline over the ffi_http session against real
---endpoints. Exercises exactly the code the coordinator runs in Steam.
package.path = "backend/?.lua;tests/?.lua;" .. package.path

-- Match Millennium's runtime: engine-wide JIT off. LuaJIT's JIT can panic
-- "bad callback" in FFI callbacks under GC pressure; the lua-host disables
-- the engine by default, so tests must too.
pcall(function() require("jit").off(true) end)

-- ---- stubs (must be registered before provider modules load) ----
local mock_config = {
    flaresolverr_url = "http://10.9.0.128:8191",
}
package.preload["json"] = function() return require("purejson") end
package.preload["logger"] = function()
    return setmetatable({}, {
        __index = function()
            return function() end
        end,
    })
end
package.preload["millennium"] = function()
    return {
        config = {
            get = function(k) return mock_config[k] end,
            set = function(k, v) mock_config[k] = v end,
        },
        version = function() return "smoke-test" end,
        ready = function() end,
    }
end
package.preload["utils"] = function()
    return { time = function() return os.time() end }
end
-- Tripwire: pipelines must never call Millennium's blocking RPC http path.
package.preload["http"] = function()
    local function blocked()
        error("blocking http module called — pipeline used the legacy path")
    end
    return {
        request = blocked, get = blocked, post = blocked,
        put = blocked, delete = blocked, download = blocked,
    }
end

local ffi_http = require("ffi_http")
local reg = require("providers/init")
local purejson = require("purejson")

-- Load providers (each self-registers with a pipeline factory).
require("providers.leetify")
require("providers.faceit")
require("providers.cstracker")
require("providers.csrep")
require("providers.csstats")

local STEAM_ID = arg[1] or "76561197960265728"
local ORDER = { "leetify", "faceit", "csrep", "cstracker", "csstats" }
-- SMOKE_ONLY=csrep or SMOKE_ONLY=leetify,csrep restricts the run (bisect aid).
if os.getenv("SMOKE_ONLY") then
    local picked = {}
    for name in tostring(os.getenv("SMOKE_ONLY")):gmatch("[^,]+") do
        picked[#picked + 1] = name
    end
    if #picked > 0 then ORDER = picked end
end

---Drive one provider pipeline to completion (or deadline) — the same loop
---the coordinator runs, scoped to a single provider.
local T0
local function vlog(fmt, ...)
    print(string.format("[%6.0fms] " .. fmt, ffi_http.wall_ms() - T0, ...))
end

local function run_one(name, deadline_s)
    T0 = ffi_http.wall_ms()
    local def = reg.get(name)
    if def == nil or type(def.pipeline) ~= "function" then
        print(string.format("%-10s SKIP (no pipeline)", name))
        return false
    end

    local p = def.pipeline(STEAM_ID)
    function p:finish(json)
        self.finished = true
        self.final_result = json
    end
    p.inflight = 0

    local s = ffi_http.session()
    if s == nil then
        print(name .. ": session failed: " .. tostring(ffi_http.load_error()))
        return false
    end

    local deadline = ffi_http.wall_ms() + (deadline_s or 60) * 1000
    local t0 = ffi_http.wall_ms()

    while ffi_http.wall_ms() < deadline do
        if not p.finished and (p.inflight or 0) == 0 then
            local ok, reqs = pcall(p.next, p)
            if not ok then
                print(name .. ": next() error: " .. tostring(reqs))
                break
            end
            if type(reqs) == "table" then
                for _, req in ipairs(reqs) do
                    req.id = req.id or (name .. "|" .. tostring(req.tag or "?"))
                    vlog(name .. ": submit tag=%s url=%s timeout=%s", tostring(req.tag), req.url, tostring(req.timeout_ms))
                    local rid, err = s:submit(req)
                    if rid then
                        p.inflight = p.inflight + 1
                    else
                        vlog(name .. ": submit FAILED %s", tostring(err))
                        p:handle(req, { id = req.id, ok = false, status = nil, error = tostring(err) })
                        if p.finished then break end
                    end
                end
            else
                vlog(name .. ": next() returned %s", type(reqs))
            end
        end

        if p.finished then break end

        if s:pending() == 0 and (p.inflight or 0) == 0 then
            print(name .. ": STUCK (nothing in flight, not finished)")
            break
        end

        if s:pending() > 0 then
            local n = s:run_slice(deadline)
            vlog(name .. ": run_slice -> %s (pending=%d)", tostring(n), s:pending())
            if n == 0 and s:pending() > 0 then break end
        end

        for _, resp in ipairs(s:take_completed()) do
            vlog(name .. ": completion id=%s ok=%s status=%s err=%s body_len=%d",
                tostring(resp.id), tostring(resp.ok), tostring(resp.status),
                tostring(resp.error), #(resp.body or ""))
            p.inflight = math.max(0, (p.inflight or 1) - 1)
            local req = resp.req or { id = resp.id }
            local ok, err = pcall(p.handle, p, req, resp)
            if not ok then
                vlog(name .. ": handle() ERROR %s", tostring(err))
                p.finished = true
            else
                vlog(name .. ": handle done (phase=%s finished=%s)", tostring(p.phase), tostring(p.finished))
            end
            if p.finished then break end
        end
    end

    local dt = ffi_http.wall_ms() - t0
    s:destroy()

    if p.finished and type(p.final_result) == "string" then
        local ok, decoded = pcall(purejson.decode, p.final_result)
        local status = ok and type(decoded) == "table" and tostring(decoded.status) or "?"
        print(string.format("%-10s DONE   %6.0fms  status=%s", name, dt, status))
        return status == "ok"
    end
    print(string.format("%-10s FAILED %6.0fms  (incomplete)", name, dt))
    return false
end

print("== provider pipeline smoke (steam_id=" .. STEAM_ID .. ") ==")
-- NOTE: do NOT pre-create/destroy a session here — creating a throwaway
-- multi and cleaning it up before the first real session somehow poisons
-- subsequent curl_multi runs (requests hang to timeout). Each run_one
-- creates its own session directly.

local pass, total = 0, 0
for _, name in ipairs(ORDER) do
    total = total + 1
    if run_one(name, 70) then
        pass = pass + 1
    end
end
print(string.format("== %d/%d pipelines returned status=ok ==", pass, total))
