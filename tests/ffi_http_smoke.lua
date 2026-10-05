---Local A/B smoke test for backend/ffi_http.lua — run with:
---    luajit tests/ffi_http_smoke.lua
---from the repo root. Validates the FFI curl layer OUTSIDE Millennium:
---serial vs concurrent fetch of the same 3 real endpoints.
package.path = "backend/?.lua;" .. package.path

-- Match Millennium's runtime: engine-wide JIT off (see pipeline_smoke).
pcall(function() require("jit").off(true) end)

local http = require("ffi_http")

local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then
    print("FAIL: no ffi in this LuaJIT: " .. tostring(ffi))
    os.exit(1)
end

assert(pcall(ffi.cdef, "int clock_gettime(int clk_id, void *tp);"))
local ts = ffi.new("long[2]") -- {tv_sec, tv_nsec} on LP64
local function wall_ms()
    ffi.C.clock_gettime(1, ffi.cast("void*", ts)) -- CLOCK_MONOTONIC
    return tonumber(ts[0]) * 1000 + tonumber(ts[1]) / 1e6
end

local UA = "millennium-cs2-profile-stats/0.5.0 ffi-smoke"

local requests = {
    {
        id = "leetify",
        url = "https://api-public.cs-prod.leetify.com/v3/profile?steam64_id=76561197960265728",
        user_agent = UA,
        timeout_ms = 15000,
    },
    {
        id = "faceit",
        url = "https://faceit-finder.com/api/search/steam",
        method = "POST",
        headers = { ["Content-Type"] = "application/json" },
        body = '{"steamUrl":"https://steamcommunity.com/profiles/76561197960265728"}',
        user_agent = UA,
        timeout_ms = 15000,
    },
    {
        id = "cstracker",
        url = "https://cstracker.gg/players/76561197960265728",
        headers = { ["Accept"] = "text/html,application/xhtml+xml" },
        user_agent = UA,
        timeout_ms = 20000,
    },
}

print("== serial (one at a time) ==")
local serial_total = 0
for _, req in ipairs(requests) do
    local t0 = wall_ms()
    local r = http.fetch_one({
        url = req.url,
        method = req.method,
        headers = req.headers,
        body = req.body,
        user_agent = req.user_agent,
        timeout_ms = req.timeout_ms,
    })
    local dt = wall_ms() - t0
    serial_total = serial_total + dt
    if r and r.ok then
        print(string.format("  %-10s HTTP %s  %6.0fms  body=%d bytes",
            req.id, tostring(r.status), dt, #(r.body or "")))
    else
        print(string.format("  %-10s FAILED  %6.0fms  %s",
            req.id, dt, tostring(r and (r.error or r.curl_code) or "nil")))
    end
end
print(string.format("  serial total: %.0fms", serial_total))

print("== concurrent (curl_multi pump) ==")
local t0 = wall_ms()
local results, perr = http.fetch_all(requests, { max_wait_ms = 90000 })
local wall = wall_ms() - t0
if not results then
    print("FAIL: fetch_all error: " .. tostring(perr))
    os.exit(1)
end
for _, r in ipairs(results) do
    if r.ok then
        print(string.format("  %-10s HTTP %s  %6.0fms  body=%d bytes",
            tostring(r.id), tostring(r.status), r.ms or 0, #(r.body or "")))
    else
        print(string.format("  %-10s FAILED  %6.0fms  %s (curl=%s)",
            tostring(r.id), r.ms or 0, tostring(r.error), tostring(r.curl_code)))
    end
end
print(string.format("  parallel wall: %.0fms", wall))
print(string.format("  speedup: %.2fx  (serial %.0fms / parallel %.0fms)",
    serial_total / math.max(wall, 1), serial_total, wall))

if wall < serial_total then
    print("RESULT: PASS — parallel wall time is below serial sum")
    os.exit(0)
else
    print("RESULT: WEAK — parallel wall not below serial sum (network variance? re-run)")
    os.exit(2)
end
