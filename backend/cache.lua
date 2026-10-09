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

---Hard cap on retained cache entries. Expired entries are kept briefly so
---get_stale can serve them while a refresh runs (stale-while-revalidate),
---but without a cap the store grew without bound across a long Steam
---session — every profile view added provider × SteamID JSON payloads that
---were never released.
local MAX_ENTRIES = 256

---How long an expired entry is retained for stale serving (seconds) before
---eviction may reclaim it. Comfortably exceeds the longest provider TTL
---reuse window observed in practice (a few profile re-views).
local STALE_RETENTION_S = 3600

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

---Evict entries the store can afford to lose: anything expired beyond the
---stale-retention window first, then (if still over the cap) the oldest
---fetched entries regardless of freshness. Called from set() so the store
---stays bounded without a background timer.
---@param now number current unix time
function CacheManager:_prune(now)
    local count = 0
    for _ in pairs(self._store) do count = count + 1 end
    if count <= MAX_ENTRIES then
        -- Under cap: still reclaim entries too old to be useful as stale.
        for key, entry in pairs(self._store) do
            if now >= entry.expires_at + STALE_RETENTION_S then
                self._store[key] = nil
            end
        end
        return
    end
    -- Over cap: drop long-expired entries, then oldest-first until under.
    local entries = {}
    for key, entry in pairs(self._store) do
        entries[#entries + 1] = { key = key, fetched_at = entry.fetched_at, expires_at = entry.expires_at }
    end
    table.sort(entries, function(a, b) return a.fetched_at < b.fetched_at end)
    local excess = count - MAX_ENTRIES
    for _, entry in ipairs(entries) do
        if excess <= 0 then break end
        if now >= entry.expires_at + STALE_RETENTION_S or entry.fetched_at < now - STALE_RETENTION_S then
            self._store[entry.key] = nil
            excess = excess - 1
        end
    end
    -- Still over cap (everything is fresh): evict oldest regardless.
    for _, entry in ipairs(entries) do
        if excess <= 0 then break end
        if self._store[entry.key] ~= nil then
            self._store[entry.key] = nil
            excess = excess - 1
        end
    end
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
    self:_prune(now)
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
