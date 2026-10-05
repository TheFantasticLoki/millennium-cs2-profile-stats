---FACEIT provider module.
---Fetches FACEIT player stats via faceit-finder.com and FACEIT stats API.

local cjson = require("json")
local logger = require("logger")
local http_utils = require("providers.http")
local reg = require("providers/init")

local faceit = {}

local function faceit_lifetime_map(payload)
    if type(payload) ~= "table" then return {} end

    local lifetime = payload.lifetime or payload.lifetime_stats
    if type(lifetime) ~= "table" and type(payload.payload) == "table" then
        lifetime = payload.payload.lifetime or payload.payload.lifetime_stats
    end
    if type(lifetime) ~= "table" then return {} end

    local result = {}
    for key, value in pairs(lifetime) do
        if type(key) == "string" then
            result[key] = value
        elseif type(value) == "table" and type(value.key) == "string" then
            result[value.key] = reg.optional(value.value)
        end
    end
    return result
end

local function first_lifetime_value(lifetime, keys)
    for _, key in ipairs(keys) do
        local value = reg.optional(lifetime[key])
        if value ~= nil and tostring(value) ~= "" then
            return value
        end
    end
    return nil
end

---Fill lifetime stats from the faceit-finder HTML "Key numbers" hero block.
---Shared by the legacy fetch path and the parallel pipeline.
local function fill_lifetime_from_html(lifetime, body, pre_matches, pre_kd)
    local hero = body:match("Kluczowe liczby.-ELO Rating") or body:match("Key numbers.-ELO Rating") or body
    lifetime.matches = pre_matches or hero:match(">Matches</p>%s*<p[^>]*>([^<]+)</p>")
    lifetime.winrate = reg.optional(lifetime.winrate) or first_lifetime_value(lifetime, { "Win Rate %", "Winrate", "winrate", "k6" }) or hero:match(">Win Rate</p>%s*<p[^>]*>([^<]+)</p>")
    lifetime.kd = pre_kd or hero:match(">K/D</p>%s*<p[^>]*>([^<]+)</p>")
    lifetime.adr = reg.optional(lifetime.adr) or first_lifetime_value(lifetime, { "ADR", "Average Damage Per Round", "adr", "k17" }) or hero:match(">ADR</p>%s*<p[^>]*>([^<]+)</p>")
    lifetime.headshots = reg.optional(lifetime.headshots) or first_lifetime_value(lifetime, { "Average Headshots %", "Headshots %", "HS %%", "headshots", "k8" }) or hero:match(">HS %%</p>%s*<p[^>]*>([^<]+)</p>")
end

---Encode the final FACEIT response. Shared by both fetch paths.
local function encode_faceit_result(player, cs2, lifetime, stats_status, stats_error, html_status, html_error)
    local lifetime_matches = reg.optional(lifetime.matches) or first_lifetime_value(lifetime, { "Matches", "matches", "m35" })
    local lifetime_kd = reg.optional(lifetime.kd) or first_lifetime_value(lifetime, { "Average K/D Ratio", "K/D Ratio", "K/D", "kd", "k5" })

    local partial_message = nil
    if lifetime_matches == nil and lifetime_kd == nil then
        partial_message = "FACEIT profile loaded, but lifetime statistics are unavailable."
        logger:info("Optional FACEIT lifetime stats unavailable (API " .. tostring(stats_status) .. ", HTML " .. tostring(html_status) .. "): " .. tostring(stats_error or html_error))
    end

    return reg.encode({
        status = "ok",
        message = partial_message,
        data = {
            nickname = reg.optional(player.nickname),
            country = reg.optional(player.country),
            player_id = reg.optional(player.player_id),
            level = reg.optional(cs2.skill_level),
            elo = reg.optional(cs2.faceit_elo),
            region = reg.optional(cs2.region),
            stats = {
                matches = lifetime_matches,
                kd = lifetime_kd,
                adr = reg.optional(lifetime.adr) or first_lifetime_value(lifetime, { "ADR", "Average Damage Per Round", "adr", "k17" }),
                headshots = reg.optional(lifetime.headshots) or first_lifetime_value(lifetime, { "Average Headshots %", "Headshots %", "HS %%", "headshots", "k8" }),
                winrate = reg.optional(lifetime.winrate) or first_lifetime_value(lifetime, { "Win Rate %", "Winrate", "winrate", "k6" }),
                recent_results = type(lifetime.s0) == "table" and lifetime.s0 or {},
            },
        },
        fetched_at = os.time(),
    })
end

function faceit.fetch(steam_id)
    if not reg.valid_steam_id(steam_id) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    local headers = {
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/json",
    }
    local lookup_body = cjson.encode({
        steamUrl = "https://steamcommunity.com/profiles/" .. steam_id,
    })
    logger:info("FACEIT: looking up player via faceit-finder.com for " .. steam_id)
    local player, player_status, player_error = http_utils.post_json("https://faceit-finder.com/api/search/steam", lookup_body, headers)
    if player == nil then
        return reg.provider_error("FACEIT lookup", player_status, player_error)
    end

    local cs2 = type(player.games) == "table" and player.games.cs2 or nil
    if type(cs2) ~= "table" or reg.is_null(player.player_id) then
        return reg.encode({
            status = "not_found",
            message = "FACEIT lookup returned no CS2 account (HTTP " .. tostring(player_status) .. ").",
        })
    end

    local lifetime = {}
    local stats_api_url = "https://api.faceit.com/stats/v1/stats/users/" .. tostring(player.player_id) .. "/games/cs2"
    logger:info("FACEIT: fetching lifetime stats from " .. stats_api_url)
    local stats_payload, stats_status, stats_error = http_utils.get_json(stats_api_url, {
        ["Accept"] = "application/json",
        ["Origin"] = "https://www.faceit.com",
        ["Referer"] = "https://www.faceit.com/",
    })

    if stats_payload ~= nil then
        lifetime = faceit_lifetime_map(stats_payload)
    end

    local stats_response = nil
    local html_error = nil
    local partial_message = nil
    local lifetime_matches = reg.optional(lifetime.matches) or first_lifetime_value(lifetime, { "Matches", "matches", "m35" })
    local lifetime_kd = reg.optional(lifetime.kd) or first_lifetime_value(lifetime, { "Average K/D Ratio", "K/D Ratio", "K/D", "kd", "k5" })

    if lifetime_matches == nil or lifetime_kd == nil then
        local stats_url = "https://faceit-finder.com/id/" .. steam_id .. "?lang=en"
        logger:info("FACEIT: fetching HTML stats page " .. stats_url)
        stats_response, html_error = http_utils.get_raw(stats_url, { ["Accept"] = "text/html" }, 12)

        if stats_response ~= nil and stats_response.status == 200 then
            local hero = stats_response.body:match("Kluczowe liczby.-ELO Rating") or stats_response.body:match("Key numbers.-ELO Rating") or stats_response.body
            lifetime.matches = lifetime_matches or hero:match(">Matches</p>%s*<p[^>]*>([^<]+)</p>")
            lifetime.winrate = reg.optional(lifetime.winrate) or first_lifetime_value(lifetime, { "Win Rate %", "Winrate", "winrate", "k6" }) or hero:match(">Win Rate</p>%s*<p[^>]*>([^<]+)</p>")
            lifetime.kd = lifetime_kd or hero:match(">K/D</p>%s*<p[^>]*>([^<]+)</p>")
            lifetime.adr = reg.optional(lifetime.adr) or first_lifetime_value(lifetime, { "ADR", "Average Damage Per Round", "adr", "k17" }) or hero:match(">ADR</p>%s*<p[^>]*>([^<]+)</p>")
            lifetime.headshots = reg.optional(lifetime.headshots) or first_lifetime_value(lifetime, { "Average Headshots %", "Headshots %", "HS %", "headshots", "k8" }) or hero:match(">HS %%</p>%s*<p[^>]*>([^<]+)</p>")
        end
    end

    lifetime_matches = reg.optional(lifetime.matches) or first_lifetime_value(lifetime, { "Matches", "matches", "m35" })
    lifetime_kd = reg.optional(lifetime.kd) or first_lifetime_value(lifetime, { "Average K/D Ratio", "K/D Ratio", "K/D", "kd", "k5" })

    if lifetime_matches == nil and lifetime_kd == nil then
        partial_message = "FACEIT profile loaded, but lifetime statistics are unavailable."
        local html_status = stats_response and stats_response.status or 0
        logger:info("Optional FACEIT lifetime stats unavailable (API " .. tostring(stats_status) .. ", HTML " .. tostring(html_status) .. "): " .. tostring(stats_error or html_error))
    end

    return reg.encode({
        status = "ok",
        message = partial_message,
        data = {
            nickname = reg.optional(player.nickname),
            country = reg.optional(player.country),
            player_id = reg.optional(player.player_id),
            level = reg.optional(cs2.skill_level),
            elo = reg.optional(cs2.faceit_elo),
            region = reg.optional(cs2.region),
            stats = {
                matches = lifetime_matches,
                kd = lifetime_kd,
                adr = reg.optional(lifetime.adr) or first_lifetime_value(lifetime, { "ADR", "Average Damage Per Round", "adr", "k17" }),
                headshots = reg.optional(lifetime.headshots) or first_lifetime_value(lifetime, { "Average Headshots %", "Headshots %", "HS %", "headshots", "k8" }),
                winrate = reg.optional(lifetime.winrate) or first_lifetime_value(lifetime, { "Win Rate %", "Winrate", "winrate", "k6" }),
                recent_results = type(lifetime.s0) == "table" and lifetime.s0 or {},
            },
        },
        fetched_at = os.time(),
    })
end

---Parallel pipeline: lookup → lifetime stats → optional HTML fallback,
---driven by the coordinator's curl_multi pump.
function faceit.pipeline(steam_id)
    local p = { phase = "lookup", queue = {}, finished = false, lifetime = {} }

    local headers = {
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/json",
    }
    local lookup_body = cjson.encode({
        steamUrl = "https://steamcommunity.com/profiles/" .. steam_id,
    })

    function p.next()
        if p.phase == "lookup" then
            logger:info("FACEIT: looking up player via faceit-finder.com for " .. steam_id)
            local q = { http_utils.post_req("https://faceit-finder.com/api/search/steam", lookup_body, headers, 10) }
            p.queue = {}
            return q
        elseif p.phase == "stats" then
            local q = { http_utils.get_req(p.stats_api_url, {
                ["Accept"] = "application/json",
                ["Origin"] = "https://www.faceit.com",
                ["Referer"] = "https://www.faceit.com/",
            }, 10) }
            p.queue = {}
            return q
        elseif p.phase == "html" then
            local q = { http_utils.get_req(p.stats_url, { ["Accept"] = "text/html" }, 12) }
            p.queue = {}
            return q
        end
        return nil
    end

    -- NOTE: invoked colon-style (p:handle) — self is the pipeline table.
    function p.handle(self, req, resp)
        if p.phase == "lookup" then
            local player, status, err = http_utils.resp_json(resp)
            if player == nil then
                p:finish(reg.provider_error("FACEIT lookup", status, err))
                return
            end
            local cs2 = type(player.games) == "table" and player.games.cs2 or nil
            if type(cs2) ~= "table" or reg.is_null(player.player_id) then
                p:finish(reg.encode({
                    status = "not_found",
                    message = "FACEIT lookup returned no CS2 account (HTTP " .. tostring(status) .. ").",
                }))
                return
            end
            p.player = player
            p.cs2 = cs2
            p.stats_api_url = "https://api.faceit.com/stats/v1/stats/users/" .. tostring(player.player_id) .. "/games/cs2"
            p.stats_url = "https://faceit-finder.com/id/" .. steam_id .. "?lang=en"
            p.phase = "stats"
        elseif p.phase == "stats" then
            local stats_payload, status, err = http_utils.resp_json(resp)
            p.stats_status = status
            p.stats_error = err
            if stats_payload ~= nil then
                p.lifetime = faceit_lifetime_map(stats_payload)
            end
            local lifetime_matches = reg.optional(p.lifetime.matches) or first_lifetime_value(p.lifetime, { "Matches", "matches", "m35" })
            local lifetime_kd = reg.optional(p.lifetime.kd) or first_lifetime_value(p.lifetime, { "Average K/D Ratio", "K/D Ratio", "K/D", "kd", "k5" })
            if lifetime_matches == nil or lifetime_kd == nil then
                p.phase = "html"
                return
            end
            p:finish(encode_faceit_result(p.player, p.cs2, p.lifetime, p.stats_status, p.stats_error, 0, nil))
        elseif p.phase == "html" then
            if resp.status == 200 and type(resp.body) == "string" then
                local lifetime_matches = reg.optional(p.lifetime.matches) or first_lifetime_value(p.lifetime, { "Matches", "matches", "m35" })
                local lifetime_kd = reg.optional(p.lifetime.kd) or first_lifetime_value(p.lifetime, { "Average K/D Ratio", "K/D Ratio", "K/D", "kd", "k5" })
                fill_lifetime_from_html(p.lifetime, resp.body, lifetime_matches, lifetime_kd)
            end
            p:finish(encode_faceit_result(p.player, p.cs2, p.lifetime, p.stats_status, p.stats_error,
                resp.status or 0, resp.error))
        end
    end

    return p
end

reg.register({
    name = "faceit",
    display_name = "FACEIT",
    config_key = "faceit_api_key",
    fetch = faceit.fetch,
    pipeline = faceit.pipeline,
})

return faceit
