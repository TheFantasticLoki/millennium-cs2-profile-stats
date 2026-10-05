---CSRep.GG provider module.
---Fetches player data via CSRep's internal JSON API.
---
---Data available: Trust score, breakdown (Statistical Trust, Account Flags,
---Anomalies, Account Bonus), performance stats (kills, deaths, K/D, clutches,
---multi-kills, first kills/deaths, trade kills), ranks per map/season,
---commendations, bans, faceit ID, crosshairs, match history.
---
---Requires FlareSolverr to bypass Cloudflare protection and obtain a
---cf_clearance cookie for API authentication.

local cjson = require("json")
local logger = require("logger")
local http_utils = require("providers.http")
local reg = require("providers/init")

local csrep = {}

---CSRep API base URL.
local API_BASE = "https://csrep.gg/api/players/"

---Fetch a single CSRep API endpoint.
---@param steam_id string
---@param endpoint string e.g. "" for main, "/performance", "/ranks", etc.
---@param cf_cookie string
---@return table|nil result, string|nil error
local function fetch_endpoint(steam_id, endpoint, cf_cookie)
    local url = API_BASE .. steam_id .. endpoint
    return http_utils.csrep_api_get(url, cf_cookie)
end

---Determine trust label from numeric score.
---Coerces JSON null (cjson userdata) and numeric strings safely.
---@param score number|string|nil
---@return string|nil
local function trust_label(score)
    local n = reg.number_or_nil(score)
    if n == nil then return nil end
    if n >= 80 then return "Excellent"
    elseif n >= 60 then return "Good"
    elseif n >= 40 then return "Moderate"
    elseif n >= 20 then return "Low"
    else return "Danger" end
end

---Normalize a numeric API field, treating JSON null (cjson userdata) as absent.
---@param value any
---@param default number|nil
---@return number|nil
local function num(value, default)
    return reg.number_or_nil(value) or default
end

---Read the first present numeric field from a list of candidate keys.
---Defends against CSRep renaming clutch/multi-kill fields across API
---versions — if none of the candidates resolve, the default is returned.
---@param tbl table
---@param keys string[]
---@param default number|nil
---@return number|nil
local function num_any(tbl, keys, default)
    for _, key in ipairs(keys) do
        local v = reg.number_or_nil(tbl[key])
        if v ~= nil then return v end
    end
    return default
end

---Normalize a decoded API payload to a table, treating JSON null (cjson
---userdata sentinel) and any non-table value as absent so fields below can
---be indexed safely.
---@param value any
---@return table|nil
local function as_table(value)
    if type(value) == "table" then
        return value
    end
    return nil
end

---Normalize a CSRep mini-profile percentage stat.
---CSRep returns KAST and headshot accuracy as 0-1 fractions (e.g. 0.707
---for 70.7%), while the plugin schema expects 0-100 percentages.
---@param value any
---@return number|nil
local function percent_stat(value)
    local n = reg.number_or_nil(value)
    if n == nil then return nil end
    -- If already > 1, assume it's already a percentage.
    if n > 1 then return n end
    return math.floor(n * 10000 + 0.5) / 100
end

---Build the final CSRep provider JSON from collected endpoint payloads.
---Shared by the legacy fetch path and the parallel pipeline so both emit
---byte-identical data tables.
local function build_player_json(steam_id, main, performance, ranks, mini, crosshairs, matches, perf_trend)
    -- as_table() guards against cjson decoding JSON null as userdata, which
    -- is truthy but crashes when indexed (e.g. `rep.breakdown`).
    local rep = as_table(main.reputation) or {}
    local rep_breakdown = as_table(rep.breakdown) or {}
    -- Normalize JSON null (cjson userdata) to nil so downstream consumers
    -- (trust_label, aggregator.extract_csrep_trust) don't see a fake value.
    local ts = reg.optional(rep.trust_score)
    -- CSRep trust components arrive on a 0-1 scale where 1 = full trust and
    -- 0 = no trust (statistical_trust, account_flags, anomalies); account_bonus
    -- is a fractional adjustment (0.0111 = +1.11%). Scale all of them to
    -- 0-100 / percentage points so they share trust_score's scale for the
    -- breakdown UI and the aggregator.
    local stats_trust_pct = reg.scaled_rating(rep.statistical_trust)
    local flags_pct = reg.scaled_rating(rep_breakdown.account_flags)
    local anomalies_pct = reg.scaled_rating(rep_breakdown.anomalies)
    local bonus_pct = reg.scaled_rating(rep.account_bonus)
    local stats = as_table(mini and mini.stats) or {}

    -- Build performance data
    local perf = performance or {}

    -- Build clutches summary
    -- (num_any treats JSON null as missing and tolerates key renames;
    --  v2_won previously read clutches_1v1_won — a copy-paste bug.)
    local clutches = {
        total  = num_any(perf, { "clutches", "clutch_total" }, 0),
        won    = num_any(perf, { "clutches_won", "clutch_won" }, 0),
        lost   = num_any(perf, { "clutches_lost", "clutch_lost" }, 0),
        v1     = num_any(perf, { "clutches_1v1", "clutch_1v1" }, 0),
        v1_won = num_any(perf, { "clutches_1v1_won", "clutch_1v1_won" }, 0),
        v2     = num_any(perf, { "clutches_1v2", "clutch_1v2" }, 0),
        v2_won = num_any(perf, { "clutches_1v2_won", "clutch_1v2_won" }, 0),
        v3     = num_any(perf, { "clutches_1v3", "clutch_1v3" }, 0),
        v3_won = num_any(perf, { "clutches_1v3_won", "clutch_1v3_won" }, 0),
        v4     = num_any(perf, { "clutches_1v4", "clutch_1v4" }, 0),
        v4_won = num_any(perf, { "clutches_1v4_won", "clutch_1v4_won" }, 0),
        v5     = num_any(perf, { "clutches_1v5", "clutch_1v5" }, 0),
        v5_won = num_any(perf, { "clutches_1v5_won", "clutch_1v5_won" }, 0),
    }

    -- Build multi-kill data
    local multi_kills = {
        double = num_any(perf, { "double_kills", "kills_double", "multi_kill_double" }, 0),
        triple = num_any(perf, { "triple_kills", "kills_triple", "multi_kill_triple" }, 0),
        quad   = num_any(perf, { "quad_kills", "kills_quad", "multi_kill_quad" }, 0),
        penta  = num_any(perf, { "penta_kills", "kills_penta", "multi_kill_penta", "pentakill" }, 0),
    }

    -- Build rank data (flatten the per-map ranks)
    local rank_data = {}
    if ranks then
        for key, val in pairs(ranks) do
            if type(val) == "table" and val.current ~= nil then
                rank_data[key] = {
                    current = val.current,
                    peak = val.peak,
                    wins = val.wins or 0,
                    losses = val.loses or 0,
                    matches = val.count or 0,
                    last_played = val.last_played,
                }
            end
        end
    end

    -- Compute win rate
    local matches_played = num(perf.matches_played, 0)
    local matches_won = num(perf.matches_won, 0)
    local win_rate = nil
    if matches_played > 0 then
        win_rate = math.floor((matches_won / matches_played) * 10000 + 0.5) / 100
    end

    -- Compute K/D ratio
    local kills = num(perf.kills, 0)
    local deaths = num(perf.deaths, 0)
    local kd_ratio = nil
    if deaths > 0 then
        kd_ratio = math.floor((kills / deaths) * 100 + 0.5) / 100
    elseif kills > 0 then
        kd_ratio = kills -- No deaths = perfect K/D
    end

    logger:info(string.format(
        "CSRep: trust=%s, stats_trust=%s, flags=%s, anomalies=%s, bonus=%s, kills=%d, deaths=%d, matches=%d, clutches=%d/%d, mk=%d/%d/%d/%d",
        tostring(ts), tostring(stats_trust_pct),
        tostring(flags_pct), tostring(anomalies_pct),
        tostring(bonus_pct), kills, deaths, matches_played,
        clutches.total, clutches.won,
        multi_kills.double, multi_kills.triple, multi_kills.quad, multi_kills.penta
    ))

    return reg.encode({
        status = "ok",
        data = {
            steam64_id = steam_id,

            -- Player info
            name = main.name,
            avatar = main.avatar,
            steam_level = main.steam_level,
            steam_status = main.steam_status,
            steam_privacy = main.steam_privacy,
            steam_created_at = main.steam_created_at,
            cs2_hours = main.cs2_hours,
            inventory_value = main.inventory_value,
            profile_url = "https://csrep.gg/player/" .. steam_id,

            -- Trust / Reputation (components normalized to 0-100 above)
            trust_score = ts,
            trust_label = trust_label(ts),
            statistical_trust = stats_trust_pct,
            account_flags = flags_pct,
            anomalies = anomalies_pct,
            account_bonus = bonus_pct,
            autoflag = main.autoflag,

            -- Bans (normalize JSON null to an empty list before taking length)
            bans = reg.optional(main.bans) or {},
            has_ban = #((reg.optional(main.bans) or {})) > 0,

            -- External IDs
            faceit_id = main.faceit_id,
            faceit_url = main.faceit_url,
            gamersclub_id = main.gamersclub_id,
            gamersclub_url = main.gamersclub_url,

            -- Commendations / medals (normalize JSON null → nil so
            -- downstream consumers never index cjson userdata)
            commendations = as_table(main.commendations),
            medals = as_table(main.medals),

            -- Performance stats (aggregated)
            performance = {
                matches_played = matches_played,
                matches_won = matches_won,
                win_rate = win_rate,
                rounds = num(perf.rounds, 0),
                kills = kills,
                deaths = deaths,
                assists = num(perf.assists, 0),
                kd_ratio = kd_ratio,

                -- First kills / deaths
                first_kills = num(perf.first_kills, 0),
                first_deaths = num(perf.first_deaths, 0),

                -- Trade kills
                trade_kills = num(perf.trade_kills, 0),
                trade_deaths = num(perf.trade_deaths, 0),

                -- Multi-kills
                multi_kills = multi_kills,

                -- Clutches
                clutches = clutches,
            },

            -- HLTV Rating, ADR, Accuracy, KAST from mini-profile
            -- CSRep returns KAST and headshot accuracy as 0-1 fractions;
            -- normalize them to the 0-100 percentages used everywhere else.
            stats = {
                hltv_rating_2 = stats.hltv_rating_2,
                adr = stats.adr,
                accuracy_head = percent_stat(stats.accuracy_head),
                kast = percent_stat(stats.kast),
            },

            -- Ranks (per map/season)
            ranks = rank_data,

            -- Crosshairs
            crosshairs = crosshairs or {},

            -- Recent matches
            recent_matches = matches or {},

            -- Performance trend data
            performance_trend = perf_trend or {},
        },
        fetched_at = os.time(),
    })
end

---Fetch all available CSRep data for a player.
---Uses multiple API endpoints to get comprehensive data.
---@param steam_id string
---@return string JSON-encoded response
local function fetch_player_data(steam_id)
    logger:info("CSRep: fetching data for " .. steam_id)

    -- Step 1: Get a fresh cf_clearance cookie via FlareSolverr
    local cf_cookie, cookie_err = http_utils.csrep_get_cookie()
    if cf_cookie == nil then
        logger:warn("CSRep: failed to get cookie: " .. tostring(cookie_err))
        return reg.encode({
            status = "cloudflare_required",
            message = "CSRep requires FlareSolverr. " .. tostring(cookie_err),
            url = "https://csrep.gg/player/" .. steam_id,
        })
    end
    logger:info("CSRep: obtained cf_clearance cookie")

    -- Step 2: Fetch main player data (includes steam info, reputation, ranks, bans)
    local main, main_err = fetch_endpoint(steam_id, "", cf_cookie)
    -- CSRep occasionally returns JSON null payloads; cjson decodes those to a
    -- userdata sentinel that is truthy but not indexable — normalize to nil.
    main = as_table(main)
    if main == nil then
        local err_msg = main_err or "empty or invalid player payload"
        logger:warn("CSRep: main endpoint failed: " .. tostring(err_msg))
        if tostring(err_msg):find("API key") then
            return reg.encode({ status = "error", message = "CSRep API authentication failed." })
        end
        return reg.encode({ status = "error", message = "CSRep: " .. tostring(err_msg) })
    end

    -- Check if player exists
    if main.redacted then
        logger:info("CSRep: player data is redacted (private): " .. steam_id)
        return reg.encode({ status = "private", message = "This player's CSRep data is private." })
    end

    -- Step 3: Fetch performance stats
    local performance, perf_err = fetch_endpoint(steam_id, "/performance", cf_cookie)
    performance = as_table(performance)
    if performance == nil then
        logger:warn("CSRep: performance endpoint failed: " .. tostring(perf_err))
    end

    -- Step 4: Fetch detailed ranks
    local ranks, ranks_err = fetch_endpoint(steam_id, "/ranks", cf_cookie)
    ranks = as_table(ranks)
    if ranks == nil then
        logger:warn("CSRep: ranks endpoint failed: " .. tostring(ranks_err))
    end

    -- Step 5: Fetch mini-profile (includes HLTV rating, ADR, accuracy, KAST)
    local mini, mini_err = fetch_endpoint(steam_id, "/mini-profile", cf_cookie)
    mini = as_table(mini)
    if mini == nil then
        logger:warn("CSRep: mini-profile endpoint failed: " .. tostring(mini_err))
    end

    -- Step 6: Fetch crosshairs
    local crosshairs, ch_err = fetch_endpoint(steam_id, "/crosshairs", cf_cookie)
    crosshairs = as_table(crosshairs)
    if crosshairs == nil then
        logger:warn("CSRep: crosshairs endpoint failed: " .. tostring(ch_err))
    end

    -- Step 7: Fetch recent matches
    local matches, matches_err = fetch_endpoint(steam_id, "/matches?limit=10", cf_cookie)
    matches = as_table(matches)
    if matches == nil then
        logger:warn("CSRep: matches endpoint failed: " .. tostring(matches_err))
    end

    -- Step 8: Fetch performance trend
    local perf_trend, trend_err = fetch_endpoint(steam_id, "/performance/trend", cf_cookie)
    perf_trend = as_table(perf_trend)
    if perf_trend == nil then
        logger:warn("CSRep: performance/trend endpoint failed: " .. tostring(trend_err))
    end

    -- Build the final payload (shared with the parallel pipeline path).
    return build_player_json(steam_id, main, performance, ranks, mini, crosshairs, matches, perf_trend)
end

function csrep.fetch(steam_id)
    if not reg.valid_steam_id(steam_id) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    return fetch_player_data(steam_id)
end

---Parallel pipeline: FlareSolverr cookie → signed main endpoint → bulk
---endpoints concurrently (direct signed GETs, per-endpoint FS fallback).
function csrep.pipeline(steam_id)
    local p = { phase = "cookie", queue = {}, finished = false, endpoints = {} }

    local FS_ENDPOINTS = {
        { tag = "performance", ep = "/performance" },
        { tag = "ranks",       ep = "/ranks" },
        { tag = "mini",        ep = "/mini-profile" },
        { tag = "crosshairs",  ep = "/crosshairs" },
        { tag = "matches",     ep = "/matches?limit=10" },
        { tag = "trend",       ep = "/performance/trend" },
    }

    local function api_url(endpoint)
        return API_BASE .. steam_id .. endpoint
    end

    ---Signed FS request for an API endpoint (direct attempts fall back to
    ---this when Cloudflare blocks the cookie-authenticated GET).
    local function push_fs_endpoint(endpoint, tag)
        local fs_url = http_utils.flaresolverr_url()
        local request_id = tostring(os.time() * 1000 + math.random(0, 999))
        local timestamp = tostring(math.floor(os.time() * 1000))
        local secret = http_utils.csrep_hash(request_id .. timestamp)
        local req = http_utils.fs_req(fs_url, {
            cmd = "request.get",
            url = api_url(endpoint),
            maxTimeout = 30000,
            session = "csrep",
            userAgent = http_utils.chrome_user_agent(),
            headers = {
                ["X-Request-ID"] = request_id,
                ["X-Request-Timestamp"] = timestamp,
                ["X-Request-Secret"] = secret,
                ["Accept"] = "application/json, text/plain, */*",
            },
        }, 40)
        req.tag = tag
        req.fs = true
        p.queue[#p.queue + 1] = req
    end

    local function push_bulk()
        p.endpoint_tags = {}
        for _, e in ipairs(FS_ENDPOINTS) do
            local req = http_utils.csrep_signed_req(api_url(e.ep), p.cookie, 10)
            req.tag = e.tag
            p.queue[#p.queue + 1] = req
            p.endpoint_tags[e.tag] = e.ep
        end
        p.pending = #FS_ENDPOINTS
    end

    ---Advance after the main endpoint resolves (direct or FS-wrapped body).
    local function handle_main_body(body, from_fs)
        local result, err, state = http_utils.csrep_decode_body(body)
        result = as_table(result)
        if state == "ok" and result ~= nil then
            p.main = result
            if p.main.redacted then
                logger:info("CSRep: player data is redacted (private): " .. steam_id)
                p:finish(reg.encode({ status = "private", message = "This player's CSRep data is private." }))
                return
            end
            p.phase = "bulk"
            push_bulk()
            return
        end
        local err_msg = err or "empty or invalid player payload"
        if tostring(err_msg):find("API key") then
            p:finish(reg.encode({ status = "error", message = "CSRep API authentication failed." }))
            return
        end
        if from_fs then
            p:finish(reg.encode({ status = "error", message = "CSRep: " .. tostring(err or "Could not parse CSRep API response") }))
            return
        end
        if state ~= "error" and http_utils.flaresolverr_url() ~= nil then
            logger:info("CSRep: direct main endpoint inconclusive (" .. tostring(err_msg) .. "); retrying via FlareSolverr")
            p.phase = "fs_main"
            push_fs_endpoint("", "fs_main")
            return
        end
        p:finish(reg.encode({ status = "error", message = "CSRep: " .. tostring(err_msg) }))
    end

    function p.next()
        if p.phase == "cookie" then
            logger:info("CSRep: fetching data for " .. steam_id)
            local fs_url = http_utils.flaresolverr_url()
            if fs_url == nil then
                p:finish(reg.encode({
                    status = "cloudflare_required",
                    message = "CSRep requires FlareSolverr. FlareSolverr not configured",
                    url = "https://csrep.gg/player/" .. steam_id,
                }))
                return nil
            end
            local req = http_utils.fs_req(fs_url, {
                cmd = "request.get",
                url = "https://csrep.gg/",
                maxTimeout = 15000,
                session = "csrep",
                userAgent = http_utils.chrome_user_agent(),
            }, 35)
            req.tag = "cookie"
            p.queue = { req }
        end
        if #p.queue == 0 then return nil end
        local q = p.queue
        p.queue = {}
        return q
    end

    -- NOTE: invoked colon-style (p:handle) — self is the pipeline table.
    function p.handle(self, req, resp)
        local tag = req.tag
        if tag == "cookie" then
            local solution, err = http_utils.fs_solution(resp)
            local cookie = http_utils.fs_cf_cookie(solution)
            if cookie == nil then
                logger:warn("CSRep: failed to get cookie: " .. tostring(err))
                p:finish(reg.encode({
                    status = "cloudflare_required",
                    message = "CSRep requires FlareSolverr. " .. tostring(err),
                    url = "https://csrep.gg/player/" .. steam_id,
                }))
                return
            end
            logger:info("CSRep: obtained cf_clearance cookie")
            p.cookie = cookie
            p.phase = "main"
            local main_req = http_utils.csrep_signed_req(api_url(""), cookie, 10)
            main_req.tag = "main"
            p.queue[#p.queue + 1] = main_req
        elseif tag == "main" then
            handle_main_body(resp.body, false)
        elseif tag == "fs_main" then
            local solution, err = http_utils.fs_solution(resp)
            if solution == nil then
                p:finish(reg.encode({ status = "error", message = "CSRep: FlareSolverr failed: " .. tostring(err) }))
                return
            end
            handle_main_body(solution.response or "", true)
        elseif p.endpoint_tags ~= nil and p.endpoint_tags[tag] ~= nil then
            local from_fs = req.fs == true
            local result, err, state = http_utils.csrep_decode_body(resp.body)
            if state == "ok" then
                p.endpoints[tag] = as_table(result)
            elseif not from_fs and http_utils.flaresolverr_url() ~= nil then
                -- Direct attempt failed → FS fallback for this endpoint.
                -- pending stays unchanged: the endpoint is still unresolved.
                push_fs_endpoint(p.endpoint_tags[tag], tag)
                return
            else
                logger:warn("CSRep: " .. tag .. " endpoint failed: " .. tostring(err))
                p.endpoints[tag] = nil
            end
            p.pending = p.pending - 1
            if p.pending <= 0 then
                p:finish(build_player_json(steam_id, p.main,
                    p.endpoints.performance, p.endpoints.ranks, p.endpoints.mini,
                    p.endpoints.crosshairs, p.endpoints.matches, p.endpoints.trend))
            end
        end
    end

    return p
end

reg.register({
    name = "csrep",
    display_name = "CSRep.GG",
    config_key = "csrep_enabled",
    fetch = csrep.fetch,
    pipeline = csrep.pipeline,
})

return csrep
