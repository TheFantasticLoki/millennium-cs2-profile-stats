---@meta

---Unified aggregated data schema for CS2 Profile Stats.
---
---Defines the canonical structure for merged player data from all providers.
---Every field uses a normalized format so the frontend only needs one set of
---type definitions regardless of which providers contributed data.
---
---Normalization rules:
---  - Percentages: 0–100 float (e.g. 62.4 means 62.4%)
---  - K/D: ratio float  (e.g. 1.39)
---  - Ratings: provider-native scale, documented per field
---  - Timestamps: ISO-8601 strings or unix seconds

local cjson = require("json")

local schema = {}

---Provider names used throughout the aggregation layer.
schema.PROVIDERS = { "leetify", "faceit", "cstracker", "csrep", "csstats" }

---Create an empty aggregated profile ready to be populated incrementally.
---All fields start as nil so partial results are naturally handled.
---@return table profile
function schema.new_profile()
    return {
        -- ── Identity ──────────────────────────────────────────────
        steam64_id = nil,       -- string  "76561198000000000"
        name      = nil,        -- string  Best-available display name

        -- ── Normalized performance stats ──────────────────────────
        -- Each value is a AggValue: { value, sources[] }
        -- Sources is a list of provider names that contributed to this value.
        stats = {
            kd              = nil,  -- float ratio  (kills / deaths)
            winrate         = nil,  -- float 0–100   (percent)
            adr             = nil,  -- float          (average damage per round)
            headshot_pct    = nil,  -- float 0–100   (headshot % of kills)
            head_accuracy   = nil,  -- float 0–100   (headshot % of ALL shots; CSRep metric — different denominator from headshot_pct)
            hltv_rating     = nil,  -- float          (HLTV 2.0 rating, ~0.5–2.0)
            kast            = nil,  -- float 0–100   (KAST percentage)
            kills           = nil,  -- int            (total kills)
            deaths          = nil,  -- int            (total deaths)
            assists         = nil,  -- int            (total assists)
            total_matches   = nil,  -- int            (total matches played)
            accuracy        = nil,  -- float 0–100   (shooting accuracy %)
            spray_accuracy  = nil,  -- float 0–100   (spray accuracy %)
            preaim          = nil,  -- float degrees  (pre-aim angle)
            aim_offset      = nil,  -- float degrees  (aim offset)
            counter_strafing= nil,  -- float 0–100   (counter-strafe %)
            reaction_time_ms= nil,  -- float ms      (median reaction time)
            ttd             = nil,  -- int ms         (time-to-damage)
            spot_to_damage  = nil,  -- int ms         (spot to damage)
            spot_to_kill    = nil,  -- int ms         (spot to kill)
            first_kills     = nil,  -- int            (entry kills)
            trade_kills     = nil,  -- int            (trade kills)
            enemy_damage    = nil,  -- float          (total enemy damage)
            bhop_success    = nil,  -- float 0–100   (bunny hop success %)
        },

        -- ── Ranks ─────────────────────────────────────────────────
        ranks = {
            premier     = nil,  -- int  (premier rating points)
            faceit      = nil,  -- int  (FACEIT level 1-10)
            faceit_elo  = nil,  -- int  (FACEIT ELO)
            leetify     = nil,  -- float (-10 to +10)
        },

        -- ── Utility stats ─────────────────────────────────────────
        utility = {
            grenade_throws       = nil,  -- int
            flash_assists        = nil,  -- int
            enemies_flashed_per_flash = nil,  -- float
            avg_flash_duration   = nil,  -- float seconds
            util_dmg_per_match   = nil,  -- float
            he_dmg_per_throw     = nil,  -- float
            fire_dmg_per_throw   = nil,  -- float
            unused_util_on_death = nil,  -- int
        },

        -- ── Behavior stats ────────────────────────────────────────
        behavior = {
            afk_time_per_match          = nil,  -- int seconds
            teamkills_per_match         = nil,  -- float
            team_damage_per_match       = nil,  -- float
            avg_teammates_flashed       = nil,  -- float
            teammate_flash_duration     = nil,  -- float seconds
            input_automation            = nil,  -- float 0–100
            vote_kicked                 = nil,  -- float 0–100
            team_dmg_kicks              = nil,  -- float 0–100
        },

        -- ── Kill breakdown ────────────────────────────────────────
        kill_breakdown = {
            wallbangs       = nil,  -- { count, total, percentage }
            through_smokes  = nil,
            in_air          = nil,
            noscope         = nil,
            headshots       = nil,
        },

        -- ── Multi-kills (rounds with N kills) ─────────────────────
        -- Each value is a AggValue: { value, sources[] }
        multi_kills = {
            double = nil,  -- int — rounds with a double kill
            triple = nil,  -- int — rounds with a triple kill
            quad   = nil,  -- int — rounds with a quad kill
            penta  = nil,  -- int — aces (all 5 enemies)
        },

        -- ── Clutch performance ────────────────────────────────────
        -- Array of { label="1v1"…1v5, wins, losses, winrate,
        --            sources[], contributions[]? }
        -- contributions: { provider, wins, losses, winrate, weight,
        --                  matches, is_primary } — the per-provider
        -- numbers behind the resolved values, for hover breakdowns.
        clutch = {},

        -- ── Entry success (opening duels) ─────────────────────────
        -- Array of { label="Combined"|"T"|"CT", success_pct,
        --            attempts_per_round_pct, success_per_round_pct,
        --            first_kills, first_deaths, sources[],
        --            contributions[]? }
        -- Populated from CSStats first-kill/first-death counters.
        entry = {},

        -- ── Leetify-specific ratings ──────────────────────────────
        leetify_rating = {
            aim          = nil,  -- float (0–100)
            positioning  = nil,  -- float (0–100)
            utility      = nil,  -- float (0–100)
            clutch       = nil,  -- float (-10 to +10, scaled)
            opening      = nil,  -- float (-10 to +10, scaled)
        },

        -- ── Trust / reputation ────────────────────────────────────
        trust = {
            cstracker_rating    = nil,  -- int 0–100
            cstracker_breakdown = {},   -- { { factor, delta } } reasons below 100
            csrep_score         = nil,  -- int 0–100
            csrep_label         = nil,  -- string
            csrep_statistical   = nil,  -- int
            csrep_account_flags = nil,  -- int
            csrep_anomalies     = nil,  -- int
            csrep_account_bonus = nil,  -- int
            csrep_breakdown     = {},   -- { { factor, value, is_penalty? } }
            has_ban             = false,
            bans                = {},   -- provider-specific ban data
        },

        -- ── Provider-specific extensions ──────────────────────────
        -- Data that has no cross-provider equivalent is kept under
        -- its provider key so nothing is lost.
        provider_data = {
            leetify   = nil,  -- full raw Leetify data (reaction time, match scores…)
            faceit    = nil,  -- full raw FACEIT data (nickname, country, recent_results…)
            cstracker = nil,  -- CSTracker extras (map_performance, teammates, match_history)
            csrep     = nil,  -- CSRep extras (commendations, crosshairs, performance_trend, ranks per map)
            csstats   = nil,  -- CSStats extras (entry, weapons, maps, extras)
        },

        -- ── Cross-provider matched matches ────────────────────────
        -- Each entry is a unified match record merged from 1+ providers.
        matches = {},

        -- ── Metadata ──────────────────────────────────────────────
        provider_count   = 0,   -- how many providers returned ok
        providers_used   = {},  -- list of provider names with data
        aggregated_at    = nil, -- unix timestamp of last aggregation
    }
end

---Create a new AggValue wrapper.
---@param value any The normalized value
---@param source string The provider name that provided this value
---@return table aggValue
function schema.agg_value(value, source)
    if value == nil then return nil end
    return {
        value   = value,
        sources = { source },
    }
end

---Create an AggValue from a resolved stat that already carries
---per-provider contributions (see aggregator.resolve_stat).
---Each contribution records the provider's own value, its weight in the
---blend, how many matches it had tracked, and whether it was primary.
---@param value any The resolved/normalized value
---@param sources string[] Provider names that contributed
---@param contributions table[] { provider, value, weight, matches, is_primary }
---@return table aggValue
function schema.agg_value_contributions(value, sources, contributions)
    if value == nil then return nil end
    return {
        value         = value,
        sources       = sources,
        contributions = contributions or {},
    }
end

---Create a new AggValue from multiple sources (used when merging identical values).
---@param value any The normalized value
---@param sources string[] List of provider names
---@return table aggValue
function schema.agg_value_multi(value, sources)
    if value == nil then return nil end
    return {
        value   = value,
        sources = sources,
    }
end

---Encode an aggregated profile to JSON.
---@param profile table
---@return string
function schema.encode(profile)
    local ok, result = pcall(cjson.encode, profile)
    if ok then return result end
    return '{"status":"error","message":"Failed to encode aggregated profile."}'
end

---Decode a JSON string to an aggregated profile table.
---@param json_str string
---@return table|nil profile, string|nil error
function schema.decode(json_str)
    local ok, result = pcall(cjson.decode, json_str)
    if ok and type(result) == "table" then return result, nil end
    return nil, tostring(result)
end

return schema
