---Repeat the maxTimeout comparison from a file (inline -e scripts panicked
---with "bad callback"; files are the stable harness).
package.path = "backend/?.lua;tests/?.lua;" .. package.path
pcall(function() require("jit").off(true) end)
local ffi_http = require("ffi_http")
local purejson = require("purejson")
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

local function probe(label, maxTimeout, curl_tmo)
    local t0 = ffi_http.wall_ms()
    local r = ffi_http.fetch_one({
        url = "http://10.9.0.128:8191/v1", method = "POST",
        body = purejson.encode({ cmd = "request.get",
            url = "https://csstats.gg/player/76561197960265728/stats",
            maxTimeout = maxTimeout, userAgent = UA }),
        headers = { ["Content-Type"] = "application/json" },
        timeout_ms = curl_tmo,
    }, { max_wait_ms = curl_tmo + 5000 })
    local msg, sol_status, resp_len = nil, nil, -1
    if r and r.body then
        local dok, d = pcall(purejson.decode, r.body)
        if dok and type(d) == "table" then
            msg = tostring(d.message)
            if type(d.solution) == "table" then
                sol_status = tostring(d.solution.status)
                resp_len = d.solution.response and #d.solution.response or 0
            end
        end
    end
    print(string.format("%-42s ok=%s st=%s err=%s in %.1fs msg=%s sol=%s resp_len=%d",
        label, tostring(r and r.ok), tostring(r and r.status), tostring(r and r.error),
        (ffi_http.wall_ms() - t0) / 1000, tostring(msg), tostring(sol_status), resp_len))
end

probe("maxTimeout=60000 curl=65000 (pipeline cfg)", 60000, 65000)
probe("maxTimeout=45000 curl=70000 (debug cfg)", 45000, 70000)
