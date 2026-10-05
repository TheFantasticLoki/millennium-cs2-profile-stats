---Aggregation engine — merges partial results from all providers into a
---single unified player profile.
---
---Normalization rules applied here:
---  - Leetify winrate: 0-1 → 0-100
---  - FACEIT string stats: "62.4%" → 62.4, "1.39" → 1.39
---  - Leetify clutch/opening ratings: 0-1 → 0-100
---  - All other providers already use 0-100 percentages

local cjson = require("json")
local logger = require("logger")
local reg = require("providers/init")
local schema = require("providers/aggregated_schema")
local matcher = require("providers/match_merger")

local aggregator = {}

---Static fallback priority (lower = higher priority). Only used as a
---tie-breaker when providers have equal/unknown match counts.
local PROVIDER_PRIORITY = {
    cstracker = 1,
    csrep     = 2,
    csstats   = 3,
    leetify   = 4,
    faceit    = 5,
}

---Floor match count for providers that don't report one, so they still
---contribute a small weight instead of being dropped entirely.
local DEFAULT_MATCH_FLOOR = 25

---Compute how many matches each provider has tracked, used to weight
---aggregation and to pick the primary source.
---@param parsed table<string, table> Decoded provider payloads
---@return table<string, number> match_counts
function aggregator.provider_match_counts(parsed)
    local counts = {}
    if parsed.leetify and parsed.leetify.total_matches then
        counts.leetify = aggregator.to_number(parsed.leetify.total_matches) or 0
    end
    if parsed.faceit and parsed.faceit.stats and parsed.faceit.stats.matches then
        counts.faceit = aggregator.normalize_faceit_stat(parsed.faceit.stats.matches) or 0
    end
    if parsed.cstracker and parsed.cstracker.total_matches then
        counts.cstracker = aggregator.to_number(parsed.cstracker.total_matches) or 0
    end
    if parsed.csrep and parsed.csrep.performance and parsed.csrep.performance.matches_played then
        counts.csrep = aggregator.to_number(parsed.csrep.performance.matches_played) or 0
    end
    if parsed.csstats and parsed.csstats.total_matches then
        counts.csstats = aggregator.to_number(parsed.csstats.total_matches) or 0
    end
    return counts
end

---Pick the provider with the most matches tracked; static priority breaks ties.
---@param providers string[]
---@param match_counts table<string, number>
---@return string|nil
local function primary_provider(providers, match_counts)
    local best, best_matches, best_prio = nil, -1, math.huge
    for _, p in ipairs(providers) do
        local m = match_counts[p] or 0
        local prio = PROVIDER_PRIORITY[p] or 99
        if m > best_matches or (m == best_matches and prio < best_prio) then
            best, best_matches, best_prio = p, m, prio
        end
    end
    return best
end

---Build a resolved value plus per-provider contributions from a map of
---provider → raw value.
---
---  method = "weighted" — rates/averages (K/D, winrate, ADR, …): blend
---           every provider's value weighted by how many matches it has
---           tracked, so larger samples pull the result toward them.
---  method = "primary"  — ranks/totals: take the single provider with the
---           most matches tracked (static priority breaks ties); other
---           providers are still recorded as contributions for the UI.
---@param values table<string, any> provider → raw value (nil entries ignored)
---@param match_counts table<string, number>
---@param method "weighted"|"primary"
---@return number|nil resolved, table contributions, string[] providers
function aggregator.aggregate_value(values, match_counts, method)
    local entries = {}
    for provider, raw in pairs(values) do
        local n = aggregator.to_number(raw)
        if n ~= nil then
            entries[#entries + 1] = { provider = provider, value = n }
        end
    end
    if #entries == 0 then return nil, {}, {} end

    -- Stable ordering: static priority first.
    table.sort(entries, function(a, b)
        return (PROVIDER_PRIORITY[a.provider] or 99) < (PROVIDER_PRIORITY[b.provider] or 99)
    end)

    local providers = {}
    for _, e in ipairs(entries) do providers[#providers + 1] = e.provider end

    local primary = primary_provider(providers, match_counts)

    -- Raw weights from tracked match counts (floored so unknown providers
    -- still get a small say instead of vanishing from the blend).
    local total_raw = 0
    for _, e in ipairs(entries) do
        local reported = match_counts[e.provider] or 0
        e.matches = reported
        e.raw_weight = reported > 0 and reported or DEFAULT_MATCH_FLOOR
        total_raw = total_raw + e.raw_weight
    end

    local resolved
    if method == "primary" then
        -- Provider with the most matches tracked wins outright.
        for _, e in ipairs(entries) do
            e.weight = (e.provider == primary) and 1 or 0
            if e.provider == primary then resolved = e.value end
        end
    else
        -- Weighted average across all contributing providers.
        local acc = 0
        for _, e in ipairs(entries) do
            e.weight = e.raw_weight / total_raw
            acc = acc + e.value * e.weight
        end
        resolved = math.floor(acc * 100 + 0.5) / 100
    end

    local contributions = {}
    for _, e in ipairs(entries) do
        contributions[#contributions + 1] = {
            provider   = e.provider,
            value      = e.value,
            weight     = e.weight,
            matches    = e.matches,
            is_primary = e.provider == primary,
        }
    end

    return resolved, contributions, providers
end

---Resolve a stat from multiple provider values into an AggValue that
---carries per-provider contributions for the frontend hover breakdown.
---@param values table<string, any> provider → raw value
---@param match_counts table<string, number>
---@param method "weighted"|"primary"|nil defaults to "weighted"
---@return table|nil aggValue
function aggregator.resolve_stat(values, match_counts, method)
    local resolved, contributions, sources =
        aggregator.aggregate_value(values, match_counts, method or "weighted")
    if resolved == nil then return nil end
    return schema.agg_value_contributions(resolved, sources, contributions)
end

---Legacy priority-only resolver kept for call sites that don't need
---contribution metadata (e.g. identity fields).
---@param values table<string, any> Map of provider → value
---@return any resolved_value, string[] sources
function aggregator.resolve_multi(values)
    local best_value = nil
    local best_priority = math.huge
    local sources = {}

    for provider, value in pairs(values) do
        if value ~= nil then
            sources[#sources + 1] = provider
            local priority = PROVIDER_PRIORITY[provider] or 99
            if priority < best_priority then
                best_priority = priority
                best_value = value
            end
        end
    end

    return best_value, sources
end

---Safe number conversion that handles strings, numbers, and nil.
---@param value any
---@return number|nil
function aggregator.to_number(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end
    local s = tostring(value):gsub(",", ""):gsub("%%", ""):match("^%s*(.-)%s*$")
    local n = tonumber(s)
    return n
end

---Normalize a FACEIT string stat (e.g. "62.4%", "1.39", "1234").
---@param value string|number|nil
---@return number|nil
function aggregator.normalize_faceit_stat(value)
    if value == nil then return nil end
    return aggregator.to_number(value)
end

---Normalize Leetify winrate from 0-1 to 0-100.
---@param value number|nil
---@return number|nil
function aggregator.normalize_leetify_winrate(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if n == nil then return nil end
    -- If already > 1, assume it's already a percentage
    if n > 1 then return n end
    return n * 100
end

---Normalize Leetify rating value (0-1 → 0-100).
---@param value number|nil
---@return number|nil
function aggregator.normalize_leetify_rating(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if n == nil then return nil end
    -- Leetify aim/positioning/utility are already 0-100 in the normalized API
    -- But clutch/opening are already scaled by scaled_rating in the API
    -- So just pass through
    return n
end

---Normalize a CSTracker match record for cross-provider matching.
---@param match table
---@return table normalized
function aggregator.normalize_cstracker_match(match)
    return {
        map_name    = match.map_name,
        score       = match.score,
        outcome     = match.outcome,
        finished_at = match.when_text, -- CSTracker only has relative time
        kills       = match.kills,
        deaths      = match.deaths,
        assists     = match.assists,
        kd          = match.kd,
        adr         = match.adr,
        rating      = match.rating,
        kast        = match.kast,
        accuracy    = match.accuracy,
        preaim      = match.preaim,
        ttd         = match.ttd,
    }
end

---Normalize a Leetify match record for cross-provider matching.
---@param match table
---@return table normalized
function aggregator.normalize_leetify_match(match)
    return {
        map_name    = match.map_name,
        score       = match.score,
        outcome     = match.outcome,
        finished_at = match.finished_at,
        kills       = nil, -- Leetify doesn't provide per-match K/D in the summary
        deaths      = nil,
        assists     = nil,
        kd          = nil,
        adr         = nil,
        rating      = nil,
        kast        = nil,
        accuracy    = nil,
        preaim      = nil,
        ttd         = nil,
    }
end

---Normalize a CSRep match record for cross-provider matching.
---@param match table
---@return table normalized
function aggregator.normalize_csrep_match(match)
    -- CSRep match format varies; extract what we can
    return {
        map_name    = match.map_name or match.map,
        score       = match.score or match.result,
        outcome     = match.outcome or match.result_type,
        finished_at = match.finished_at or match.date or match.timestamp,
        kills       = match.kills,
        deaths      = match.deaths,
        assists     = match.assists,
        kd          = match.kd,
        adr         = match.adr,
        rating      = match.hltv_rating or match.rating,
        kast        = match.kast,
        accuracy    = match.accuracy,
        preaim      = nil,
        ttd         = nil,
    }
end

---Normalize a CSStats match record for cross-provider matching.
---CSStats MATCH_DATA rows carry map, score, result, per-match K/D/A, ADR,
---rating, and a unix finish timestamp — all of which feed the merger.
---@param match table
---@return table normalized
function aggregator.normalize_csstats_match(match)
    local score = match.score
    if type(score) == "table" and #score >= 2 then
        score = tostring(score[1]) .. "-" .. tostring(score[2])
    end
    return {
        map_name    = match.map_name,
        score       = score,
        outcome     = match.outcome,
        finished_at = match.finished_at, -- unix seconds; merger windows on it
        kills       = match.kills,
        deaths      = match.deaths,
        assists     = match.assists,
        kd          = match.kd,
        adr         = match.adr,
        rating      = match.rating,
        kast        = match.kast,
        accuracy    = match.accuracy,
        preaim      = nil,
        ttd         = nil,
    }
end

---Parse CSTracker clutch data into the unified format.
---@param clutch table[]
---@return table[]
function aggregator.normalize_cstracker_clutch(clutch)
    if type(clutch) ~= "table" then return {} end
    local result = {}
    for _, entry in ipairs(clutch) do
        if type(entry) == "table" and entry.label then
            result[#result + 1] = {
                label   = entry.label,
                wins    = entry.wins or 0,
                losses  = entry.losses or 0,
                winrate = entry.winrate or 0,
            }
        end
    end
    return result
end

---Parse CSRep clutch data into the unified format.
---@param perf table Performance stats from CSRep
---@return table[]
function aggregator.normalize_csrep_clutch(perf)
    if type(perf) ~= "table" then return {} end
    -- csrep.lua nests clutch counters under performance.clutches; older
    -- cached payloads may flatten them onto performance itself.
    local src = type(perf.clutches) == "table" and perf.clutches or perf
    local result = {}
    local labels = { "v1", "v2", "v3", "v4", "v5" }
    local won_keys = { "v1_won", "v2_won", "v3_won", "v4_won", "v5_won" }
    local total_keys = { "v1", "v2", "v3", "v4", "v5" }

    for i, label in ipairs(labels) do
        -- to_number safely maps cjson null userdata to nil
        local total = aggregator.to_number(src[total_keys[i]]) or 0
        local won = aggregator.to_number(src[won_keys[i]]) or 0
        if total > 0 then
            result[#result + 1] = {
                label   = "1v" .. tostring(i),
                wins    = won,
                losses  = total - won,
                winrate = math.floor((won / total) * 100 + 0.5),
            }
        end
    end
    return result
end

---Normalize CSStats clutch data into the unified format.
---CSStats reports the same {label,wins,losses,winrate} shape directly
---(built from totals.overall in csstats.lua). Empty 0/0 rows are dropped
---so they can never shadow real data from another provider.
---@param clutch table[]
---@return table[]
function aggregator.normalize_csstats_clutch(clutch)
    if type(clutch) ~= "table" then return {} end
    local result = {}
    for _, entry in ipairs(clutch) do
        if type(entry) == "table" and entry.label then
            local wins = aggregator.to_number(entry.wins) or 0
            local losses = aggregator.to_number(entry.losses) or 0
            if wins + losses > 0 then
                result[#result + 1] = {
                    label   = entry.label,
                    wins    = wins,
                    losses  = losses,
                    winrate = aggregator.to_number(entry.winrate) or 0,
                }
            end
        end
    end
    return result
end

---Extract trust data from CSTracker into the unified trust section.
---@param profile table CSTracker raw data
---@param trust table Trust section of the aggregated profile
function aggregator.extract_cstracker_trust(profile, trust)
    if profile.trust_rating ~= nil then
        trust.cstracker_rating = profile.trust_rating
    end
    if type(profile.trust_breakdown) == "table" then
        trust.cstracker_breakdown = profile.trust_breakdown
    end
    if profile.has_ban then
        trust.has_ban = true
    end
end

---Extract trust data from CSRep into the unified trust section.
---@param profile table CSRep raw data
---@param trust table Trust section of the aggregated profile
function aggregator.extract_csrep_trust(profile, trust)
    if profile.trust_score ~= nil then
        trust.csrep_score = profile.trust_score
    end
    if profile.trust_label ~= nil then
        trust.csrep_label = profile.trust_label
    end
    if profile.statistical_trust ~= nil then
        trust.csrep_statistical = profile.statistical_trust
    end
    if profile.account_flags ~= nil then
        trust.csrep_account_flags = profile.account_flags
    end
    if profile.anomalies ~= nil then
        trust.csrep_anomalies = profile.anomalies
    end
    if profile.account_bonus ~= nil then
        trust.csrep_account_bonus = profile.account_bonus
    end
    if profile.has_ban then
        trust.has_ban = true
    end
    if type(profile.bans) == "table" then
        trust.bans = profile.bans
    end

    -- Structured breakdown so the UI can explain why the score is not 100.
    -- csrep.lua normalizes components to a 0-100 scale: statistical_trust is
    -- the base trust %, account_flags/anomalies are trust % retained (a
    -- penalty is applied when below 100), and account_bonus is a positive
    -- adjustment in percentage points.
    local breakdown = {}
    if profile.statistical_trust ~= nil then
        breakdown[#breakdown + 1] = {
            factor = "Statistical Trust",
            value  = profile.statistical_trust,
        }
    end
    if profile.account_flags ~= nil then
        breakdown[#breakdown + 1] = {
            factor     = "Account Flags",
            value      = profile.account_flags,
            is_penalty = profile.account_flags < 100,
        }
    end
    if profile.anomalies ~= nil then
        breakdown[#breakdown + 1] = {
            factor     = "Anomalies",
            value      = profile.anomalies,
            is_penalty = profile.anomalies < 100,
        }
    end
    if profile.account_bonus ~= nil then
        breakdown[#breakdown + 1] = {
            factor = "Account Bonus",
            value  = profile.account_bonus,
        }
    end
    trust.csrep_breakdown = breakdown
end

---Build the aggregated profile from a map of provider responses.
---@param responses table<string, string> Map of provider name → JSON response
---@return string JSON-encoded aggregated profile
function aggregator.aggregate(responses)
    local profile = schema.new_profile()
    local provider_count = 0
    local providers_used = {}

    -- Parse all responses
    local parsed = {}
    for name, raw in pairs(responses) do
        local ok, data = pcall(cjson.decode, raw)
        if ok and type(data) == "table" and data.status == "ok" and type(data.data) == "table" then
            parsed[name] = data.data
            provider_count = provider_count + 1
            providers_used[#providers_used + 1] = name
        end
    end

    profile.provider_count = provider_count
    profile.providers_used = providers_used

    if provider_count == 0 then
        profile.aggregated_at = os.time()
        return schema.encode(profile)
    end

    -- ── Aggregation weights ──────────────────────────────────────
    -- How many matches each provider tracks. Drives both the weighted
    -- blend for rates and the "most matches tracked" primary pick for
    -- ranks/totals, instead of a fixed provider priority list.
    local match_counts = aggregator.provider_match_counts(parsed)

    -- ── Identity ──────────────────────────────────────────────────
    -- Use the best available name from any provider
    local name_sources = {}
    for name, data in pairs(parsed) do
        if data.name then name_sources[name] = data.name end
        if data.nickname then name_sources[name] = data.nickname end
    end
    if next(name_sources) then
        local _, name_providers = aggregator.resolve_multi(name_sources)
        local best_name = nil
        local best_prio = math.huge
        for p, n in pairs(name_sources) do
            if (PROVIDER_PRIORITY[p] or 99) < best_prio then
                best_prio = PROVIDER_PRIORITY[p]
                best_name = n
            end
        end
        profile.name = best_name
    end

    -- Steam ID from any provider
    for _, data in pairs(parsed) do
        if data.steam64_id then
            profile.steam64_id = data.steam64_id
            break
        end
    end

    -- ── Core stats ────────────────────────────────────────────────
    -- K/D
    local kd_values = {}
    if parsed.leetify and parsed.leetify.stats and parsed.leetify.stats.kd then
        kd_values.leetify = parsed.leetify.stats.kd
    end
    if parsed.faceit and parsed.faceit.stats and parsed.faceit.stats.kd then
        kd_values.faceit = aggregator.normalize_faceit_stat(parsed.faceit.stats.kd)
    end
    if parsed.cstracker and parsed.cstracker.kd then
        kd_values.cstracker = parsed.cstracker.kd
    end
    if parsed.csrep and parsed.csrep.performance and parsed.csrep.performance.kd_ratio then
        kd_values.csrep = parsed.csrep.performance.kd_ratio
    end
    if parsed.csstats and parsed.csstats.kd then
        kd_values.csstats = parsed.csstats.kd
    end
    local kd_val = aggregator.resolve_stat(kd_values, match_counts, "weighted")
    if kd_val then profile.stats.kd = kd_val end

    -- Win rate
    local wr_values = {}
    if parsed.leetify and parsed.leetify.winrate then
        wr_values.leetify = aggregator.normalize_leetify_winrate(parsed.leetify.winrate)
    end
    if parsed.faceit and parsed.faceit.stats and parsed.faceit.stats.winrate then
        wr_values.faceit = aggregator.normalize_faceit_stat(parsed.faceit.stats.winrate)
    end
    if parsed.cstracker and parsed.cstracker.winrate then
        wr_values.cstracker = parsed.cstracker.winrate
    end
    if parsed.csrep and parsed.csrep.performance and parsed.csrep.performance.win_rate then
        wr_values.csrep = parsed.csrep.performance.win_rate
    end
    if parsed.csstats and parsed.csstats.winrate then
        wr_values.csstats = parsed.csstats.winrate
    end
    local wr_val = aggregator.resolve_stat(wr_values, match_counts, "weighted")
    if wr_val then profile.stats.winrate = wr_val end

    -- ADR
    local adr_values = {}
    if parsed.faceit and parsed.faceit.stats and parsed.faceit.stats.adr then
        adr_values.faceit = aggregator.normalize_faceit_stat(parsed.faceit.stats.adr)
    end
    if parsed.cstracker and parsed.cstracker.adr then
        adr_values.cstracker = parsed.cstracker.adr
    end
    if parsed.csrep and parsed.csrep.stats and parsed.csrep.stats.adr then
        adr_values.csrep = parsed.csrep.stats.adr
    end
    if parsed.csstats and parsed.csstats.adr then
        adr_values.csstats = parsed.csstats.adr
    end
    local adr_val = aggregator.resolve_stat(adr_values, match_counts, "weighted")
    if adr_val then profile.stats.adr = adr_val end

    -- Headshot %
    -- Definition: share of KILLS landed as headshots. CSRep's
    -- accuracy_head is intentionally excluded — it measures headshots as
    -- a share of ALL SHOTS, a different metric collected as
    -- stats.head_accuracy below.
    local hs_values = {}
    if parsed.faceit and parsed.faceit.stats and parsed.faceit.stats.headshots then
        hs_values.faceit = aggregator.normalize_faceit_stat(parsed.faceit.stats.headshots)
    end
    if parsed.cstracker and parsed.cstracker.hs_pct then
        hs_values.cstracker = parsed.cstracker.hs_pct
    end
    if parsed.csstats and parsed.csstats.hs then
        hs_values.csstats = parsed.csstats.hs
    end
    local hs_val = aggregator.resolve_stat(hs_values, match_counts, "weighted")
    if hs_val then profile.stats.headshot_pct = hs_val end

    -- Head Accuracy — share of ALL SHOTS landed on the head (CSRep's
    -- metric). Not blended with HS%: the denominators differ, so mixing
    -- them would produce a meaningless number. Kept as its own stat.
    local ha_values = {}
    if parsed.csrep and parsed.csrep.stats and parsed.csrep.stats.accuracy_head then
        ha_values.csrep = parsed.csrep.stats.accuracy_head
    end
    local ha_val = aggregator.resolve_stat(ha_values, match_counts, "primary")
    if ha_val then profile.stats.head_accuracy = ha_val end

    -- HLTV Rating
    local hltv_values = {}
    if parsed.cstracker and parsed.cstracker.hltv_rating then
        hltv_values.cstracker = parsed.cstracker.hltv_rating
    end
    if parsed.csrep and parsed.csrep.stats and parsed.csrep.stats.hltv_rating_2 then
        hltv_values.csrep = parsed.csrep.stats.hltv_rating_2
    end
    if parsed.csstats and parsed.csstats.hltv_rating then
        hltv_values.csstats = parsed.csstats.hltv_rating
    end
    local hltv_val = aggregator.resolve_stat(hltv_values, match_counts, "weighted")
    if hltv_val then profile.stats.hltv_rating = hltv_val end

    -- KAST
    local kast_values = {}
    if parsed.cstracker and parsed.cstracker.kast then
        kast_values.cstracker = parsed.cstracker.kast
    end
    if parsed.csrep and parsed.csrep.stats and parsed.csrep.stats.kast then
        kast_values.csrep = parsed.csrep.stats.kast
    end
    if parsed.csstats and parsed.csstats.kast then
        kast_values.csstats = parsed.csstats.kast
    end
    local kast_val = aggregator.resolve_stat(kast_values, match_counts, "weighted")
    if kast_val then profile.stats.kast = kast_val end

    -- Kills / Deaths / Assists (totals)
    for _, stat in ipairs({ { key = "kills", ct_key = "kills", rep_key = "kills", cs_key = "kills" },
                            { key = "deaths", ct_key = "deaths", rep_key = "deaths", cs_key = "deaths" },
                            { key = "assists", ct_key = "assists", rep_key = "assists", cs_key = "assists" } }) do
        local vals = {}
        if parsed.cstracker and parsed.cstracker[stat.ct_key] then
            vals.cstracker = parsed.cstracker[stat.ct_key]
        end
        if parsed.csrep and parsed.csrep.performance and parsed.csrep.performance[stat.rep_key] then
            vals.csrep = parsed.csrep.performance[stat.rep_key]
        end
        if parsed.csstats and parsed.csstats[stat.cs_key] then
            vals.csstats = parsed.csstats[stat.cs_key]
        end
        -- Totals span different queues per provider, so take the provider
        -- with the most matches tracked instead of averaging.
        local val = aggregator.resolve_stat(vals, match_counts, "primary")
        if val then
            profile.stats[stat.key] = val
        end
    end

    -- Total matches
    local matches_values = {}
    if parsed.leetify and parsed.leetify.total_matches then
        matches_values.leetify = parsed.leetify.total_matches
    end
    if parsed.faceit and parsed.faceit.stats and parsed.faceit.stats.matches then
        matches_values.faceit = aggregator.normalize_faceit_stat(parsed.faceit.stats.matches)
    end
    if parsed.cstracker and parsed.cstracker.total_matches then
        matches_values.cstracker = parsed.cstracker.total_matches
    end
    if parsed.csrep and parsed.csrep.performance and parsed.csrep.performance.matches_played then
        matches_values.csrep = parsed.csrep.performance.matches_played
    end
    if parsed.csstats and parsed.csstats.total_matches then
        matches_values.csstats = parsed.csstats.total_matches
    end
    local matches_val = aggregator.resolve_stat(matches_values, match_counts, "primary")
    if matches_val then profile.stats.total_matches = matches_val end

    -- Accuracy
    local acc_values = {}
    if parsed.cstracker and parsed.cstracker.accuracy then
        acc_values.cstracker = parsed.cstracker.accuracy
    end
    local acc_val = aggregator.resolve_stat(acc_values, match_counts, "weighted")
    if acc_val then profile.stats.accuracy = acc_val end

    -- CSTracker-specific stats
    if parsed.cstracker then
        local ct = parsed.cstracker
        profile.stats.preaim = schema.agg_value(ct.preaim, "cstracker")
        profile.stats.aim_offset = schema.agg_value(ct.aim_offset, "cstracker")
        profile.stats.counter_strafing = schema.agg_value(ct.counter_strafing, "cstracker")
        profile.stats.ttd = schema.agg_value(ct.ttd, "cstracker")
        profile.stats.spot_to_damage = schema.agg_value(ct.spot_to_damage, "cstracker")
        profile.stats.spot_to_kill = schema.agg_value(ct.spot_to_kill, "cstracker")
        profile.stats.trade_kills = schema.agg_value(ct.trade_kills, "cstracker")
        profile.stats.enemy_damage = schema.agg_value(ct.enemy_damage, "cstracker")
        profile.stats.bhop_success = schema.agg_value(ct.bhop_success, "cstracker")
        profile.stats.spray_accuracy = schema.agg_value(ct.spray_accuracy, "cstracker")
    end

    -- First kills (entry kills) — CSTracker and CSStats both report lifetime
    -- counts over different match pools; take the larger sample.
    local fk_values = {}
    if parsed.cstracker and parsed.cstracker.first_kills then
        fk_values.cstracker = parsed.cstracker.first_kills
    end
    if parsed.csstats and parsed.csstats.first_kills then
        fk_values.csstats = parsed.csstats.first_kills
    end
    local fk_val = aggregator.resolve_stat(fk_values, match_counts, "primary")
    if fk_val then profile.stats.first_kills = fk_val end

    -- Leetify-specific stats
    if parsed.leetify then
        local lf = parsed.leetify
        profile.stats.reaction_time_ms = schema.agg_value(
            lf.stats and lf.stats.reaction_time_ms, "leetify"
        )
    end

    -- ── Ranks ─────────────────────────────────────────────────────
    -- Premier (highest priority)
    local premier_values = {}
    if parsed.leetify and parsed.leetify.ranks and parsed.leetify.ranks.premier then
        premier_values.leetify = parsed.leetify.ranks.premier
    end
    if parsed.cstracker and parsed.cstracker.premier then
        premier_values.cstracker = parsed.cstracker.premier
    end
    if parsed.csrep and parsed.csrep.premier then
        premier_values.csrep = parsed.csrep.premier
    end
    if parsed.csstats and parsed.csstats.premier then
        premier_values.csstats = parsed.csstats.premier
    end
    -- Premier is a point-in-time rank per platform — averaging makes no
    -- sense, so take the provider with the most matches tracked.
    local premier_val = aggregator.resolve_stat(premier_values, match_counts, "primary")
    if premier_val then profile.ranks.premier = premier_val end

    -- FACEIT level
    local faceit_level_values = {}
    if parsed.faceit and parsed.faceit.level then
        faceit_level_values.faceit = parsed.faceit.level
    end
    if parsed.cstracker and parsed.cstracker.faceit_level then
        faceit_level_values.cstracker = parsed.cstracker.faceit_level
    end
    local faceit_level_val = aggregator.resolve_stat(faceit_level_values, match_counts, "primary")
    if faceit_level_val then profile.ranks.faceit = faceit_level_val end

    -- FACEIT ELO
    local faceit_elo_values = {}
    if parsed.faceit and parsed.faceit.elo then
        faceit_elo_values.faceit = parsed.faceit.elo
    end
    if parsed.leetify and parsed.leetify.ranks and parsed.leetify.ranks.faceit_elo then
        faceit_elo_values.leetify = parsed.leetify.ranks.faceit_elo
    end
    if parsed.cstracker and parsed.cstracker.faceit_elo then
        faceit_elo_values.cstracker = parsed.cstracker.faceit_elo
    end
    local faceit_elo_val = aggregator.resolve_stat(faceit_elo_values, match_counts, "primary")
    if faceit_elo_val then profile.ranks.faceit_elo = faceit_elo_val end

    -- Leetify rating
    if parsed.leetify and parsed.leetify.ranks and parsed.leetify.ranks.leetify then
        profile.ranks.leetify = schema.agg_value(parsed.leetify.ranks.leetify, "leetify")
    end

    -- ── Leetify rating breakdown ──────────────────────────────────
    if parsed.leetify and parsed.leetify.rating then
        local lr = parsed.leetify.rating
        profile.leetify_rating.aim = schema.agg_value(lr.aim, "leetify")
        profile.leetify_rating.positioning = schema.agg_value(lr.positioning, "leetify")
        profile.leetify_rating.utility = schema.agg_value(lr.utility, "leetify")
        profile.leetify_rating.clutch = schema.agg_value(lr.clutch, "leetify")
        profile.leetify_rating.opening = schema.agg_value(lr.opening, "leetify")
    end

    -- ── Utility stats ─────────────────────────────────────────────
    if parsed.cstracker then
        local ct = parsed.cstracker
        profile.utility.grenade_throws = schema.agg_value(ct.grenade_throws, "cstracker")
        profile.utility.flash_assists = schema.agg_value(ct.flash_assists, "cstracker")
        profile.utility.enemies_flashed_per_flash = schema.agg_value(ct.enemies_flashed_per_flash, "cstracker")
        profile.utility.avg_flash_duration = schema.agg_value(ct.avg_flash_duration, "cstracker")
        profile.utility.util_dmg_per_match = schema.agg_value(ct.util_dmg_per_match, "cstracker")
        profile.utility.he_dmg_per_throw = schema.agg_value(ct.he_dmg_per_throw, "cstracker")
        profile.utility.fire_dmg_per_throw = schema.agg_value(ct.fire_dmg_per_throw, "cstracker")
        profile.utility.unused_util_on_death = schema.agg_value(ct.unused_util_on_death, "cstracker")
    end

    -- ── Behavior stats ────────────────────────────────────────────
    if parsed.cstracker then
        local ct = parsed.cstracker
        profile.behavior.afk_time_per_match = schema.agg_value(ct.afk_time_per_match, "cstracker")
        profile.behavior.teamkills_per_match = schema.agg_value(ct.teamkills_per_match, "cstracker")
        profile.behavior.team_damage_per_match = schema.agg_value(ct.team_damage_per_match, "cstracker")
        profile.behavior.avg_teammates_flashed = schema.agg_value(ct.avg_teammates_flashed, "cstracker")
        profile.behavior.teammate_flash_duration = schema.agg_value(ct.teammate_flash_duration, "cstracker")
        profile.behavior.input_automation = schema.agg_value(ct.input_automation, "cstracker")
        profile.behavior.vote_kicked = schema.agg_value(ct.vote_kicked, "cstracker")
        profile.behavior.team_dmg_kicks = schema.agg_value(ct.team_dmg_kicks, "cstracker")
    end

    -- ── Kill breakdown ────────────────────────────────────────────
    if parsed.cstracker and type(parsed.cstracker.kill_breakdown) == "table" then
        for key, data in pairs(parsed.cstracker.kill_breakdown) do
            if type(data) == "table" then
                profile.kill_breakdown[key] = {
                    value = data,
                    sources = { "cstracker" },
                }
            end
        end
    end

    -- ── Multi-kills ────────────────────────────────────────────────
    -- Round-kill tallies (double/triple/quad/penta). Counts spanning
    -- different sample sizes, so take the provider with the most matches
    -- tracked — same method as kills/deaths/assists.
    for _, key in ipairs({ "double", "triple", "quad", "penta" }) do
        local vals = {}
        if parsed.csrep and type(parsed.csrep.performance) == "table"
            and type(parsed.csrep.performance.multi_kills) == "table"
            and aggregator.to_number(parsed.csrep.performance.multi_kills[key]) ~= nil then
            vals.csrep = parsed.csrep.performance.multi_kills[key]
        end
        if parsed.cstracker and type(parsed.cstracker.multi_kills) == "table"
            and aggregator.to_number(parsed.cstracker.multi_kills[key]) ~= nil then
            vals.cstracker = parsed.cstracker.multi_kills[key]
        end
        if parsed.csstats and type(parsed.csstats.multi_kills) == "table"
            and aggregator.to_number(parsed.csstats.multi_kills[key]) ~= nil then
            vals.csstats = parsed.csstats.multi_kills[key]
        end
        local agg_val = aggregator.resolve_stat(vals, match_counts, "primary")
        if agg_val then profile.multi_kills[key] = agg_val end
    end

    -- ── Clutch performance ────────────────────────────────────────
    -- Normalize each provider's clutch into the unified shape. CSTracker
    -- and CSRep go through their normalizers; CSStats ships the same
    -- shape directly. Empty 0/0 rows are dropped at the merge point so
    -- they can never shadow real data from another provider.
    local clutch_ct = {}
    if parsed.cstracker and type(parsed.cstracker.clutch) == "table" then
        clutch_ct = aggregator.normalize_cstracker_clutch(parsed.cstracker.clutch)
    end

    local clutch_rep = {}
    if parsed.csrep and parsed.csrep.performance then
        clutch_rep = aggregator.normalize_csrep_clutch(parsed.csrep.performance)
    end

    local clutch_cs = {}
    if parsed.csstats and type(parsed.csstats.clutch) == "table" then
        clutch_cs = aggregator.normalize_csstats_clutch(parsed.csstats.clutch)
    end

    -- Collect every provider's entry per label. The displayed numbers come
    -- from the provider with the most matches tracked (static priority only
    -- breaks ties) — the same rule as kills/deaths/totals — so a small or
    -- stale scrape can no longer shadow a larger dataset. Every provider's
    -- own numbers are kept as contributions for the UI hover breakdown.
    local clutch_map = {}
    local function add_clutch_source(name, entries)
        for _, entry in ipairs(entries) do
            local wins = aggregator.to_number(entry.wins) or 0
            local losses = aggregator.to_number(entry.losses) or 0
            if wins + losses > 0 then
                local bucket = clutch_map[entry.label]
                if not bucket then
                    bucket = {}
                    clutch_map[entry.label] = bucket
                end
                -- Store a coerced copy so cjson nulls never leak into
                -- contributions or the encoded profile.
                bucket[#bucket + 1] = {
                    provider = name,
                    entry = {
                        label   = entry.label,
                        wins    = wins,
                        losses  = losses,
                        winrate = aggregator.to_number(entry.winrate) or 0,
                    },
                }
            end
        end
    end
    add_clutch_source("cstracker", clutch_ct)
    add_clutch_source("csrep", clutch_rep)
    add_clutch_source("csstats", clutch_cs)

    local clutch_labels = { "1v1", "1v2", "1v3", "1v4", "1v5" }
    for _, label in ipairs(clutch_labels) do
        local bucket = clutch_map[label]
        if bucket and #bucket > 0 then
            -- Weights by matches tracked (floored so unknown providers still
            -- contribute), mirroring aggregate_value's raw-weight rule.
            local total_raw = 0
            for _, item in ipairs(bucket) do
                local reported = match_counts[item.provider] or 0
                item.matches = reported
                item.raw_weight = reported > 0 and reported or DEFAULT_MATCH_FLOOR
                total_raw = total_raw + item.raw_weight
            end
            -- Primary: most matches tracked; static priority breaks ties.
            local primary = bucket[1]
            for _, item in ipairs(bucket) do
                local prio_new = PROVIDER_PRIORITY[item.provider] or 99
                local prio_cur = PROVIDER_PRIORITY[primary.provider] or 99
                if item.raw_weight > primary.raw_weight
                    or (item.raw_weight == primary.raw_weight and prio_new < prio_cur) then
                    primary = item
                end
            end

            local contributions = {}
            for _, item in ipairs(bucket) do
                contributions[#contributions + 1] = {
                    provider   = item.provider,
                    wins       = item.entry.wins,
                    losses     = item.entry.losses,
                    winrate    = item.entry.winrate,
                    weight     = item.raw_weight / total_raw,
                    matches    = item.matches,
                    is_primary = item.provider == primary.provider,
                }
            end
            -- Heaviest contributor first for stable display order; the
            -- sources list follows the same order so badges match the
            -- hover breakdown.
            table.sort(contributions, function(a, b)
                return (a.weight or 0) > (b.weight or 0)
            end)
            local sources = {}
            for _, c in ipairs(contributions) do
                sources[#sources + 1] = c.provider
            end

            profile.clutch[#profile.clutch + 1] = {
                label         = label,
                wins          = primary.entry.wins,
                losses        = primary.entry.losses,
                winrate       = primary.entry.winrate,
                sources       = sources,
                contributions = contributions,
            }
        end
    end

    -- ── Entry success ─────────────────────────────────────────────
    -- Opening-duel performance (first kills vs first deaths). CSStats
    -- reports combined and per-side counters; rows follow the clutch
    -- pattern with per-row source attribution and contributions so the
    -- UI hover shows the same per-provider breakdown as clutch.
    if parsed.csstats and type(parsed.csstats.entry) == "table" then
        local e = parsed.csstats.entry
        local sides = {
            { label = "Combined", side = e },
            { label = "T",        side = e.t },
            { label = "CT",       side = e.ct },
        }
        for _, s in ipairs(sides) do
            local side = s.side
            if type(side) == "table" and side.success_pct ~= nil then
                local matches = match_counts.csstats or 0
                profile.entry[#profile.entry + 1] = {
                    label                  = s.label,
                    success_pct            = side.success_pct,
                    attempts_per_round_pct = side.attempts_per_round_pct,
                    success_per_round_pct  = side.success_per_round_pct,
                    first_kills            = side.first_kills,
                    first_deaths           = side.first_deaths,
                    sources                = { "csstats" },
                    contributions = {
                        {
                            provider               = "csstats",
                            success_pct            = side.success_pct,
                            attempts_per_round_pct = side.attempts_per_round_pct,
                            success_per_round_pct  = side.success_per_round_pct,
                            first_kills            = side.first_kills,
                            first_deaths           = side.first_deaths,
                            weight                 = 1,
                            matches                = matches,
                            is_primary             = true,
                        },
                    },
                }
            end
        end
    end

    -- ── Trust / reputation ────────────────────────────────────────
    if parsed.cstracker then
        aggregator.extract_cstracker_trust(parsed.cstracker, profile.trust)
    end
    if parsed.csrep then
        aggregator.extract_csrep_trust(parsed.csrep, profile.trust)
    end

    -- ── Provider-specific extensions ──────────────────────────────
    -- Keep full raw data from each provider for deep-dive views
    if parsed.leetify then
        profile.provider_data.leetify = parsed.leetify
    end
    if parsed.faceit then
        profile.provider_data.faceit = parsed.faceit
    end
    if parsed.cstracker then
        -- Store CSTracker extras (match_history, map_performance, teammates)
        profile.provider_data.cstracker = {
            match_history   = parsed.cstracker.match_history,
            map_performance = parsed.cstracker.map_performance,
            teammates       = parsed.cstracker.teammates,
        }
    end
    if parsed.csrep then
        -- Store CSRep extras (commendations, crosshairs, performance_trend, ranks)
        profile.provider_data.csrep = {
            commendations      = parsed.csrep.commendations,
            medals             = parsed.csrep.medals,
            crosshairs         = parsed.csrep.crosshairs,
            performance_trend  = parsed.csrep.performance_trend,
            ranks              = parsed.csrep.ranks,
            faceit_id          = parsed.csrep.faceit_id,
            steam_level        = parsed.csrep.steam_level,
            cs2_hours          = parsed.csrep.cs2_hours,
            inventory_value    = parsed.csrep.inventory_value,
        }
    end
    if parsed.csstats then
        profile.provider_data.csstats = {
            recent_matches = parsed.csstats.recent_matches,
            damage         = parsed.csstats.damage,
            rounds         = parsed.csstats.rounds,
            entry          = parsed.csstats.entry,
            clutch_1vX     = parsed.csstats.clutch_1vX,
            multi_kills    = parsed.csstats.multi_kills,
            last_match_at  = parsed.csstats.last_match_at,
            extras         = parsed.csstats.extras,
        }
    end

    -- ── Cross-provider matched matches ────────────────────────────
    local provider_matches = {}

    if parsed.leetify and type(parsed.leetify.recent_matches) == "table" then
        local normalized = {}
        for _, m in ipairs(parsed.leetify.recent_matches) do
            normalized[#normalized + 1] = aggregator.normalize_leetify_match(m)
        end
        provider_matches.leetify = normalized
    end

    if parsed.cstracker and type(parsed.cstracker.match_history) == "table" then
        local normalized = {}
        for _, m in ipairs(parsed.cstracker.match_history) do
            normalized[#normalized + 1] = aggregator.normalize_cstracker_match(m)
        end
        provider_matches.cstracker = normalized
    end

    if parsed.csrep and type(parsed.csrep.recent_matches) == "table" then
        local normalized = {}
        for _, m in ipairs(parsed.csrep.recent_matches) do
            normalized[#normalized + 1] = aggregator.normalize_csrep_match(m)
        end
        provider_matches.csrep = normalized
    end

    if parsed.csstats and type(parsed.csstats.recent_matches) == "table" then
        local normalized = {}
        for _, m in ipairs(parsed.csstats.recent_matches) do
            normalized[#normalized + 1] = aggregator.normalize_csstats_match(m)
        end
        provider_matches.csstats = normalized
    end

    profile.matches = matcher.merge_matches(provider_matches)

    -- ── Finalize ──────────────────────────────────────────────────
    profile.aggregated_at = os.time()

    logger:info(string.format(
        "[Aggregator] Built unified profile for %s: %d providers, %d stats, %d matches, %d trust sources",
        tostring(profile.steam64_id),
        profile.provider_count,
        (function() local c = 0; for _ in pairs(profile.stats) do c = c + 1 end; return c end)(),
        #profile.matches,
        (profile.trust.cstracker_rating and 1 or 0) + (profile.trust.csrep_score and 1 or 0)
    ))

    return schema.encode(profile)
end

return aggregator
