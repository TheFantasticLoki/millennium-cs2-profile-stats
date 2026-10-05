---Debug: FS reachability + raw pipeline responses for the failing providers.
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
        version = function() return "debug" end,
        ready = function() end,
    }
end
package.preload["utils"] = function() return { time = function() return os.time() end } end
package.preload["http"] = function()
    local function blocked() error("blocking http called") end
    return { request = blocked, get = blocked, post = blocked, put = blocked, delete = blocked, download = blocked }
end

local ffi_http = require("ffi_http")

local function show(label, r)
    if r == nil then
        print(label .. ": NIL RESULT")
        return
    end
    print(string.format("%s: ok=%s status=%s err=%s curl=%s ms=%s body_len=%d",
        label, tostring(r.ok), tostring(r.status), tostring(r.error),
        tostring(r.curl_code), tostring(r.ms), #(r.body or "")))
    if r.body and #r.body > 0 and #r.body < 400 then
        print("  body: " .. r.body:gsub("\n", " "):sub(1, 300))
    elseif r.body and #r.body >= 400 then
        print("  body head: " .. r.body:sub(1, 200):gsub("\n", " "))
    end
end

-- 1) FS reachability: simple request.get to example.com through FS /v1
print("== FlareSolverr reachability ==")
local t0 = ffi_http.wall_ms()
local fs_resp = ffi_http.fetch_one({
    url = "http://10.9.0.128:8191/v1",
    method = "POST",
    body = '{"cmd":"request.get","url":"https://example.com","maxTimeout":20000}',
    headers = { ["Content-Type"] = "application/json" },
    timeout_ms = 30000,
}, { max_wait_ms = 35000 })
show("fs/example.com", fs_resp)
print(string.format("  wall: %.0fms", ffi_http.wall_ms() - t0))

-- 2) Leetify: public + legacy raw responses
print("== leetify raw ==")
local lr = ffi_http.fetch_all({
    { id = "pub", url = "https://api-public.cs-prod.leetify.com/v3/profile?steam64_id=76561197960265728",
      headers = { ["Accept"] = "application/json" }, timeout_ms = 10000,
      user_agent = "millennium-cs2-profile-stats/0.5.0" },
    { id = "legacy", url = "https://api.cs-prod.leetify.com/api/profile/id/76561197960265728",
      headers = { ["Accept"] = "application/json", ["Origin"] = "https://leetify.com", ["Referer"] = "https://leetify.com/" },
      timeout_ms = 10000, user_agent = "millennium-cs2-profile-stats/0.5.0" },
}, { max_wait_ms = 25000 })
for _, r in ipairs(lr or {}) do show("leetify/" .. tostring(r.id), r) end

-- 3) cstracker page raw
print("== cstracker raw ==")
local cr = ffi_http.fetch_one({
    url = "https://cstracker.gg/players/76561197960265728",
    headers = {
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
    },
    timeout_ms = 15000,
    user_agent = "millennium-cs2-profile-stats/0.5.0",
}, { max_wait_ms = 20000 })
show("cstracker/page", cr)
if cr and cr.body then
    local http_utils = require("providers.http")
    print("  is_cloudflare_challenge:", tostring(http_utils.is_cloudflare_challenge(cr)))
    print("  has premier:", tostring(cr.body:match("premier") ~= nil),
          "trust:", tostring(cr.body:match("trust") ~= nil),
          "rating:", tostring(cr.body:match("rating") ~= nil))
end
