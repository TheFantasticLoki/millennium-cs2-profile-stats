---@meta

---Provider registry for CS2 Profile Stats
---Manages registration, configuration, and lifecycle of all data providers.

local cjson = require("json")
local http_utils = require("providers.http")
local logger = require("logger")
local millennium = require("millennium")

---@alias ProviderStatus "loading"|"ok"|"not_found"|"private"|"unauthorized"|"rate_limited"|"error"

---@class ProviderResponse
---@field status ProviderStatus
---@field message? string
---@field data? table
---@field fetched_at? number

---@class ProviderDefinition
---@field name string Unique provider identifier (e.g. "leetify", "cstracker")
---@field display_name string Human-readable name (e.g. "Leetify", "CSTracker")
---@field config_key string Config key prefix for API keys etc.
---@field fetch fun(steam_id: string): ProviderResponse
---@field enabled? fun(): boolean Whether this provider is enabled

local registry = {}
local providers = {}

---Encode a provider response to JSON string.
---@param payload ProviderResponse
---@return string
function registry.encode(payload)
    local ok, result = pcall(cjson.encode, payload)
    if ok then
        return result
    end
    logger:error("Failed to encode a provider response: " .. tostring(result))
    return [[{"status":"error","message":"Could not encode provider response."}]]
end

---Check if a value is nil or JSON null.
---@param value any
---@return boolean
function registry.is_null(value)
    return value == nil or value == cjson.null
end

---Return the value if non-nil/non-null, otherwise nil.
---@param value any
---@return any
function registry.optional(value)
    if registry.is_null(value) then
        return nil
    end
    return value
end

---Convert a value to a number or return nil.
---@param value any
---@return number|nil
function registry.number_or_nil(value)
    value = registry.optional(value)
    if type(value) == "number" then
        return value
    elseif type(value) == "string" then
        return tonumber(value)
    end
    return nil
end

---Multiply a value by 100 (for 0-1 → 0-100 scaling).
---@param value any
---@return number|nil
function registry.scaled_rating(value)
    local number = registry.number_or_nil(value)
    if number == nil then return nil end
    return number * 100
end

---Read a trimmed string from plugin config.
---@param key string
---@return string|nil
function registry.trimmed_config(key)
    local value = millennium.config.get(key)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if value == "" then return nil end
    return value
end

---Validate a SteamID64 string (17 digits).
---@param steam_id any
---@return boolean
function registry.valid_steam_id(steam_id)
    return type(steam_id) == "string" and steam_id:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") ~= nil
end

---Map HTTP status to a provider error status string.
---@param http_status number
---@return string
function registry.error_status(http_status)
    if http_status == 401 or http_status == 403 then
        return "unauthorized"
    elseif http_status == 404 then
        return "not_found"
    elseif http_status == 429 then
        return "rate_limited"
    end
    return "error"
end

---Build a provider error response.
---@param provider_name string
---@param http_status number
---@param message string
---@return string JSON-encoded response
function registry.provider_error(provider_name, http_status, message)
    local log_message = provider_name .. " request failed (" .. tostring(http_status) .. "): " .. tostring(message)
    if http_status == 404 then
        logger:info(log_message)
    else
        logger:warn(log_message)
    end
    return registry.encode({
        status = registry.error_status(http_status),
        message = message or "Provider request failed.",
    })
end

---Build a provider response for a failed HTTP call. Cloudflare fail-fast
---errors (see providers/http.lua get_raw) are translated into the structured
---cloudflare_required status; everything else falls back to provider_error.
---@param provider_name string
---@param http_status number
---@param message string
---@param url? string Profile URL hint for the verification message
---@return string JSON-encoded response
function registry.http_failure(provider_name, http_status, message, url)
    if http_utils.is_cloudflare_error(message) then
        logger:warn(provider_name .. ": Cloudflare challenge and no FlareSolverr — failing fast")
        return registry.encode({
            status = "cloudflare_required",
            message = "Visit the provider site to complete Cloudflare verification, then retry.",
            url = url,
        })
    end
    return registry.provider_error(provider_name, http_status, message or "Network request failed.")
end

---Register a provider definition.
---@param def ProviderDefinition
function registry.register(def)
    if type(def) ~= "table" or type(def.name) ~= "string" or type(def.fetch) ~= "function" then
        logger:error("Invalid provider definition for: " .. tostring(def and def.name or "?"))
        return
    end
    providers[def.name] = def
    logger:info("Registered provider: " .. def.display_name)
end

---Get all registered providers.
---@return table<string, ProviderDefinition>
function registry.get_all()
    return providers
end

---Get a specific provider by name.
---@param name string
---@return ProviderDefinition|nil
function registry.get(name)
    return providers[name]
end

---Log a summary table of all data fields returned by a provider.
---Logs each non-nil field as "field = value" so coverage and accuracy
---can be cross-referenced with the source sites.
---@param provider_name string Display name of the provider
---@param steam_id string SteamID64 being queried
---@param result_json string Raw JSON-encoded provider response
function registry.log_response_data(provider_name, steam_id, result_json)
    local ok, decoded = pcall(cjson.decode, result_json)
    if not ok or type(decoded) ~= "table" then
        logger:info("[" .. provider_name .. "] response decode failed: " .. tostring(decoded))
        return
    end

    local status = tostring(decoded.status or "unknown")
    local message = decoded.message
    local data = decoded.data

    -- Log status and any message
    if message then
        logger:info("[" .. provider_name .. "] " .. steam_id .. " → status=" .. status .. " msg=" .. tostring(message))
    else
        logger:info("[" .. provider_name .. "] " .. steam_id .. " → status=" .. status)
    end

    -- If there's no data table, nothing more to log
    if type(data) ~= "table" then return end

    -- Recursively format a value for logging (handles nested tables up to depth 2)
    ---@param val any
    ---@param depth number
    ---@return string
    local function fmt_val(val, depth)
        depth = depth or 0
        if val == nil or val == cjson.null then return "nil" end
        if type(val) ~= "table" then return tostring(val) end
        if depth >= 2 then
            local count = 0
            for _ in pairs(val) do count = count + 1 end
            return "{...}" .. count .. " keys}"
        end
        local parts = {}
        local n = 0
        for k, v in pairs(val) do
            n = n + 1
            if n > 5 then parts[#parts + 1] = "...+" .. (select('#', pairs(val)) - 5) .. "more"; break end
            if type(v) == "table" then
                parts[#parts + 1] = tostring(k) .. "=" .. fmt_val(v, depth + 1)
            else
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    -- Log every field in the data table so we can cross-reference coverage
    local field_count = 0
    local populated_count = 0
    local parts = {}
    for key, value in pairs(data) do
        field_count = field_count + 1
        local str_value = fmt_val(value, 0)
        if value ~= nil and value ~= cjson.null then
            populated_count = populated_count + 1
        end
        parts[#parts + 1] = tostring(key) .. "=" .. str_value
    end

    -- Log as one or more lines depending on size
    local header = "[" .. provider_name .. "] " .. steam_id .. " data (" .. populated_count .. "/" .. field_count .. " fields populated):"
    if #parts <= 8 then
        logger:info(header .. " " .. table.concat(parts, " | "))
    else
        logger:info(header)
        -- Break into chunks of 8 fields per line for readability
        for i = 1, #parts, 8 do
            local chunk = {}
            for j = i, math.min(i + 7, #parts) do
                chunk[#chunk + 1] = parts[j]
            end
            logger:info("  " .. table.concat(chunk, " | "))
        end
    end
end

---Fetch from a specific provider.
---@param name string
---@param steam_id string
---@return string JSON-encoded response
function registry.fetch_provider(name, steam_id)
    local provider = providers[name]
    if provider == nil then
        return registry.encode({ status = "error", message = "Unknown provider: " .. tostring(name) })
    end

    if not registry.is_provider_enabled(name) then
        return registry.encode({ status = "error", message = provider.display_name .. " is disabled." })
    end

    local start_time = os.clock()
    local ok, result = pcall(provider.fetch, steam_id)
    local elapsed_ms = (os.clock() - start_time) * 1000

    if ok and type(result) == "string" then
        logger:info("[" .. (provider.display_name or name) .. "] fetch took " .. string.format("%.0f", elapsed_ms) .. "ms")
        registry.log_response_data(provider.display_name or name, steam_id, result)
        return result
    else
        local error_msg = (provider.display_name or name) .. " threw an error: " .. tostring(result)
        logger:error(error_msg)
        return registry.encode({ status = "error", message = error_msg })
    end
end

---Canonical fetch priority (fast APIs first, scrapers last). Mirrors the
---frontend's PROVIDER_ORDER so progressive rendering fills in value order.
local FETCH_PRIORITY = { "leetify", "faceit", "csrep", "cstracker", "csstats", "cs2tracker", "tracker" }

---Fetch from all enabled providers and return results as a table.
---Providers are fetched in FETCH_PRIORITY order.
---@param steam_id string
---@return table<string, string> Map of provider name → JSON response
function registry.fetch_all(steam_id)
    local results = {}
    local total_start = os.clock()

    local ordered, seen = {}, {}
    for _, name in ipairs(FETCH_PRIORITY) do
        if providers[name] ~= nil then
            ordered[#ordered + 1] = name
            seen[name] = true
        end
    end
    for name, _ in pairs(providers) do
        if not seen[name] then
            ordered[#ordered + 1] = name
        end
    end

    for _, name in ipairs(ordered) do
        local provider = providers[name]
        if registry.is_provider_enabled(name) then
            local start_time = os.clock()
            local ok, result = pcall(provider.fetch, steam_id)
            local elapsed_ms = (os.clock() - start_time) * 1000

            if ok and type(result) == "string" then
                logger:info("[" .. (provider.display_name or name) .. "] fetch took " .. string.format("%.0f", elapsed_ms) .. "ms")
                registry.log_response_data(provider.display_name or name, steam_id, result)
                results[name] = result
            else
                logger:error((provider.display_name or name) .. " threw an error: " .. tostring(result))
                results[name] = registry.encode({
                    status = "error",
                    message = (provider.display_name or name) .. " encountered an error.",
                })
            end
        else
            logger:info((provider.display_name or name) .. ": skipped (disabled)")
        end
    end
    local total_elapsed = (os.clock() - total_start) * 1000
    logger:info("[fetch_all] all providers completed in " .. string.format("%.0f", total_elapsed) .. "ms for " .. steam_id)
    return results
end

---Check if a provider is enabled via plugin config.
---Providers are enabled by default unless explicitly disabled.
---@param name string
---@return boolean
function registry.is_provider_enabled(name)
    local provider = providers[name]
    if provider == nil then return false end

    -- Check the provider's own enabled function first
    if type(provider.enabled) == "function" then
        return provider.enabled()
    end

    -- Check plugin config: "provider_<name>_enabled" (defaults to true)
    local config_key = "provider_" .. name .. "_enabled"
    local value = millennium.config.get(config_key)
    if value == nil then return true end -- Enabled by default
    return value ~= false and value ~= "false"
end

---Get provider-specific config value.
---@param provider_name string
---@param key string
---@return string|number|boolean|nil
function registry.get_provider_config(provider_name, key)
    local config_key = "provider_" .. provider_name .. "_" .. key
    return millennium.config.get(config_key)
end

---Set provider-specific config value.
---@param provider_name string
---@param key string
---@param value string|number|boolean
function registry.set_provider_config(provider_name, key, value)
    local config_key = "provider_" .. provider_name .. "_" .. key
    millennium.config.set(config_key, value)
end

---Get all provider configurations for the settings UI.
---Returns an array of provider configs with their current state.
---@return string JSON-encoded response
function registry.get_provider_configs()
    local result = {}
    for name, provider in pairs(providers) do
        local config = {
            name = name,
            display_name = provider.display_name,
            config_key = provider.config_key,
            enabled = registry.is_provider_enabled(name),
        }

        -- Include any provider-specific config keys
        if type(provider.config_keys) == "table" then
            config.config_keys = {}
            for _, key in ipairs(provider.config_keys) do
                config.config_keys[key] = registry.get_provider_config(name, key)
            end
        end

        result[#result + 1] = config
    end
    return registry.encode(result)
end

return registry
