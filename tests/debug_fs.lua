---Debug: FlareSolverr behavior against the CF-protected provider sites.
package.path = "backend/?.lua;tests/?.lua;" .. package.path

local ffi_http = require("ffi_http")

local function fs_test(label, payload, curl_timeout_ms)
    print("== " .. label .. " ==")
    local t0 = ffi_http.wall_ms()
    local r = ffi_http.fetch_one({
        url = "http://10.9.0.128:8191/v1",
        method = "POST",
        body = require("purejson").encode(payload),
        headers = { ["Content-Type"] = "application/json" },
        timeout_ms = curl_timeout_ms,
    }, { max_wait_ms = curl_timeout_ms + 5000 })
    local dt = ffi_http.wall_ms() - t0
    if r == nil then
        print(string.format("  NIL RESULT after %.0fms", dt))
        return
    end
    print(string.format("  ok=%s status=%s err=%s curl=%s in %.0fms body_len=%d",
        tostring(r.ok), tostring(r.status), tostring(r.error), tostring(r.curl_code), dt, #(r.body or "")))
    if r.body and #r.body > 0 then
        local ok, data = pcall(require("purejson").decode, r.body)
        if ok and type(data) == "table" then
            local sol = data.solution
            print("  FS status=" .. tostring(data.status) .. " msg=" .. tostring(data.message))
            if type(sol) == "table" then
                print("  solution.status=" .. tostring(sol.status) .. " response_len=" .. tostring(sol.response and #sol.response or 0))
                local cookies = sol.cookies or {}
                print("  cookies=" .. tostring(#cookies))
                for _, c in ipairs(cookies) do
                    print("    cookie: " .. tostring(c.name) .. " (len " .. tostring(c.value and #c.value or 0) .. ")")
                end
            end
        else
            print("  raw body head: " .. (r.body or ""):sub(1, 200):gsub("\n", " "))
        end
    end
end

local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

fs_test("csrep.gg homepage (session=csrep, maxTimeout=15s)", {
    cmd = "request.get",
    url = "https://csrep.gg/",
    maxTimeout = 15000,
    session = "csrep",
    userAgent = UA,
}, 45000)

fs_test("csstats.gg stats page (maxTimeout=45s)", {
    cmd = "request.get",
    url = "https://csstats.gg/player/76561197960265728/stats",
    maxTimeout = 45000,
    userAgent = UA,
}, 70000)
