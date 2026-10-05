---Leetify provider module.
---Fetches player stats, ratings, and match history from Leetify's public APIs.

local cjson = require("json")
local logger = require("logger")
local http_utils = require("providers.http")
local reg = require("providers/init")

local leetify = {}

local function normalize_public_leetify_profile(profile, steam_id, recent_kd, recent_kd_matches)
    local ranks = type(profile.ranks) == "table" and profile.ranks or {}
    local rating = type(profile.rating) == "table" and profile.rating or {}
    local stats = type(profile.stats) == "table" and profile.stats or {}
    local recent_matches = {}

    if type(profile.recent_matches) == "table" then
        for index = 1, math.min(#profile.recent_matches, 5) do
            local match = profile.recent_matches[index]
            if type(match) == "table" then
                recent_matches[#recent_matches + 1] = {
                    outcome = reg.optional(match.outcome),
                    map_name = reg.optional(match.map_name),
                    finished_at = reg.optional(match.finished_at),
                    score = reg.optional(match.score),
                    data_source = reg.optional(match.data_source),
                }
            end
        end
    end

    return {
        name = reg.optional(profile.name),
        steam64_id = steam_id,
        profile_id = reg.optional(profile.id),
        privacy_mode = reg.optional(profile.privacy_mode),
        winrate = reg.optional(profile.winrate),
        total_matches = reg.optional(profile.total_matches),
        first_match_date = reg.optional(profile.first_match_date),
        ranks = {
            premier = reg.optional(ranks.premier),
            faceit = reg.optional(ranks.faceit),
            faceit_elo = reg.optional(ranks.faceit_elo),
            leetify = reg.optional(ranks.leetify),
        },
        rating = {
            aim = reg.optional(rating.aim),
            positioning = reg.optional(rating.positioning),
            utility = reg.optional(rating.utility),
            clutch = reg.scaled_rating(rating.clutch),
            opening = reg.scaled_rating(rating.opening),
        },
        stats = {
            kd = recent_kd,
            kd_matches = recent_kd_matches,
            reaction_time_ms = reg.optional(stats.reaction_time_ms),
            preaim = reg.optional(stats.preaim),
            spray_accuracy = reg.optional(stats.spray_accuracy),
            counter_strafing = reg.optional(stats.counter_strafing_good_shots_ratio),
        },
        recent_matches = recent_matches,
    }
end

local function latest_legacy_rank(games, expected_rank_type, expected_source)
    for _, match in ipairs(games) do
        if type(match) == "table" then
            local rank = reg.number_or_nil(match.skillLevel)
            local rank_type = reg.number_or_nil(match.rankType)
            local source = type(match.dataSource) == "string" and match.dataSource:lower() or ""
            local source_matches = expected_source == nil or source:find(expected_source, 1, true) ~= nil
            if rank ~= nil and rank > 0 and rank_type == expected_rank_type and source_matches then
                return rank
            end
        end
    end
    return nil
end

local function average_legacy_stat(games, limit, key, multiplier)
    local total = 0
    local count = 0
    for index = 1, math.min(#games, limit) do
        local match = games[index]
        local value = type(match) == "table" and reg.number_or_nil(match[key]) or nil
        if value ~= nil and value > 0 then
            total = total + value
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return (total / count) * (multiplier or 1)
end

local function aggregate_legacy_kd(games, limit)
    local kills = 0
    local deaths = 0
    local matches = 0
    for index = 1, math.min(#games, limit) do
        local match = games[index]
        local match_kills = type(match) == "table" and reg.number_or_nil(match.kills) or nil
        local match_deaths = type(match) == "table" and reg.number_or_nil(match.deaths) or nil
        if match_kills ~= nil and match_deaths ~= nil and match_deaths > 0 then
            kills = kills + match_kills
            deaths = deaths + match_deaths
            matches = matches + 1
        end
    end
    if deaths == 0 then return nil, nil end
    return kills / deaths, matches
end

---Compute recent K/D from an already-decoded matches payload (shared by the
---legacy fetch path and the parallel pipeline).
local function compute_recent_kd_from_payload(matches, steam_id)
    local kills = 0
    local deaths = 0
    local match_count = 0
    for _, match in ipairs(matches) do
        local player_stats = type(match) == "table" and match.stats or nil
        if type(player_stats) == "table" then
            for _, player in ipairs(player_stats) do
                if type(player) == "table" and tostring(player.steam64_id) == steam_id then
                    local player_kills = reg.number_or_nil(player.total_kills)
                    local player_deaths = reg.number_or_nil(player.total_deaths)
                    if player_kills ~= nil and player_deaths ~= nil and player_deaths > 0 then
                        kills = kills + player_kills
                        deaths = deaths + player_deaths
                        match_count = match_count + 1
                    end
                    break
                end
            end
        end
    end
    if deaths == 0 then return nil, nil end
    return kills / deaths, match_count
end

local function get_public_recent_kd(steam_id, headers)
    local url = "https://api-public.cs-prod.leetify.com/v3/profile/matches?steam64_id=" .. steam_id
    logger:info("Leetify: fetching match history " .. url)
    local matches, status, request_error = http_utils.get_json(url, headers, 4)
    if matches == nil then
        logger:info("Optional Leetify match history unavailable (" .. tostring(status) .. "): " .. tostring(request_error))
        return nil, nil
    end
    return compute_recent_kd_from_payload(matches, steam_id)
end

local function subtract_decimal_strings(left, right)
    local result = {}
    local borrow = 0
    local right_offset = #left - #right
    for index = #left, 1, -1 do
        local left_digit = tonumber(left:sub(index, index))
        local right_index = index - right_offset
        local right_digit = right_index >= 1 and tonumber(right:sub(right_index, right_index)) or 0
        if left_digit == nil or right_digit == nil then return nil end
        local digit = left_digit - right_digit - borrow
        if digit < 0 then
            digit = digit + 10
            borrow = 1
        else
            borrow = 0
        end
        result[#result + 1] = tostring(digit)
    end
    if borrow ~= 0 then return nil end
    local value = table.concat(result):reverse():gsub("^0+", "")
    return value ~= "" and value or "0"
end

local function table_contains(values, expected)
    if type(values) ~= "table" then return false end
    for _, value in ipairs(values) do
        if value == expected then return true end
    end
    return false
end

---Parse SCOPE.GG __NEXT_DATA__ HTML for the Sniper median-damage-time
---range (seconds → ms). Pure: shared by the legacy path and the pipeline.
local function parse_scope_damage(html)
    local next_data_json = html:match('<script id="__NEXT_DATA__" type="application/json">(.-)</script>')
    if next_data_json == nil then return nil, nil end

    local ok, next_data = pcall(cjson.decode, next_data_json)
    if not ok or type(next_data) ~= "table" then return nil, nil end

    local props = type(next_data.props) == "table" and next_data.props or {}
    local initial_state = type(props.initialState) == "table" and props.initialState or {}
    local dashboard = type(initial_state.publicDashboard) == "table" and initial_state.publicDashboard or {}
    local ratings = type(dashboard.ratings) == "table" and dashboard.ratings or {}
    local rating_payload = type(ratings.ratings) == "table" and ratings.ratings or {}
    local all_ratings = type(rating_payload.Ratings) == "table" and rating_payload.Ratings or {}
    local by_side = type(all_ratings.StatsBySide) == "table" and all_ratings.StatsBySide or {}
    local general = type(by_side.GeneralStats) == "table" and by_side.GeneralStats or {}
    local metrics = type(general.Metrics) == "table" and general.Metrics or {}

    for _, metric in ipairs(metrics) do
        if type(metric) == "table" and metric.ID == "MedianDamageTimeByClass" and table_contains(metric.ShowToRoles, "Sniper") then
            local aggregated = type(metric.Aggregated) == "table" and metric.Aggregated or {}
            local range = type(aggregated[1]) == "table" and aggregated[1] or {}
            local minimum = reg.number_or_nil(range[1])
            local maximum = reg.number_or_nil(range[2])
            if minimum ~= nil and maximum ~= nil then
                return minimum * 1000, maximum * 1000
            end
        end
    end

    return nil, nil
end

local function get_scope_damage_time(steam_id)
    local account_id = subtract_decimal_strings(steam_id, "76561197960265728")
    if account_id == nil then return nil, nil, nil end

    local scope_url = "https://app.scope.gg/progress/" .. account_id
    local response, request_error = http_utils.get_raw(scope_url, { ["Accept"] = "text/html" }, 6)

    if response == nil or response.status < 200 or response.status >= 300 then
        logger:info("Optional SCOPE.GG enrichment unavailable (" .. tostring(response and response.status or 0) .. "): " .. tostring(request_error))
        return nil, nil, nil
    end

    local minimum, maximum = parse_scope_damage(response.body)
    if minimum ~= nil then
        return minimum, maximum, scope_url
    end
    return nil, nil, nil
end

local function normalize_legacy_leetify_profile(profile, steam_id)
    local ratings = type(profile.recentGameRatings) == "table" and profile.recentGameRatings or {}
    local meta = type(profile.meta) == "table" and profile.meta or {}
    local games = type(profile.games) == "table" and profile.games or {}
    local games_played = reg.number_or_nil(ratings.gamesPlayed) or #games
    local aggregate_limit = math.min(#games, games_played)
    local wins = 0
    local recent_matches = {}
    local recent_kd, recent_kd_matches = aggregate_legacy_kd(games, aggregate_limit)

    for index = 1, aggregate_limit do
        local match = games[index]
        if type(match) == "table" and match.matchResult == "win" then
            wins = wins + 1
        end
    end

    for index = 1, math.min(#games, 5) do
        local match = games[index]
        if type(match) == "table" then
            recent_matches[#recent_matches + 1] = {
                outcome = reg.optional(match.matchResult),
                map_name = reg.optional(match.mapName),
                finished_at = reg.optional(match.gameFinishedAt),
                score = reg.optional(match.scores),
                data_source = reg.optional(match.dataSource),
            }
        end
    end

    local first_match_date = nil
    if #games > 0 and type(games[#games]) == "table" then
        first_match_date = reg.optional(games[#games].gameFinishedAt)
    end

    return {
        name = reg.optional(meta.name),
        steam64_id = steam_id,
        profile_id = reg.optional(meta.leetifyUserId),
        privacy_mode = "public",
        winrate = aggregate_limit > 0 and wins / aggregate_limit or nil,
        total_matches = games_played,
        first_match_date = first_match_date,
        ranks = {
            premier = latest_legacy_rank(games, 11, "matchmaking"),
            faceit = latest_legacy_rank(games, 3, "faceit"),
            faceit_elo = nil,
            leetify = reg.scaled_rating(ratings.leetify),
        },
        rating = {
            aim = reg.optional(ratings.aim),
            positioning = reg.optional(ratings.positioning),
            utility = reg.optional(ratings.utility),
            clutch = reg.scaled_rating(ratings.clutch),
            opening = reg.scaled_rating(ratings.opening),
        },
        stats = {
            kd = recent_kd,
            kd_matches = recent_kd_matches,
            reaction_time_ms = average_legacy_stat(games, aggregate_limit, "reactionTime", 1000),
            preaim = average_legacy_stat(games, aggregate_limit, "preaim"),
            spray_accuracy = nil,
            counter_strafing = nil,
        },
        recent_matches = recent_matches,
    }
end

function leetify.fetch(steam_id)
    if not reg.valid_steam_id(steam_id) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    local headers = { ["Accept"] = "application/json" }
    local api_key = reg.trimmed_config("leetify_api_key")
    if api_key ~= nil then
        headers["_leetify_key"] = api_key
    end

    local url = "https://api-public.cs-prod.leetify.com/v3/profile?steam64_id=" .. steam_id
    logger:info("Leetify: fetching " .. url .. (api_key and " (with API key)" or " (no API key)"))
    local profile, status, request_error = http_utils.get_json(url, headers)
    if profile == nil then
        if status ~= 404 then
            return reg.provider_error("Leetify", status, request_error)
        end

        local legacy_url = "https://api.cs-prod.leetify.com/api/profile/id/" .. steam_id
        local legacy_headers = {
            ["Accept"] = "application/json",
            ["Origin"] = "https://leetify.com",
            ["Referer"] = "https://leetify.com/",
        }
        logger:info("Leetify: falling back to legacy API " .. legacy_url)
        local legacy_profile, legacy_status, legacy_error = http_utils.get_json(legacy_url, legacy_headers)
        if legacy_profile == nil then
            return reg.provider_error("Leetify legacy profile", legacy_status, legacy_error)
        end

        local legacy_ratings = type(legacy_profile.recentGameRatings) == "table" and legacy_profile.recentGameRatings or {}
        local legacy_games = type(legacy_profile.games) == "table" and legacy_profile.games or {}
        if next(legacy_ratings) == nil and #legacy_games == 0 then
            return reg.encode({ status = "not_found", message = "Leetify has no public matches for this Steam account." })
        end

        local normalized_profile = normalize_legacy_leetify_profile(legacy_profile, steam_id)
        if normalized_profile.stats.reaction_time_ms == nil then
            local damage_time_min_ms, damage_time_max_ms, scope_url = get_scope_damage_time(steam_id)
            normalized_profile.stats.damage_time_min_ms = damage_time_min_ms
            normalized_profile.stats.damage_time_max_ms = damage_time_max_ms
            normalized_profile.stats.damage_time_source_url = scope_url
        end

        logger:info("Using Leetify web profile fallback for SteamID64 " .. steam_id)
        return reg.encode({
            status = "ok",
            data = normalized_profile,
            fetched_at = os.time(),
        })
    end

    if profile.privacy_mode ~= nil and profile.privacy_mode ~= cjson.null and profile.privacy_mode ~= "public" then
        return reg.encode({ status = "private", message = "This Leetify profile is private." })
    end

    local recent_kd, recent_kd_matches = get_public_recent_kd(steam_id, headers)
    return reg.encode({
        status = "ok",
        data = normalize_public_leetify_profile(profile, steam_id, recent_kd, recent_kd_matches),
        fetched_at = os.time(),
    })
end

---Parallel pipeline: same steps/fallbacks as leetify.fetch, driven by the
---coordinator's curl_multi pump instead of blocking RPCs.
function leetify.pipeline(steam_id)
    local p = { phase = "public", queue = {}, finished = false }

    local headers = { ["Accept"] = "application/json" }
    local api_key = reg.trimmed_config("leetify_api_key")
    if api_key ~= nil then
        headers["_leetify_key"] = api_key
    end

    local function push(req)
        p.queue[#p.queue + 1] = req
    end

    local function finish_public(profile, recent_kd, recent_kd_matches)
        p:finish(reg.encode({
            status = "ok",
            data = normalize_public_leetify_profile(profile, steam_id, recent_kd, recent_kd_matches),
            fetched_at = os.time(),
        }))
    end

    local function finish_legacy(legacy_profile)
        local legacy_ratings = type(legacy_profile.recentGameRatings) == "table" and legacy_profile.recentGameRatings or {}
        local legacy_games = type(legacy_profile.games) == "table" and legacy_profile.games or {}
        if next(legacy_ratings) == nil and #legacy_games == 0 then
            p:finish(reg.encode({ status = "not_found", message = "Leetify has no public matches for this Steam account." }))
            return
        end
        local normalized = normalize_legacy_leetify_profile(legacy_profile, steam_id)
        if normalized.stats.reaction_time_ms == nil then
            p.normalized = normalized
            p.phase = "scope"
            return -- next() submits SCOPE.GG or finishes
        end
        p:finish(reg.encode({ status = "ok", data = normalized, fetched_at = os.time() }))
    end

    function p.next()
        if p.phase == "public" then
            local url = "https://api-public.cs-prod.leetify.com/v3/profile?steam64_id=" .. steam_id
            logger:info("Leetify: fetching " .. url .. (api_key and " (with API key)" or " (no API key)"))
            push(http_utils.get_req(url, headers, 10))
        elseif p.phase == "matches" then
            push(http_utils.get_req(
                "https://api-public.cs-prod.leetify.com/v3/profile/matches?steam64_id=" .. steam_id,
                headers, 4))
        elseif p.phase == "legacy" then
            local legacy_url = "https://api.cs-prod.leetify.com/api/profile/id/" .. steam_id
            logger:info("Leetify: falling back to legacy API " .. legacy_url)
            push(http_utils.get_req(legacy_url, {
                ["Accept"] = "application/json",
                ["Origin"] = "https://leetify.com",
                ["Referer"] = "https://leetify.com/",
            }, 10))
        elseif p.phase == "scope" then
            local account_id = subtract_decimal_strings(steam_id, "76561197960265728")
            if account_id == nil then
                p:finish(reg.encode({ status = "ok", data = p.normalized, fetched_at = os.time() }))
                return nil
            end
            p.scope_url = "https://app.scope.gg/progress/" .. account_id
            push(http_utils.get_req(p.scope_url, { ["Accept"] = "text/html" }, 6))
        end
        if #p.queue == 0 then return nil end
        local q = p.queue
        p.queue = {}
        return q
    end

    -- NOTE: invoked colon-style (p:handle) — self is the pipeline table.
    function p.handle(self, req, resp)
        if p.phase == "public" then
            local profile, status, err = http_utils.resp_json(resp)
            if profile == nil then
                if status ~= 404 then
                    p:finish(reg.provider_error("Leetify", status, err))
                    return
                end
                p.phase = "legacy"
                return
            end
            if profile.privacy_mode ~= nil and profile.privacy_mode ~= cjson.null and profile.privacy_mode ~= "public" then
                p:finish(reg.encode({ status = "private", message = "This Leetify profile is private." }))
                return
            end
            p.profile = profile
            p.phase = "matches"
        elseif p.phase == "matches" then
            local matches, status, err = http_utils.resp_json(resp)
            local recent_kd, recent_kd_matches = nil, nil
            if matches == nil then
                logger:info("Optional Leetify match history unavailable (" .. tostring(status) .. "): " .. tostring(err))
            else
                recent_kd, recent_kd_matches = compute_recent_kd_from_payload(matches, steam_id)
            end
            finish_public(p.profile, recent_kd, recent_kd_matches)
        elseif p.phase == "legacy" then
            local legacy_profile, status, err = http_utils.resp_json(resp)
            if legacy_profile == nil then
                p:finish(reg.provider_error("Leetify legacy profile", status, err))
                return
            end
            finish_legacy(legacy_profile)
        elseif p.phase == "scope" then
            local minimum, maximum = nil, nil
            if resp.status ~= nil and resp.status >= 200 and resp.status < 300 and type(resp.body) == "string" then
                minimum, maximum = parse_scope_damage(resp.body)
            else
                logger:info("Optional SCOPE.GG enrichment unavailable (" .. tostring(resp.status or 0) .. "): " .. tostring(resp.error))
            end
            p.normalized.stats.damage_time_min_ms = minimum
            p.normalized.stats.damage_time_max_ms = maximum
            p.normalized.stats.damage_time_source_url = (minimum ~= nil) and p.scope_url or nil
            p:finish(reg.encode({ status = "ok", data = p.normalized, fetched_at = os.time() }))
        end
    end

    return p
end

reg.register({
    name = "leetify",
    display_name = "Leetify",
    config_key = "leetify_api_key",
    fetch = leetify.fetch,
    pipeline = leetify.pipeline,
})

return leetify
