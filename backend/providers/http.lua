---@meta

---Shared HTTP utilities for provider modules.
---Includes optional FlareSolverr support for Cloudflare-protected sites.

local cjson = require("json")
local http = require("http")
local logger = require("logger")
local millennium = require("millennium")

local PLUGIN_VERSION = "0.5.0"
local USER_AGENT = "millennium-cs2-profile-stats/" .. PLUGIN_VERSION

---Real browser User-Agent for FlareSolverr. Cloudflare and similar services
---reject non-browser UAs, so we use a current Chrome string for JS rendering.
local CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

local http_utils = {}

---Get the standard User-Agent string.
---@return string
function http_utils.user_agent()
    return USER_AGENT
end

---Get the FlareSolverr URL from plugin config, or nil if not configured.
---@return string|nil
function http_utils.flaresolverr_url()
    local value = millennium.config.get("flaresolverr_url")
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if value == "" then return nil end
    return value
end

---Check if a response looks like a Cloudflare challenge page.
---Checks both body content and status code patterns.
---@param response HTTPResponse
---@return boolean
function http_utils.is_cloudflare_challenge(response)
    if response == nil then return false end
    local body = response.body or ""
    -- Body-based detection
    if body:match("Just a moment") then return true end
    if body:match("challenge%-platform") then return true end
    if body:match("cf_chl_opt") then return true end
    if body:match("Enable JavaScript and cookies to continue") then return true end
    if body:match("challenges%.cloudflare%.com") then return true end
    -- Status-based: 403 with small body is likely Cloudflare
    if response.status == 403 and #body < 10000 then return true end
    return false
end

---Fetch a page through FlareSolverr to bypass Cloudflare.
---@param url string The URL to fetch
---@param timeout? number Timeout in seconds (default 60)
---@return HTTPResponse|nil response, string|nil error
function http_utils.flaresolverr_get(url, timeout)
    local fs_url = http_utils.flaresolverr_url()
    if fs_url == nil then
        return nil, "FlareSolverr not configured"
    end

    local request_body = cjson.encode({
        cmd = "request.get",
        url = url,
        maxTimeout = (timeout or 60) * 1000,
        userAgent = CHROME_UA,
    })

    local response, request_error = http.request(fs_url .. "/v1", {
        method = "POST",
        data = request_body,
        headers = {
            ["Content-Type"] = "application/json",
        },
        timeout = (timeout or 60) + 5,
        follow_redirects = true,
        verify_ssl = true,
    })

    if response == nil then
        logger:warn("FlareSolverr request failed: " .. tostring(request_error))
        return nil, request_error or "FlareSolverr request failed."
    end

    if response.status < 200 or response.status >= 300 then
        logger:warn("FlareSolverr returned HTTP " .. tostring(response.status))
        return nil, "FlareSolverr HTTP " .. tostring(response.status)
    end

    local ok, data = pcall(cjson.decode, response.body)
    if not ok or type(data) ~= "table" then
        return nil, "FlareSolverr returned invalid JSON"
    end

    -- FlareSolverr wraps the response in a solution object
    local solution = data.solution
    if solution == nil or type(solution) ~= "table" then
        return nil, "FlareSolverr returned no solution"
    end

    -- Build a response object compatible with our existing code
    return {
        status = solution.status or 200,
        body = solution.response or "",
        headers = solution.headers or {},
    }, nil
end

---Perform a GET request and decode the JSON response.
---@param url string
---@param headers? table<string, string>
---@param timeout? number
---@return table|nil data, number status, string|nil error
function http_utils.get_json(url, headers, timeout)
    local response, request_error = http.get(url, {
        headers = headers,
        timeout = timeout or 10,
        follow_redirects = true,
        verify_ssl = true,
        user_agent = USER_AGENT,
    })

    if response == nil then
        return nil, 0, request_error or "Network request failed."
    end

    if response.status < 200 or response.status >= 300 then
        return nil, response.status, "HTTP " .. tostring(response.status)
    end

    local ok, data = pcall(cjson.decode, response.body)
    if not ok or type(data) ~= "table" then
        return nil, response.status, "Invalid JSON response."
    end

    return data, response.status, nil
end

---Perform a POST request and decode the JSON response.
---@param url string
---@param body string
---@param headers? table<string, string>
---@return table|nil data, number status, string|nil error
function http_utils.post_json(url, body, headers)
    local response, request_error = http.request(url, {
        method = "POST",
        data = body,
        headers = headers,
        timeout = 10,
        follow_redirects = true,
        verify_ssl = true,
        user_agent = USER_AGENT,
    })

    if response == nil then
        return nil, 0, request_error or "Network request failed."
    end

    if response.status < 200 or response.status >= 300 then
        return nil, response.status, "HTTP " .. tostring(response.status)
    end

    local ok, data = pcall(cjson.decode, response.body)
    if not ok or type(data) ~= "table" then
        return nil, response.status, "Invalid JSON response."
    end

    return data, response.status, nil
end

---Perform a GET request and return the raw response (for HTML scraping).
---If FlareSolverr is configured and the response is a Cloudflare challenge,
---automatically retries through FlareSolverr.
---@param url string
---@param headers? table<string, string>
---@param timeout? number
---@param use_flaresolverr? boolean Whether to retry via FlareSolverr on Cloudflare (default: true)
---@return HTTPResponse|nil response, string|nil error, boolean flaresolverr_used Whether FlareSolverr was used
function http_utils.get_raw(url, headers, timeout, use_flaresolverr)
    if use_flaresolverr == nil then use_flaresolverr = true end

    local response, request_error = http.get(url, {
        headers = headers,
        timeout = timeout or 10,
        follow_redirects = true,
        verify_ssl = true,
        user_agent = USER_AGENT,
    })

    if response == nil then
        return nil, request_error or "Network request failed.", false
    end

    -- Cloudflare challenge: retry through FlareSolverr when configured,
    -- otherwise fail fast with a structured error instead of handing a
    -- challenge page to the HTML/JSON parsers.
    if http_utils.is_cloudflare_challenge(response) then
        if use_flaresolverr and http_utils.flaresolverr_url() ~= nil then
            logger:info("Cloudflare challenge detected for " .. url .. ", retrying via FlareSolverr")
            local fs_response, fs_error = http_utils.flaresolverr_get(url, timeout)
            if fs_response ~= nil then
                return fs_response, nil, true
            else
                logger:warn("FlareSolverr retry failed: " .. tostring(fs_error))
            end
        end
        logger:warn("Cloudflare challenge for " .. url .. " and FlareSolverr unavailable — failing fast")
        return nil, "cloudflare_required: " .. url, false
    end

    return response, request_error, false
end

---True when an error string from get_raw marks an unresolvable Cloudflare
---challenge (FlareSolverr not configured, or its retry failed). Providers
---map this to the structured cloudflare_required status.
---@param err any
---@return boolean
function http_utils.is_cloudflare_error(err)
    return type(err) == "string" and err:find("cloudflare_required", 1, true) == 1
end

---CSRep API helpers.
---CSRep uses Cloudflare protection + a request signing mechanism for their API.
---We obtain a cf_clearance cookie via FlareSolverr, then sign each API request
---with X-Request-ID, X-Request-Timestamp, and X-Request-Secret headers.
---The secret is a DJB2-like hash of (id+timestamp) encoded in base-36.

---DJB2-like hash function matching CSRep's frontend (module 47740).
---Computes ((t << 5) - t + charCode) for each character, returns unsigned 32-bit
---integer encoded as base-36 string.
---@param s string
---@return string base36_hash
function http_utils.csrep_hash(s)
    local t = 0
    local TWO_POW_32 = 4294967296 -- 2^32
    for i = 1, #s do
        local byte = string.byte(s, i)
        t = ((t * 32) - t + byte) % TWO_POW_32
    end
    -- Encode as base-36
    if t == 0 then return "0" end
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local result = ""
    while t > 0 do
        local r = t % 36 + 1
        result = string.sub(digits, r, r) .. result
        t = math.floor(t / 36)
    end
    return result
end

---Get a fresh cf_clearance cookie from FlareSolverr by visiting csrep.gg.
---@return string|nil cookie, string|nil error
function http_utils.csrep_get_cookie()
    local fs_url = http_utils.flaresolverr_url()
    if fs_url == nil then
        return nil, "FlareSolverr not configured"
    end

    local request_body = cjson.encode({
        cmd = "request.get",
        url = "https://csrep.gg/",
        maxTimeout = 15000,
        session = "csrep",
        userAgent = CHROME_UA,
    })

    local response, request_error = http.request(fs_url .. "/v1", {
        method = "POST",
        data = request_body,
        headers = {
            ["Content-Type"] = "application/json",
        },
        timeout = 20,
        follow_redirects = true,
        verify_ssl = true,
    })

    if response == nil then
        return nil, "FlareSolverr cookie request failed: " .. tostring(request_error)
    end

    local ok, data = pcall(cjson.decode, response.body)
    if not ok or type(data) ~= "table" then
        return nil, "FlareSolverr returned invalid JSON"
    end

    local solution = data.solution
    if solution == nil or type(solution) ~= "table" then
        return nil, "FlareSolverr returned no solution"
    end

    -- Extract cf_clearance cookie from the session
    local cookies = solution.cookies or {}
    for _, cookie in ipairs(cookies) do
        if cookie.name == "cf_clearance" then
            return cookie.value, nil
        end
    end

    return nil, "No cf_clearance cookie in FlareSolverr response"
end

---Make a signed API request to csrep.gg.
---Generates proper X-Request-ID, X-Request-Timestamp, and X-Request-Secret headers,
---then makes the request through FlareSolverr session to bypass Cloudflare.
---@param url string The full API URL
---@param cf_cookie string The cf_clearance cookie
---@return table|nil data, string|nil error
function http_utils.csrep_api_get(url, cf_cookie)
    local request_id = tostring(os.time() * 1000 + math.random(0, 999))
    local timestamp = tostring(math.floor(os.time() * 1000))
    local secret = http_utils.csrep_hash(request_id .. timestamp)

    -- Try direct request first with cookie (fast path)
    local response, request_error = http.get(url, {
        headers = {
            ["X-Request-ID"] = request_id,
            ["X-Request-Timestamp"] = timestamp,
            ["X-Request-Secret"] = secret,
            ["Accept"] = "application/json, text/plain, */*",
            ["Referer"] = "https://csrep.gg/",
            ["Origin"] = "https://csrep.gg",
            ["Cookie"] = "cf_clearance=" .. cf_cookie,
        },
        timeout = 10,
        follow_redirects = true,
        verify_ssl = true,
        user_agent = CHROME_UA,
    })

    if response ~= nil and not http_utils.is_cloudflare_challenge(response) then
        local ok, data = pcall(cjson.decode, response.body)
        if ok and type(data) == "table" and data.status == "OK" then
            return data.result, nil
        end
        -- If we got a response but it's not OK, check for error
        if ok and type(data) == "table" and data.status == "ERROR" then
            return nil, data.message or "CSRep API error"
        end
    end

    -- Direct request failed (Cloudflare or error), go through FlareSolverr session
    local fs_url = http_utils.flaresolverr_url()
    if fs_url == nil then
        return nil, "Direct API failed and FlareSolverr not configured"
    end

    local fs_request_id = tostring(os.time() * 1000 + math.random(0, 999))
    local fs_timestamp = tostring(math.floor(os.time() * 1000))
    local fs_secret = http_utils.csrep_hash(fs_request_id .. fs_timestamp)

    local fs_body = cjson.encode({
        cmd = "request.get",
        url = url,
        maxTimeout = 30000,
        session = "csrep",
        userAgent = CHROME_UA,
        headers = {
            ["X-Request-ID"] = fs_request_id,
            ["X-Request-Timestamp"] = fs_timestamp,
            ["X-Request-Secret"] = fs_secret,
            ["Accept"] = "application/json, text/plain, */*",
        },
    })

    local fs_response, fs_error = http.request(fs_url .. "/v1", {
        method = "POST",
        data = fs_body,
        headers = {
            ["Content-Type"] = "application/json",
        },
        timeout = 35,
        follow_redirects = true,
        verify_ssl = true,
    })

    if fs_response == nil then
        return nil, "FlareSolverr API request failed: " .. tostring(fs_error)
    end

    local fs_ok, fs_data = pcall(cjson.decode, fs_response.body)
    if not fs_ok or type(fs_data) ~= "table" then
        return nil, "FlareSolverr returned invalid JSON"
    end

    local solution = fs_data.solution
    if solution == nil or type(solution) ~= "table" then
        return nil, "FlareSolverr returned no solution"
    end

    local body = solution.response or ""
    local parse_ok, parsed = pcall(cjson.decode, body)
    if parse_ok and type(parsed) == "table" then
        if parsed.status == "OK" then
            return parsed.result, nil
        elseif parsed.status == "ERROR" then
            return nil, parsed.message or "CSRep API error"
        end
    end

    -- Try parsing HTML-wrapped JSON (FlareSolverr wraps responses in <html><pre>)
    local json_match = body:match("<pre>(.-)</pre>")
    if json_match then
        local inner_ok, inner_data = pcall(cjson.decode, json_match)
        if inner_ok and type(inner_data) == "table" then
            if inner_data.status == "OK" then
                return inner_data.result, nil
            elseif inner_data.status == "ERROR" then
                return nil, inner_data.message or "CSRep API error"
            end
        end
    end

    return nil, "Could not parse CSRep API response"
end

-- ---------------------------------------------------------------------------
-- Pipeline helpers (parallel ffi_http pump path)
--
---These build request descriptors for backend/ffi_http.lua sessions and
---decode pump responses with the same contracts as the blocking helpers
---above, so provider logic behaves identically on both paths.
-- ---------------------------------------------------------------------------

---Chrome UA string (FlareSolverr / Cloudflare-sensitive calls).
---@return string
function http_utils.chrome_user_agent()
    return CHROME_UA
end

---Build a direct GET request descriptor for the ffi pump.
---@param url string
---@param headers? table<string,string>
---@param timeout? number seconds (default 10)
---@param opts? { user_agent?: string, referer?: string }
---@return table req
function http_utils.get_req(url, headers, timeout, opts)
    opts = opts or {}
    return {
        url = url,
        method = "GET",
        headers = headers,
        timeout_ms = (timeout or 10) * 1000,
        user_agent = opts.user_agent or USER_AGENT,
        referer = opts.referer,
    }
end

---Build a direct POST request descriptor for the ffi pump.
---@param url string
---@param body string
---@param headers? table<string,string>
---@param timeout? number seconds (default 10)
---@param opts? { user_agent?: string, referer?: string }
---@return table req
function http_utils.post_req(url, body, headers, timeout, opts)
    opts = opts or {}
    return {
        url = url,
        method = "POST",
        body = body,
        headers = headers,
        timeout_ms = (timeout or 10) * 1000,
        user_agent = opts.user_agent or USER_AGENT,
        referer = opts.referer,
    }
end

---Decode a pump response body as JSON — same contract as get_json:
---returns data, status, error (status 0 on transport failure).
---@param resp table|nil ffi_http result table
---@return table|nil data, number status, string|nil error
function http_utils.resp_json(resp)
    if resp == nil then
        return nil, 0, "Network request failed."
    end
    if resp.status == nil then
        return nil, 0, resp.error or "Network request failed."
    end
    if resp.status < 200 or resp.status >= 300 then
        return nil, resp.status, "HTTP " .. tostring(resp.status)
    end
    local ok, data = pcall(cjson.decode, resp.body or "")
    if not ok or type(data) ~= "table" then
        return nil, resp.status, "Invalid JSON response."
    end
    return data, resp.status, nil
end

---Build the fail-fast Cloudflare error marker (see get_raw / is_cloudflare_error).
---@param url string
---@return string
function http_utils.cloudflare_error(url)
    return "cloudflare_required: " .. url
end

---Build a FlareSolverr POST /v1 request descriptor for the ffi pump.
---@param fs_url string
---@param payload table FlareSolverr command payload
---@param timeout_s? number (default 60)
---@return table req
function http_utils.fs_req(fs_url, payload, timeout_s)
    return {
        url = fs_url .. "/v1",
        method = "POST",
        body = cjson.encode(payload),
        headers = { ["Content-Type"] = "application/json" },
        timeout_ms = ((timeout_s or 60) + 5) * 1000,
    }
end

---Decode a FlareSolverr /v1 pump response into its `solution` table.
---@param resp table|nil
---@return table|nil solution, string|nil error
function http_utils.fs_solution(resp)
    if resp == nil then
        return nil, "FlareSolverr request failed."
    end
    if resp.status == nil then
        return nil, resp.error or "FlareSolverr request failed."
    end
    if resp.status < 200 or resp.status >= 300 then
        return nil, "FlareSolverr HTTP " .. tostring(resp.status)
    end
    local ok, data = pcall(cjson.decode, resp.body or "")
    if not ok or type(data) ~= "table" then
        return nil, "FlareSolverr returned invalid JSON"
    end
    local solution = data.solution
    if solution == nil or type(solution) ~= "table" then
        return nil, "FlareSolverr returned no solution"
    end
    return solution, nil
end

---Extract a cf_clearance cookie from an FS solution's cookies array.
---@param solution table|nil
---@return string|nil cookie
function http_utils.fs_cf_cookie(solution)
    if type(solution) ~= "table" then return nil end
    local cookies = solution.cookies or {}
    for _, cookie in ipairs(cookies) do
        if type(cookie) == "table" and cookie.name == "cf_clearance" then
            return cookie.value
        end
    end
    return nil
end

---Build a signed csrep API request descriptor for the ffi pump (generates
---fresh X-Request-ID/Timestamp/Secret headers per call).
---@param url string
---@param cf_cookie string
---@param timeout_s? number (default 10)
---@return table req
function http_utils.csrep_signed_req(url, cf_cookie, timeout_s)
    local request_id = tostring(os.time() * 1000 + math.random(0, 999))
    local timestamp = tostring(math.floor(os.time() * 1000))
    local secret = http_utils.csrep_hash(request_id .. timestamp)
    return {
        url = url,
        method = "GET",
        headers = {
            ["X-Request-ID"] = request_id,
            ["X-Request-Timestamp"] = timestamp,
            ["X-Request-Secret"] = secret,
            ["Accept"] = "application/json, text/plain, */*",
            ["Referer"] = "https://csrep.gg/",
            ["Origin"] = "https://csrep.gg",
            ["Cookie"] = "cf_clearance=" .. cf_cookie,
        },
        timeout_ms = (timeout_s or 10) * 1000,
        user_agent = CHROME_UA,
    }
end

---Decode a csrep API response body (direct JSON or FS <html><pre>-wrapped).
---Mirrors the fallback ladder in csrep_api_get: OK envelope → result,
---ERROR envelope → error, unrecognized/undecodable → "unknown"/"invalid"
---so the caller can decide whether to fall back to FlareSolverr.
---@param body string|nil
---@return any result, string|nil error, string state "ok"|"error"|"unknown"|"invalid"
function http_utils.csrep_decode_body(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty or invalid player payload", "invalid"
    end
    local ok, data = pcall(cjson.decode, body)
    if ok and type(data) == "table" then
        if data.status == "OK" then
            return data.result, nil, "ok"
        elseif data.status == "ERROR" then
            return nil, data.message or "CSRep API error", "error"
        end
        return nil, nil, "unknown"
    end
    local json_match = body:match("<pre>(.-)</pre>")
    if json_match then
        local inner_ok, inner = pcall(cjson.decode, json_match)
        if inner_ok and type(inner) == "table" then
            if inner.status == "OK" then
                return inner.result, nil, "ok"
            elseif inner.status == "ERROR" then
                return nil, inner.message or "CSRep API error", "error"
            end
            return nil, nil, "unknown"
        end
    end
    return nil, "Could not parse CSRep API response", "invalid"
end

return http_utils
