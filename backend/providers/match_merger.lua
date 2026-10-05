---Cross-provider match matcher.
---
---Identifies the same real-world match across different providers by comparing
---immutable data points: map name, score, finished timestamp, and K/D/A.
---
---Matching strategy (ordered by reliability):
---  1. finished_at timestamp within 60-second window + same map + same score
---  2. Same map + same score + same K/D/A totals
---  3. Same map + same score (fallback, lower confidence)

local logger = require("logger")
local schema = require("providers/aggregated_schema")

local matcher = {}

---Normalized map name cache for fuzzy matching.
local MAP_ALIASES = {
    -- de_ prefix stripped, lowercase
    dust2     = "dust2",
    dustii    = "dust2",
    dust_ii   = "dust2",
    mirage    = "mirage",
    inferno   = "inferno",
    nuke      = "nuke",
    ancient   = "ancient",
    anubis    = "anubis",
    overpass  = "overpass",
    vertigo   = "vertigo",
    train     = "train",
    cache     = "cache",
}

---Normalize a map name to a canonical lowercase key.
---@param map_name string|nil
---@return string|nil
function matcher.normalize_map(map_name)
    if type(map_name) ~= "string" or map_name == "" then return nil end
    local name = map_name:lower():gsub("^de_", ""):gsub("^cs_", ""):gsub("_", ""):gsub("%s+", "")
    return MAP_ALIASES[name] or name
end

---Parse a score string like "13–8" or "13:8" or "13 - 8" into two integers.
---@param score string|number|table|nil
---@return number|nil s1, number|nil s2
function matcher.parse_score(score)
    if score == nil then return nil, nil end

    -- Table: already a pair
    if type(score) == "table" and #score >= 2 then
        local a = tonumber(score[1])
        local b = tonumber(score[2])
        return a, b
    end

    -- Number: not a score
    if type(score) == "number" then return nil, nil end

    -- String: try multiple separators
    local s = tostring(score)
    local a, b = s:match("(%d+)%s*[:–—%-]+%s*(%d+)")
    if a and b then
        return tonumber(a), tonumber(b)
    end
    return nil, nil
end

---Create a match key from immutable fields for deduplication.
---@param match table A normalized match record
---@return string|nil key
function matcher.match_key(match)
    if match == nil then return nil end

    local map = matcher.normalize_map(match.map_name)
    local s1, s2 = matcher.parse_score(match.score)

    if map == nil or s1 == nil or s2 == nil then return nil end

    -- Build key: "map|low:high"
    local low, high = math.min(s1, s2), math.max(s1, s2)
    return map .. "|" .. low .. ":" .. high
end

---Parse a finished_at timestamp to a unix number for comparison.
---@param ts string|number|nil
---@return number|nil
function matcher.parse_timestamp(ts)
    if ts == nil then return nil end
    if type(ts) == "number" then return ts end
    -- ISO-8601 string → parse with pattern
    local s = tostring(ts)
    -- Try to extract seconds since epoch from ISO format
    local year, month, day, hour, min, sec = s:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if year then
        -- Use os.time for approximate conversion
        local t = os.time({
            year = tonumber(year), month = tonumber(month), day = tonumber(day),
            hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
        })
        return t
    end
    -- Try raw number
    return tonumber(s)
end

---Compute a similarity score between two matches (0–100).
---Higher means more likely to be the same match.
---@param a table Normalized match from provider A
---@param b table Normalized match from provider B
---@return number score, string reason
function matcher.similarity(a, b)
    local score = 0
    local reasons = {}

    -- Map match (required for any match)
    local map_a = matcher.normalize_map(a.map_name)
    local map_b = matcher.normalize_map(b.map_name)
    if map_a == nil or map_b == nil then
        return 0, "no_map"
    end
    if map_a ~= map_b then
        return 0, "different_map"
    end
    score = score + 30
    reasons[#reasons + 1] = "map"

    -- Score match
    local s1a, s2a = matcher.parse_score(a.score)
    local s1b, s2b = matcher.parse_score(b.score)
    if s1a and s1b then
        local same_score = (s1a == s1b and s2a == s2b) or (s1a == s2b and s2a == s1b)
        if same_score then
            score = score + 30
            reasons[#reasons + 1] = "score"
        else
            return score, "different_score:" .. table.concat(reasons, ",")
        end
    end

    -- Timestamp match (within 60-second window)
    local ts_a = matcher.parse_timestamp(a.finished_at)
    local ts_b = matcher.parse_timestamp(b.finished_at)
    if ts_a and ts_b then
        local diff = math.abs(ts_a - ts_b)
        if diff <= 60 then
            score = score + 40
            reasons[#reasons + 1] = "timestamp_close"
        elseif diff <= 300 then
            score = score + 20
            reasons[#reasons + 1] = "timestamp_near"
        end
    end

    -- K/D/A match (if available from both)
    if a.kills ~= nil and b.kills ~= nil and a.deaths ~= nil and b.deaths ~= nil then
        if a.kills == b.kills and a.deaths == b.deaths then
            score = score + 10
            reasons[#reasons + 1] = "kda"
            if a.assists ~= nil and b.assists ~= nil and a.assists == b.assists then
                score = score + 5
                reasons[#reasons + 1] = "assists"
            end
        end
    end

    return score, table.concat(reasons, ",")
end

---Match confidence threshold. Below this, two matches are considered different.
matcher.CONFIDENCE_THRESHOLD = 60

---Match a list of normalized matches from multiple providers into unified matches.
---@param provider_matches table<string, table[]> Map of provider name → list of matches
---@return table[] Unified match list
function matcher.merge_matches(provider_matches)
    -- Collect all matches with source tag
    local all = {}
    for provider, matches in pairs(provider_matches) do
        if type(matches) == "table" then
            for _, match in ipairs(matches) do
                if type(match) == "table" and match.map_name then
                    all[#all + 1] = { match = match, provider = provider, merged = false }
                end
            end
        end
    end

    if #all == 0 then return {} end

    -- Sort by finished_at descending (most recent first)
    table.sort(all, function(a, b)
        local ts_a = matcher.parse_timestamp(a.match.finished_at) or 0
        local ts_b = matcher.parse_timestamp(b.match.finished_at) or 0
        return ts_a > ts_b
    end)

    local unified = {}
    local used = {}

    for i = 1, #all do
        if not used[i] then
            local base = all[i]
            local merged = {
                map_name   = base.match.map_name,
                score      = base.match.score,
                outcome    = base.match.outcome,
                finished_at= base.match.finished_at,
                kills      = base.match.kills,
                deaths     = base.match.deaths,
                assists    = base.match.assists,
                kd         = base.match.kd,
                adr        = base.match.adr,
                rating     = base.match.rating,
                kast       = base.match.kast,
                accuracy   = base.match.accuracy,
                preaim     = base.match.preaim,
                ttd        = base.match.ttd,
                sources    = { base.provider },
                data       = { [base.provider] = base.match },
            }
            used[i] = true

            -- Try to match with remaining entries
            for j = i + 1, #all do
                if not used[j] then
                    local score, reason = matcher.similarity(base.match, all[j].match)
                    if score >= matcher.CONFIDENCE_THRESHOLD then
                        -- Merge data from this provider
                        local other = all[j].match
                        local other_provider = all[j].provider

                        -- Fill in missing fields from the other provider
                        for _, field in ipairs({ "kills", "deaths", "assists", "kd", "adr", "rating", "kast", "accuracy", "preaim", "ttd" }) do
                            if merged[field] == nil and other[field] ~= nil then
                                merged[field] = other[field]
                            end
                        end

                        -- Use the other outcome if we don't have one
                        if merged.outcome == nil and other.outcome ~= nil then
                            merged.outcome = other.outcome
                        end

                        -- Use the other finished_at if we don't have one
                        if merged.finished_at == nil and other.finished_at ~= nil then
                            merged.finished_at = other.finished_at
                        end

                        -- Use the other score if we don't have one
                        if merged.score == nil and other.score ~= nil then
                            merged.score = other.score
                        end

                        -- Track all providers
                        merged.sources[#merged.sources + 1] = other_provider
                        merged.data[other_provider] = other
                        used[j] = true

                        logger:info(string.format(
                            "Matched %s match (score=%s, map=%s) from %s with %s (score=%s) — confidence %d (%s)",
                            base.provider, tostring(base.match.score), tostring(base.match.map_name),
                            other_provider, other_provider, tostring(other.score), score, reason
                        ))
                    end
                end
            end

            unified[#unified + 1] = merged
        end
    end

    return unified
end

return matcher
