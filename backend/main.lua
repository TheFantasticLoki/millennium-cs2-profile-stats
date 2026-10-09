local cjson = require("json")
local logger = require("logger")
local millennium = require("millennium")
local reg = require("providers/init")
local cache = require("cache")
local coordinator = require("coordinator")
local aggregator = require("providers/aggregator")

-- Load all providers (each self-registers via reg.register())
require("providers.leetify")
require("providers.faceit")
require("providers.cstracker")
require("providers.csrep")
require("providers.csstats")
--require("providers.cs2tracker")
--require("providers.tracker")

local PLUGIN_VERSION = "0.5.0"

---Canonical provider fetch priority: fast public APIs first, HTML scrapers
---last. Mirrors the frontend's PROVIDER_ORDER in webkit/index.tsx so the
---loading segments fill in value order.
local FETCH_PRIORITY = { "leetify", "faceit", "csrep", "cstracker", "csstats" }

---An aggregation is already running for this steam ID: serve the stale
---result (if any) instead of duplicating every provider fetch.
local agg_inflight = {}

local function set_default(key, value)
    if millennium.config.get(key) == nil then
        millennium.config.set(key, value)
    end
end

local function on_load()
    logger:info("Loading CS2 Profile Stats v" .. PLUGIN_VERSION .. " on Millennium " .. millennium.version())
    -- TEMP (parallel-HTTP experiment): FFI + libcurl feasibility probe.
    -- pcall-guarded; results also land in config key ffi_probe_result.
    pcall(function() require("ffi_probe").run() end)
    set_default("show_steam_details", true)
    set_default("expand_details", false)
    set_default("flaresolverr_url", "")
    -- Provider enable/disable defaults (all enabled by default)
    local provider_names = {"leetify", "faceit", "cstracker", "csrep", "csstats", "cs2tracker", "tracker"}
    for _, name in ipairs(provider_names) do
        set_default("provider_" .. name .. "_enabled", true)
    end
    millennium.ready()
end

local function on_unload()
    logger:info("Unloading CS2 Profile Stats")
    -- Tear down the shared libcurl session and pipeline state so a plugin
    -- toggle-off doesn't leave in-flight transfers (sockets, easy handles,
    -- body buffers) resident in the lua-host process until Steam exits.
    pcall(coordinator.shutdown)
end

---IPC: Get plugin preferences.
function get_preferences()
    return reg.encode({
        show_steam_details = millennium.config.get("show_steam_details") ~= false,
        expand_details = millennium.config.get("expand_details") == true,
        flaresolverr_url = millennium.config.get("flaresolverr_url") or "",
    })
end

---IPC: Fetch a single provider (parallel pump + cache + coalescing).
function get_provider(provider_name, steamId)
    return coordinator.get(provider_name, steamId)
end

---IPC: Fetch all providers at once.
function get_all_providers(steamId)
    return coordinator.get_all(steamId)
end

---IPC: Get Leetify profile (backwards compatible).
function get_leetify_profile(steamId)
    return get_provider("leetify", steamId)
end

---IPC: Get FACEIT profile (backwards compatible).
function get_faceit_profile(steamId)
    return get_provider("faceit", steamId)
end

---IPC: Get CSTracker profile.
function get_cstracker_profile(steamId)
    return get_provider("cstracker", steamId)
end

---IPC: Get CSRep profile.
function get_csrep_profile(steamId)
    return get_provider("csrep", steamId)
end

---IPC: Get CSStats profile.
function get_csstats_profile(steamId)
    return get_provider("csstats", steamId)
end

---IPC: Get aggregated player profile from all enabled providers.
---Merges data from all providers into a unified schema with normalization
---and cross-provider match matching. Returns partial results if some providers
---haven't finished or returned errors.
function get_aggregated_profile(steamId)
    if not reg.valid_steam_id(steamId) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    -- Check aggregated cache first
    local cached = cache:get("aggregated", steamId)
    if cached ~= nil then
        return cached
    end

    -- An identical aggregation is already running: serve the stale result
    -- (if any) instead of duplicating every provider fetch.
    if agg_inflight[steamId] then
        local stale = cache:get_stale("aggregated", steamId)
        if stale ~= nil then
            logger:info("[aggregated] identical fetch in flight for " .. steamId .. "; serving stale cache")
            return stale
        end
    end

    -- Collect responses from all enabled providers in fetch-priority order
    -- (fast APIs first so the most valuable segments fill earliest). Each
    -- coordinator.get pumps the shared parallel session — the first call
    -- fans out every unfinished provider concurrently.
    local responses = {}
    for _, name in ipairs(FETCH_PRIORITY) do
        if reg.is_provider_enabled(name) then
            responses[name] = coordinator.get(name, steamId)
        end
    end

    -- Build aggregated profile. Wrapped in pcall so an unexpected shape
    -- in any provider payload degrades to a structured error response
    -- (and a log line) instead of blowing up the IPC call with a Lua
    -- traceback the frontend can't surface.
    agg_inflight[steamId] = true
    local agg_ok, result = pcall(aggregator.aggregate, responses)
    agg_inflight[steamId] = nil
    if not agg_ok or type(result) ~= "string" then
        logger:error("[aggregated] aggregator.aggregate failed: " .. tostring(result))
        return reg.encode({
            status = "error",
            message = "Aggregation failed: " .. tostring(result),
        })
    end

    -- Cache the aggregated result (use the shortest TTL among providers).
    -- Only successful profiles are cached — a transient aggregation error
    -- must be retried on the next render, not pinned in the cache.
    local ok, parsed = pcall(cjson.decode, result)
    if ok and type(parsed) == "table" and parsed.status ~= "error" then
        cache:set("aggregated", steamId, result)
    end

    return result
end

---IPC: Get aggregated profile and also return individual provider responses.
---Useful for the frontend to show both the aggregated view and per-provider details.
function get_aggregated_with_providers(steamId)
    if not reg.valid_steam_id(steamId) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    local aggregated = get_aggregated_profile(steamId)

    -- Also collect individual provider responses
    local providers = {}
    for _, name in ipairs(FETCH_PRIORITY) do
        if reg.is_provider_enabled(name) then
            local cached = cache:get(name, steamId)
            if cached ~= nil then
                providers[name] = cached
            end
        end
    end

    return reg.encode({
        aggregated = aggregated,
        providers = providers,
    })
end

---IPC: Get CS2Tracker profile.
--function get_cs2tracker_profile(steamId)
--    return get_provider("cs2tracker", steamId)
--end

---IPC: Get Tracker.GG profile.
--function get_tracker_profile(steamId)
--    return get_provider("tracker", steamId)
--end

---IPC: Get all provider names and their display names.
function get_provider_list()
    local all = reg.get_all()
    local list = {}
    for name, def in pairs(all) do
        list[#list + 1] = {
            name = name,
            display_name = def.display_name,
            config_key = def.config_key,
        }
    end
    return reg.encode(list)
end

---IPC: Check provider cache status.
function get_provider_status(steamId)
    if not reg.valid_steam_id(steamId) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    local all = reg.get_all()
    local statuses = {}
    for name, def in pairs(all) do
        local cached = cache:get(name, steamId)
        statuses[name] = {
            cached = cached ~= nil,
            display_name = def.display_name,
        }
    end
    return reg.encode(statuses)
end

---IPC: Get all provider configurations for the settings UI.
function get_provider_configs()
    return reg.get_provider_configs()
end

---IPC: Toggle a provider on/off.
function toggle_provider(provider_name, enabled)
    if type(provider_name) ~= "string" or provider_name == "" then
        return reg.encode({ status = "error", message = "Invalid provider name." })
    end

    local config_key = "provider_" .. provider_name .. "_enabled"
    millennium.config.set(config_key, enabled == true or enabled == "true")
    logger:info("Provider " .. provider_name .. " " .. (enabled and "enabled" or "disabled"))
    return reg.encode({ status = "ok", provider = provider_name, enabled = enabled == true or enabled == "true" })
end

---IPC: Set a provider-specific config value (e.g. API key).
function set_provider_config(provider_name, key, value)
    if type(provider_name) ~= "string" or provider_name == "" then
        return reg.encode({ status = "error", message = "Invalid provider name." })
    end
    if type(key) ~= "string" or key == "" then
        return reg.encode({ status = "error", message = "Invalid config key." })
    end

    reg.set_provider_config(provider_name, key, value)
    logger:info("Set provider config: " .. provider_name .. "." .. key .. " = " .. tostring(value))
    return reg.encode({ status = "ok", provider = provider_name, key = key })
end

---IPC: Get a provider-specific config value.
function get_provider_config_value(provider_name, key)
    if type(provider_name) ~= "string" or provider_name == "" then
        return reg.encode({ status = "error", message = "Invalid provider name." })
    end
    if type(key) ~= "string" or key == "" then
        return reg.encode({ status = "error", message = "Invalid config key." })
    end

    local value = reg.get_provider_config(provider_name, key)
    return reg.encode({ status = "ok", provider = provider_name, key = key, value = value })
end

---IPC: Get all plugin settings (preferences + provider configs).
function get_all_settings()
    local provider_names = {"leetify", "faceit", "cstracker", "csrep", "csstats", "cs2tracker", "tracker"}
    local provider_configs = {}
    for _, name in ipairs(provider_names) do
        provider_configs[name] = {
            enabled = reg.is_provider_enabled(name),
        }
    end

    return reg.encode({
        show_steam_details = millennium.config.get("show_steam_details") ~= false,
        expand_details = millennium.config.get("expand_details") == true,
        flaresolverr_url = millennium.config.get("flaresolverr_url") or "",
        leetify_api_key = millennium.config.get("leetify_api_key") or "",
        providers = provider_configs,
    })
end

return {
    on_load = on_load,
    on_unload = on_unload,
}
