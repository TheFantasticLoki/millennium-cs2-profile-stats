---Verbose single-pipeline tracer.
---    luajit tests/trace_pipeline.lua <provider> [steam_id]
package.path = "backend/?.lua;tests/?.lua;" .. package.path

-- Match Millennium's runtime: engine-wide JIT off (see pipeline_smoke).
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
        version = function() return "trace" end,
        ready = function() end,
    }
end
package.preload["utils"] = function() return { time = function() return os.time() end } end
package.preload["http"] = function()
    local function blocked() error("blocking http called") end
    return { request = blocked, get = blocked, post = blocked, put = blocked, delete = blocked, download = blocked }
end

local ffi_http = require("ffi_http")
local reg = require("providers/init")
local purejson = require("purejson")

require("providers.leetify")
require("providers.faceit")
require("providers.cstracker")
require("providers.csrep")
require("providers.csstats")

local NAME = arg[1] or "leetify"
local STEAM_ID = arg[2] or "76561197960265728"
local DEADLINE_S = tonumber(arg[3]) or 30

local function log(fmt, ...)
    print(string.format("[%6.0fms] " .. fmt, ffi_http.wall_ms() - T0, ...))
end

T0 = ffi_http.wall_ms()

local def = reg.get(NAME)
if def == nil or type(def.pipeline) ~= "function" then
    print("no pipeline for " .. NAME)
    os.exit(1)
end

local p = def.pipeline(STEAM_ID)
function p:finish(json)
    self.finished = true
    self.final_result = json
    log(NAME .. ": FINISH %s", (json or "?"):sub(1, 200))
end
p.inflight = 0

local s = assert(ffi_http.session())
local deadline = ffi_http.wall_ms() + DEADLINE_S * 1000
local iterations = 0

while ffi_http.wall_ms() < deadline do
    iterations = iterations + 1
    if iterations > 2000 then log("iteration guard"); break end

    if not p.finished and (p.inflight or 0) == 0 then
        local ok, reqs = pcall(p.next, p)
        if not ok then
            log(NAME .. ": next() ERROR %s", tostring(reqs))
            break
        end
        if type(reqs) == "table" then
            for _, req in ipairs(reqs) do
                req.id = req.id or (NAME .. "|" .. tostring(req.tag or "?"))
                log(NAME .. ": submit tag=%s url=%s timeout=%s", tostring(req.tag), req.url, tostring(req.timeout_ms))
                local rid, err = s:submit(req)
                if rid then
                    p.inflight = p.inflight + 1
                else
                    log(NAME .. ": submit FAILED %s", tostring(err))
                    p:handle(req, { id = req.id, ok = false, status = nil, error = tostring(err) })
                end
            end
        else
            log(NAME .. ": next() returned %s (queue empty)", type(reqs))
        end
    end

    if p.finished then break end

    if s:pending() == 0 and (p.inflight or 0) == 0 then
        log(NAME .. ": STUCK — nothing in flight, not finished")
        break
    end

    if s:pending() > 0 then
        local n = s:run_slice(deadline)
        log(NAME .. ": run_slice -> %s new completions (pending=%d)", tostring(n), s:pending())
        if n == 0 and s:pending() > 0 then
            log(NAME .. ": run_slice deadline with pending — exiting")
            break
        end
    end

    for _, resp in ipairs(s:take_completed()) do
        log(NAME .. ": completion id=%s ok=%s status=%s err=%s curl=%s body_len=%d",
            tostring(resp.id), tostring(resp.ok), tostring(resp.status),
            tostring(resp.error), tostring(resp.curl_code), #(resp.body or ""))
        if resp.body and #resp.body > 0 then
            log(NAME .. ":   body head: %s", resp.body:sub(1, 120):gsub("\n", " "))
        end
        p.inflight = math.max(0, (p.inflight or 1) - 1)
        local req = resp.req or { id = resp.id }
        local ok, err = pcall(p.handle, p, req, resp)
        if not ok then
            log(NAME .. ": handle() ERROR %s", tostring(err))
            p.finished = true
        else
            log(NAME .. ": handle done (phase=%s finished=%s inflight=%d)",
                tostring(p.phase), tostring(p.finished), p.inflight or -1)
        end
        if p.finished then break end
    end
end

if p.finished and p.final_result then
    local ok, decoded = pcall(purejson.decode, p.final_result)
    if ok and type(decoded) == "table" then
        print(string.format("RESULT %s: status=%s message=%s", NAME, tostring(decoded.status), tostring(decoded.message)))
    else
        print("RESULT " .. NAME .. ": undecodable final_result: " .. tostring(p.final_result):sub(1, 200))
    end
else
    print("RESULT " .. NAME .. ": INCOMPLETE after " .. string.format("%.0f", ffi_http.wall_ms() - T0) .. "ms")
end
s:destroy()
