---@meta

---Session-based cache for provider responses.
---Cache entries are stored in memory and expire based on per-provider TTLs.

local logger = require("logger")
local utils = require("utils")

---@class CacheEntry
---@field data string JSON-encoded response
---@field fetched_at number Unix timestamp when the data was fetched
---@field expires_at number Unix timestamp when the cache entry expires

---@class CacheManager
---@field _store table<string, CacheEntry> Internal cache storage
---@field _ttls table<string, number> Per-provider TTL in seconds
local CacheManager = {}
CacheManager.__index = CacheManager

---Default TTLs per provider (in seconds).
---Providers not listed here default to 300 seconds (5 minutes).
local DEFAULT_TTLS = {
    leetify = 3600,       -- 1 hour (stable API, generous rate limits)
    faceit = 1800,        -- 30 minutes
    cstracker = 900,      -- 15 minutes (actively updated)
    csrep = 900,          -- 15 minutes
    csstats = 1800,       -- 30 minutes
    cs2tracker = 1800,    -- 30 minutes
    tracker = 1800,       -- 30 minutes
    aggregated = 900,     -- 15 minutes (same as shortest individual provider)
}

---Create a new CacheManager instance.
---@return CacheManager
function CacheManager.new()
    local self = setmetatable({}, CacheManager)
    self._store = {}
    self._ttls = {}
    for k, v in pairs(DEFAULT_TTLS) do
        self._ttls[k] = v
    end
    return self
end

---Set a custom TTL for a provider.
---@param provider_name string
---@param ttl_seconds number
function CacheManager:set_ttl(provider_name, ttl_seconds)
    self._ttls[provider_name] = ttl_seconds
end

---Build the cache key for a provider + steam ID combination.
---@param provider_name string
---@param steam_id string
---@return string
function CacheManager:_key(provider_name, steam_id)
    return provider_name .. ":" .. steam_id
end

---Check if a cache entry exists and is still fresh.
---@param provider_name string
---@param steam_id string
---@return boolean
function CacheManager:has(provider_name, steam_id)
    return self:get(provider_name, steam_id) ~= nil
end

---Get a cached response if still fresh. Expired entries are retained in the
---store so callers can serve them stale via get_stale while a refresh runs
---(stale-while-revalidate).
---@param provider_name string
---@param steam_id string
---@return string|nil JSON-encoded response, or nil if expired/missing
function CacheManager:get(provider_name, steam_id)
    local entry = self._store[self:_key(provider_name, steam_id)]
    if entry == nil then
        return nil
    end
    if utils.time() >= entry.expires_at then
        return nil
    end
    return entry.data
end

---Get a cached response even if its TTL has expired. Returns nil only when
---nothing was ever stored for the key.
---@param provider_name string
---@param steam_id string
---@return string|nil JSON-encoded (possibly stale) response
function CacheManager:get_stale(provider_name, steam_id)
    local entry = self._store[self:_key(provider_name, steam_id)]
    if entry == nil then
        return nil
    end
    return entry.data
end

---Store a response in the cache.
---@param provider_name string
---@param steam_id string
---@param data string JSON-encoded response
---@param ttl_override? number Per-entry TTL in seconds (e.g. shorter TTLs for negative responses)
function CacheManager:set(provider_name, steam_id, data, ttl_override)
    local now = utils.time()
    local ttl = ttl_override or self._ttls[provider_name] or 300
    local key = self:_key(provider_name, steam_id)
    self._store[key] = {
        data = data,
        fetched_at = now,
        expires_at = now + ttl,
    }
end

---Invalidate all cached entries for a steam ID (used on page reload).
---@param steam_id string
function CacheManager:invalidate_for(steam_id)
    local prefix = ":" .. steam_id
    for key, _ in pairs(self._store) do
        if key:sub(-#prefix) == prefix then
            self._store[key] = nil
        end
    end
end

---Clear the entire cache.
function CacheManager:clear()
    self._store = {}
end

---Get cache stats for debugging.
---@return table
function CacheManager:stats()
    local count = 0
    local now = utils.time()
    local expired = 0
    for _, entry in pairs(self._store) do
        count = count + 1
        if now >= entry.expires_at then
            expired = expired + 1
        end
    end
    return { total = count, expired = expired }
end

return CacheManager.new()
