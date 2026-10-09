---CSStats.GG provider module.
---Established stats tracker that collects match data independently. Has been
---around long enough that even unregistered players have data from other users'
---games. Good for match history and general statistics.
---
---Note: CSStats returns 403 without proper browser headers. FlareSolverr may
---be needed to bypass Cloudflare protection.
---
---HTML structure (after FlareSolverr):
---  - K/D: <div id="kpd" class="stat-large stat"><span>1.39</span></div>
---  - HLTV Rating: <div id="rating" class="stat-large stat"><span>1.33</span></div>
---  - Win Rate: <div class="stat">Played 342</div> <div class="stat">Won 196</div>
---  - Kills/Deaths/Assists: <div class="stat">Kills 5767</div>
---  - ADR/KAST: <div class="stat">KAST 73%</div>

local cjson = require("json")
local logger = require("logger")
local http_utils = require("providers.http")
local reg = require("providers/init")

local csstats = {}

---Browser headers for direct requests. CSStats sits behind Cloudflare and
---rejects non-browser clients; `br` is omitted because the HTTP layer may not
---decompress brotli.
local BROWSER_HEADERS = {
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["Accept-Encoding"] = "gzip, deflate",
    ["Cache-Control"] = "max-age=0",
    ["Connection"] = "keep-alive",
    ["Sec-Ch-Ua"] = '"Chromium";v="131", "Google Chrome";v="131", "Not-A.Brand";v="99"',
    ["Sec-Ch-Ua-Mobile"] = "?0",
    ["Sec-Ch-Ua-Platform"] = '"Windows"',
    ["Sec-Fetch-Dest"] = "document",
    ["Sec-Fetch-Mode"] = "navigate",
    ["Sec-Fetch-Site"] = "none",
    ["Sec-Fetch-User"] = "?1",
    ["Upgrade-Insecure-Requests"] = "1",
}

---How many recent matches to forward to the aggregator. MATCH_DATA carries the
---entire history; the merger only needs a window that overlaps the other
---providers, and 50 keeps the IPC payload reasonable.
local RECENT_MATCH_LIMIT = 50

---Extract a balanced JSON object literal that follows `marker` in `html`.
---Walks the brace depth while respecting string literals so nested objects
---and escaped quotes cannot truncate the scan.
---@param html string
---@param marker string Plain-text marker preceding the object
---@return string|nil json_text
local function extract_json_object(html, marker)
    local start = html:find(marker, 1, true)
    if start == nil then return nil end

    local i = start + #marker
    local length = #html
    while i <= length and html:sub(i, i):match("%s") do
        i = i + 1
    end
    if html:sub(i, i) ~= "{" then return nil end

    local depth = 0
    local in_string = false
    local escaped = false
    for j = i, length do
        local char = html:sub(j, j)
        if in_string then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == '"' then
                in_string = false
            end
        else
            if char == '"' then
                in_string = true
            elseif char == "{" then
                depth = depth + 1
            elseif char == "}" then
                depth = depth - 1
                if depth == 0 then
                    return html:sub(i, j)
                end
            end
        end
    end
    return nil
end

---Safely decode a JSON object extracted from the fragment.
---@param html string
---@param marker string
---@return table|nil data
local function decode_json_after(html, marker)
    local text = extract_json_object(html, marker)
    if text == nil then return nil end
    local ok, decoded = pcall(cjson.decode, text)
    if not ok or type(decoded) ~= "table" then return nil end
    return decoded
end

---Number accessor that tolerates cjson nulls, strings, and missing keys.
---@param value any
---@return number|nil
local function num(value)
    return reg.number_or_nil(value)
end

---Round to one decimal place.
---@param value number|nil
---@return number|nil
local function round1(value)
    if value == nil then return nil end
    return math.floor(value * 10 + 0.5) / 10
end

---Round to two decimal places.
---@param value number|nil
---@return number|nil
local function round2(value)
    if value == nil then return nil end
    return math.floor(value * 100 + 0.5) / 100
end

---Percentage of `part` over `total`, rounded to `digits` decimals.
---@param part number|nil
---@param total number|nil
---@param digits number|nil
---@return number|nil
local function percent(part, total, digits)
    if part == nil or total == nil or total <= 0 then return nil end
    local value = (part / total) * 100
    if digits == 1 then return round1(value) end
    if digits == 2 then return round2(value) end
    return math.floor(value + 0.5)
end

---Normalize a MATCH_DATA row into the unified recent-match shape used by the
---aggregator and match merger. Scores stay as {player, opponent} pairs —
---normalize_csstats_match converts them for the merger.
---@param row table
---@return table|nil match
local function normalize_match_row(row)
    if type(row) ~= "table" then return nil end
    local result = tostring(row.result or "")
    local outcome
    if result == "w" then
        outcome = "win"
    elseif result == "l" then
        outcome = "loss"
    else
        outcome = "tie"
    end

    local score = row.score
    if type(score) ~= "table" or #score < 2 then return nil end

    local kills, deaths = num(row.k), num(row.d)
    local kd = nil
    if kills ~= nil and deaths ~= nil and deaths > 0 then
        kd = round2(kills / deaths)
    end

    return {
        outcome     = outcome,
        map_name    = row.map,
        score       = { num(score[1]), num(score[2]) },
        finished_at = num(row.date), -- unix seconds; merger windows on this
        kills       = kills,
        deaths      = deaths,
        assists     = num(row.a),
        kd          = kd,
        adr         = num(row.adr),
        rating      = num(row.rating),
        hs          = num(row.hs),
        data_source = "csstats",
    }
end

---Normalize the per-weapon table into a sorted array with derived accuracy
---and headshot percentages.
---@param weapons table<string, table>|nil
---@return table[]
local function normalize_weapons(weapons)
    local result = {}
    if type(weapons) ~= "table" then return result end
    for name, w in pairs(weapons) do
        if type(w) == "table" then
            local kills = num(w.kills) or 0
            local shots = num(w.shots) or 0
            local hits = num(w.hits) or 0
            local headshots = num(w.headshot) or 0
            result[#result + 1] = {
                name      = name,
                kills     = kills,
                headshots = headshots,
                hs_pct    = percent(headshots, kills, 1),
                shots     = shots,
                hits      = hits,
                accuracy  = percent(hits, shots, 1),
                damage    = num(w.dmg),
                hitgroups = type(w.hitgroups) == "table" and w.hitgroups or nil,
            }
        end
    end
    table.sort(result, function(a, b) return (a.kills or 0) > (b.kills or 0) end)
    return result
end

---Normalize the per-map table into a sorted array. CSStats stores `adr` and
---`rating` per map as SUMS over played matches, so averages divide by played.
---@param maps table<string, table>|nil
---@return table[]
local function normalize_maps(maps)
    local result = {}
    if type(maps) ~= "table" then return result end
    for name, m in pairs(maps) do
        if type(m) == "table" then
            local played = num(m.played) or 0
            local rounds = num(m.rounds) or 0
            local kills, deaths = num(m.K), num(m.D)
            local won = num(m.won) or 0
            result[#result + 1] = {
                map            = name,
                played         = played,
                won            = won,
                winrate        = percent(won, played, 1),
                kills          = kills,
                deaths         = deaths,
                kd             = (kills ~= nil and deaths ~= nil and deaths > 0) and round2(kills / deaths) or nil,
                avg_adr        = played > 0 and round1((num(m.adr) or 0) / played) or nil,
                avg_rating     = played > 0 and round2((num(m.rating) or 0) / played) or nil,
                kast           = percent(num(m.kast_rounds), rounds, 1),
                rounds         = rounds,
                rounds_for     = num(m.rounds_for),
                rounds_against = num(m.rounds_against),
            }
        end
    end
    table.sort(result, function(a, b) return (a.played or 0) > (b.played or 0) end)
    return result
end

---Build the unified clutch array (1v1..1v5) from totals. CSStats reports wins
---and losses per situation, so winrates are computed rather than taken from
---rounded site values — identical output, consistent with other providers.
---@param totals table
---@return table[] clutch
local function build_clutch(totals)
    local clutch = {}
    for i = 1, 5 do
        local wins = num(totals["1v" .. i])
        local losses = num(totals["1v" .. i .. "_lost"])
        if wins ~= nil and losses ~= nil and (wins + losses) > 0 then
            clutch[#clutch + 1] = {
                label   = "1v" .. i,
                wins    = wins,
                losses  = losses,
                winrate = percent(wins, wins + losses, 1),
            }
        end
    end
    return clutch
end

---Build the entry-success block. CSStats tracks first kills (FK) and first
---deaths (FD) overall and per side; the `_SPR` variants are the counters the
---site itself uses for the displayed Entry Success percentages.
---@param totals table
---@return table|nil entry
local function build_entry(totals)
    local fk = num(totals.FK)
    local fd = num(totals.FD)
    if fk == nil and fd == nil then return nil end

    local rounds = num(totals.rounds)
    local t_rounds = num(totals.t_rounds)
    local ct_rounds = num(totals.ct_rounds)
    local fk_t, fd_t = num(totals.FK_T_SPR), num(totals.FD_T_SPR)
    local fk_ct, fd_ct = num(totals.FK_CT_SPR), num(totals.FD_CT_SPR)

    local attempts = nil
    if fk ~= nil and fd ~= nil then attempts = fk + fd end

    local t_attempts = nil
    if fk_t ~= nil and fd_t ~= nil then t_attempts = fk_t + fd_t end
    local ct_attempts = nil
    if fk_ct ~= nil and fd_ct ~= nil then ct_attempts = fk_ct + fd_ct end

    return {
        -- Combined (T+CT)
        success_pct            = percent(fk, attempts, 1),
        attempts_per_round_pct = percent(attempts, rounds, 1),
        success_per_round_pct  = percent(fk, rounds, 1),
        first_kills            = fk,
        first_deaths           = fd,
        -- Per side
        t = {
            success_pct            = percent(fk_t, t_attempts, 1),
            attempts_per_round_pct = percent(t_attempts, t_rounds, 1),
            first_kills            = fk_t,
            first_deaths           = fd_t,
        },
        ct = {
            success_pct            = percent(fk_ct, ct_attempts, 1),
            attempts_per_round_pct = percent(ct_attempts, ct_rounds, 1),
            first_kills            = fk_ct,
            first_deaths           = fd_ct,
        },
    }
end

---Latest Premier rating from MATCH_DATA. Rows tagged `t="premier"` carry the
---rating after that match in `rank.new`; the newest row is the current rating.
---@param rows table[]|nil
---@return number|nil premier
local function extract_premier(rows)
    if type(rows) ~= "table" then return nil end
    local latest_date, latest_rating = nil, nil
    for _, row in ipairs(rows) do
        local rank = type(row) == "table" and row.rank or nil
        if type(rank) == "table" and rank.t == "premier" then
            local date = num(row.date) or 0
            local rating = num(rank.new)
            if rating ~= nil and (latest_date == nil or date >= latest_date) then
                latest_date, latest_rating = date, rating
            end
        end
    end
    return latest_rating
end

---Build multi-kill round totals from MATCH_DATA. `m3`/`m4`/`m5` count rounds
---with 3/4/5 kills across the whole tracked history.
---@param rows table[]|nil
---@return table|nil multi_kills
local function extract_multi_kills(rows)
    if type(rows) ~= "table" or #rows == 0 then return nil end
    local triple, quad, penta = 0, 0, 0
    for _, row in ipairs(rows) do
        if type(row) == "table" then
            triple = triple + (num(row.m3) or 0)
            quad = quad + (num(row.m4) or 0)
            penta = penta + (num(row.m5) or 0)
        end
    end
    if triple == 0 and quad == 0 and penta == 0 then return nil end
    return { triple = triple, quad = quad, penta = penta }
end

---Extract the player name from the played-with disclaimer embedded in the
---stats fragment ("Stats shown for NAME are based solely on ...").
---@param html string
---@return string|nil name
local function extract_name(html)
    local name = html:match('Stats shown for (.-) are based solely on')
    if name ~= nil then
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then return name end
    end
    return nil
end

---Parse the /stats HTML fragment into the provider data table.
---Exposed for testing — the fetch path is a thin wrapper around this.
---@param html string Raw fragment body (FlareSolverr-wrapped is fine)
---@param steam_id string
---@return table|nil data, string|nil error_message
function csstats.parse_fragment(html, steam_id)
    local stats = decode_json_after(html, "var stats = ")
    if stats == nil then
        return nil, "CSStats returned no stats payload (page may be rate-limited)."
    end

    local totals = {}
    if type(stats.totals) == "table" and type(stats.totals.overall) == "table" then
        totals = stats.totals.overall
    end
    local overall = type(stats.overall) == "table" and stats.overall or {}

    local match_data = decode_json_after(html, "window.MATCH_DATA = ")
    local rows = nil
    if type(match_data) == "table" and type(match_data.rows) == "table" then
        rows = match_data.rows
    end

    -- ── Core rates ────────────────────────────────────────────────
    local kills = num(totals.K)
    local deaths = num(totals.D)
    local assists = num(totals.A)
    local headshots = num(totals.HS)
    local damage = num(totals.dmg)
    local rounds = num(totals.rounds)
    local games = num(totals.games)
    local wins = num(totals.wins)
    local losses = num(totals.losses)
    local ties = num(totals.draws)

    local kd = num(overall.kpd)
    if kd == nil and kills ~= nil and deaths ~= nil and deaths > 0 then
        kd = round2(kills / deaths)
    end

    -- ADR: the site's stats JSON reports the mean of per-match ADRs, but the
    -- value displayed on the page (and the value every other provider reports)
    -- is damage / rounds. Prefer the displayed definition.
    local adr = nil
    if damage ~= nil and rounds ~= nil and rounds > 0 then
        adr = round1(damage / rounds)
    end
    adr = adr or num(overall.adr)

    local hs = num(overall.hs)
    if hs == nil then hs = percent(headshots, kills, 1) end

    local winrate = percent(wins, games, 1) or num(overall.wr)

    local kast_rounds = num(totals.KAST_rounds)
    local kast = percent(kast_rounds, rounds, 1)

    -- ── Clutch & entry ────────────────────────────────────────────
    local clutch = build_clutch(totals)
    local clutch_1vX = num(overall["1vX"])
    local entry = build_entry(totals)

    -- ── Match history ─────────────────────────────────────────────
    local recent_matches = {}
    if rows ~= nil then
        for _, row in ipairs(rows) do
            if #recent_matches >= RECENT_MATCH_LIMIT then break end
            local match = normalize_match_row(row)
            if match ~= nil then recent_matches[#recent_matches + 1] = match end
        end
    end
    if #recent_matches == 0 and type(stats.past10) == "table" then
        -- Fallback when MATCH_DATA is unavailable: past10 lacks K/D/A and
        -- timestamps but still feeds the recent-form display.
        for _, m in ipairs(stats.past10) do
            if #recent_matches >= RECENT_MATCH_LIMIT then break end
            if type(m) == "table" then
                local result = tostring(m.result or "")
                local s1, s2 = tostring(m.score or ""):match("(%d+)%s*:%s*(%d+)")
                recent_matches[#recent_matches + 1] = {
                    outcome     = result == "win" and "win" or result == "lose" and "loss" or "tie",
                    map_name    = m.map,
                    score       = s1 and { tonumber(s1), tonumber(s2) } or nil,
                    adr         = num(m.adr),
                    rating      = num(m.rating),
                    hs          = num(m.hs),
                    kd          = num(m.kpd),
                    data_source = "csstats",
                }
            end
        end
    end

    local multi_kills = extract_multi_kills(rows)
    local premier = extract_premier(rows)
    local last_match_at = nil
    if rows ~= nil and type(rows[1]) == "table" then
        last_match_at = num(rows[1].date)
    end

    -- ── Extras ────────────────────────────────────────────────────
    local weapons = nil
    if type(stats.weapons) == "table" and type(stats.weapons.overall) == "table" then
        weapons = normalize_weapons(stats.weapons.overall)
    end
    local maps = nil
    if type(stats.maps) == "table" and type(stats.maps.overall) == "table" then
        maps = normalize_maps(stats.maps.overall)
    end

    local data = {
        name          = extract_name(html),
        steam64_id    = steam_id,
        profile_url   = "https://csstats.gg/player/" .. steam_id,

        -- Core stats (aggregator consumes these)
        kd            = kd,
        winrate       = winrate,
        adr           = adr,
        hs            = hs,
        hltv_rating   = num(overall.rating),
        kast          = kast,
        kills         = kills,
        deaths        = deaths,
        assists       = assists,
        headshots     = headshots,
        total_matches = games,
        wins          = wins,
        losses        = losses,
        ties          = ties,
        damage        = damage,
        rounds        = rounds,

        -- Clutch (unified format — aggregator merges with CSTracker/CSRep)
        clutch        = clutch,
        clutch_1vX    = clutch_1vX,
        -- Legacy flat fields kept for older cached UI paths
        clutch_1v1    = clutch[1] and clutch[1].winrate or nil,
        clutch_1v2    = clutch[2] and clutch[2].winrate or nil,
        clutch_1v3    = clutch[3] and clutch[3].winrate or nil,

        -- Entry success (opening duels)
        entry         = entry,
        first_kills   = entry and entry.first_kills or nil,

        -- Ranks / extras
        premier       = premier,
        multi_kills   = multi_kills,
        last_match_at = last_match_at,

        recent_matches = recent_matches,
        extras        = {
            ct_rounds    = num(totals.ct_rounds),
            t_rounds     = num(totals.t_rounds),
            kast_rounds  = kast_rounds,
            comp_wins    = num(stats.comp_wins),
            adr_reported = num(overall.adr), -- site JSON mean-of-match-ADRs
            best         = type(stats.best) == "table" and stats.best or nil,
            past10       = type(stats.past10) == "table" and stats.past10 or nil,
            weapons      = weapons,
            maps         = maps,
        },
    }

    return data, nil
end

function csstats.fetch(steam_id)
    if not reg.valid_steam_id(steam_id) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    -- The profile page itself is an SPA shell without stats; the stats live
    -- behind the /stats XHR endpoint, which we fetch directly.
    local stats_url = "https://csstats.gg/player/" .. steam_id .. "/stats"
    logger:info("CSStats: fetching " .. stats_url)
    local response, request_error, fs_used = http_utils.get_raw(stats_url, BROWSER_HEADERS, 45)

    if response == nil then
        if http_utils.is_cloudflare_error(request_error) then
            logger:warn("CSStats: Cloudflare challenge and no FlareSolverr — failing fast")
            return reg.encode({
                status = "cloudflare_required",
                message = "Visit csstats.gg to complete verification, then retry.",
                url = "https://csstats.gg/player/" .. steam_id,
            })
        end
        logger:warn("CSStats: HTTP request failed: " .. tostring(request_error))
        return reg.provider_error("CSStats", 0, request_error or "Network request failed.")
    end
    logger:info("CSStats: HTTP " .. tostring(response.status) .. ", body length " .. tostring(#(response.body or "")))

    local body = response.body or ""

    -- Check for Cloudflare challenge (skip if FlareSolverr already handled it)
    if not fs_used and http_utils.is_cloudflare_challenge(response) then
        logger:warn("CSStats: Cloudflare challenge detected (HTTP " .. tostring(response.status) .. ")")
        return reg.encode({
            status = "cloudflare_required",
            message = "Visit csstats.gg to complete verification, then retry.",
            url = "https://csstats.gg/player/" .. steam_id,
        })
    end

    if response.status == 404 then
        return reg.encode({ status = "not_found", message = "CSStats has no profile for this Steam account." })
    end

    if response.status == 429 then
        local retry_after = response.headers and (response.headers["Retry-After"] or response.headers["retry-after"])
        return reg.encode({
            status = "rate_limited",
            message = "CSStats is rate-limiting requests" .. (retry_after and (". Retry after " .. tostring(retry_after) .. "s.") or " — try again shortly."),
        })
    end

    if response.status < 200 or response.status >= 300 then
        if response.status == 403 then
            return reg.encode({
                status = "unauthorized",
                message = "CSStats requires login for this profile (403). It may be private.",
            })
        end
        return reg.provider_error("CSStats", response.status, "HTTP " .. tostring(response.status))
    end

    local data, parse_error = csstats.parse_fragment(body, steam_id)

    -- A 200 without the stats payload usually means the shell/skeleton was
    -- served instead of the fragment — retry once through FlareSolverr.
    if data == nil and not fs_used and http_utils.flaresolverr_url() ~= nil then
        logger:info("CSStats: no stats payload in response, retrying via FlareSolverr")
        local fs_response, fs_error = http_utils.flaresolverr_get(stats_url, 60)
        if fs_response ~= nil then
            data, parse_error = csstats.parse_fragment(fs_response.body or "", steam_id)
            logger:info("CSStats: FlareSolverr retry " .. (data and "succeeded" or "failed: " .. tostring(parse_error)))
        else
            logger:warn("CSStats: FlareSolverr failed: " .. tostring(fs_error))
        end
    end

    if data == nil then
        logger:warn("CSStats: parse failed: " .. tostring(parse_error))
        return reg.encode({
            status = "error",
            message = parse_error or "CSStats returned no stat data.",
        })
    end

    logger:info(string.format(
        "CSStats: kd=%s, hltv=%s, wr=%s, hs=%s, adr=%s, kast=%s, matches=%s, clutch=%d, entry=%s",
        tostring(data.kd), tostring(data.hltv_rating), tostring(data.winrate),
        tostring(data.hs), tostring(data.adr), tostring(data.kast),
        tostring(data.total_matches), #(data.clutch or {}),
        data.entry and tostring(data.entry.success_pct) or "nil"
    ))

    return reg.encode({
        status = "ok",
        data = data,
        fetched_at = os.time(),
    })
end

---Parallel pipeline: /stats fragment → parse → optional FlareSolverr retry.
---Status mapping mirrors csstats.fetch exactly.
function csstats.pipeline(steam_id)
    local p = { phase = "page", queue = {}, finished = false }
    local stats_url = "https://csstats.gg/player/" .. steam_id .. "/stats"
    local profile_url = "https://csstats.gg/player/" .. steam_id

    -- BROWSER_HEADERS minus Accept-Encoding: ffi_http sets
    -- CURLOPT_ACCEPT_ENCODING "" which sends every supported encoding AND
    -- decompresses transparently; a manual Accept-Encoding header would
    -- disable curl's auto-decompression and hand us gzip bytes.
    local PIPE_HEADERS = {}
    for k, v in pairs(BROWSER_HEADERS) do
        if k ~= "Accept-Encoding" then
            PIPE_HEADERS[k] = v
        end
    end

    local function finish_with_data(data)
        logger:info(string.format(
            "CSStats: kd=%s, hltv=%s, wr=%s, hs=%s, adr=%s, kast=%s, matches=%s, clutch=%d, entry=%s",
            tostring(data.kd), tostring(data.hltv_rating), tostring(data.winrate),
            tostring(data.hs), tostring(data.adr), tostring(data.kast),
            tostring(data.total_matches), #(data.clutch or {}),
            data.entry and tostring(data.entry.success_pct) or "nil"
        ))
        p:finish(reg.encode({ status = "ok", data = data, fetched_at = os.time() }))
    end

    local function handle_body(body, fs_used)
        local data, parse_error = csstats.parse_fragment(body, steam_id)
        if data ~= nil then
            if fs_used then
                logger:info("CSStats: FlareSolverr retry succeeded")
            end
            finish_with_data(data)
            return
        end
        if not fs_used and http_utils.flaresolverr_url() ~= nil then
            -- A 200 without the stats payload usually means the shell page
            -- was served instead of the fragment — retry via FlareSolverr.
            p.phase = "fs"
            return
        end
        if fs_used then
            logger:info("CSStats: FlareSolverr retry failed: " .. tostring(parse_error))
        end
        logger:warn("CSStats: parse failed: " .. tostring(parse_error))
        p:finish(reg.encode({
            status = "error",
            message = parse_error or "CSStats returned no stat data.",
        }))
    end

    function p.next()
        if p.phase == "page" then
            logger:info("CSStats: fetching " .. stats_url)
            local req = http_utils.get_req(stats_url, PIPE_HEADERS, 45)
            req.tag = "page"
            p.queue = { req }
        elseif p.phase == "fs" then
            logger:info("CSStats: retrying via FlareSolverr")
            -- Named session: reuse one FlareSolverr browser (and its
            -- cf_clearance cookie) across scrapes instead of spawning a
            -- fresh headless instance per request.
            local req = http_utils.fs_req(http_utils.flaresolverr_url(), {
                cmd = "request.get",
                url = stats_url,
                maxTimeout = 60000,
                session = "csstats",
                userAgent = http_utils.chrome_user_agent(),
            }, 60)
            req.tag = "fs"
            p.queue = { req }
        end
        if #p.queue == 0 then return nil end
        local q = p.queue
        p.queue = {}
        return q
    end

    -- NOTE: invoked colon-style (p:handle) — self is the pipeline table.
    function p.handle(self, req, resp)
        if req.tag == "page" then
            if resp.status == nil then
                logger:warn("CSStats: HTTP request failed: " .. tostring(resp.error))
                p:finish(reg.provider_error("CSStats", 0, resp.error or "Network request failed."))
                return
            end
            logger:info("CSStats: HTTP " .. tostring(resp.status) .. ", body length " .. tostring(#(resp.body or "")))

            if http_utils.is_cloudflare_challenge(resp) then
                if http_utils.flaresolverr_url() ~= nil then
                    p.phase = "fs"
                    return
                end
                logger:warn("CSStats: Cloudflare challenge and no FlareSolverr — failing fast")
                p:finish(reg.encode({
                    status = "cloudflare_required",
                    message = "Visit csstats.gg to complete verification, then retry.",
                    url = profile_url,
                }))
                return
            end

            if resp.status == 404 then
                p:finish(reg.encode({ status = "not_found", message = "CSStats has no profile for this Steam account." }))
                return
            end

            if resp.status == 429 then
                local retry_after = resp.headers and (resp.headers["Retry-After"] or resp.headers["retry-after"])
                p:finish(reg.encode({
                    status = "rate_limited",
                    message = "CSStats is rate-limiting requests" .. (retry_after and (". Retry after " .. tostring(retry_after) .. "s.") or " — try again shortly."),
                }))
                return
            end

            if resp.status < 200 or resp.status >= 300 then
                if resp.status == 403 then
                    p:finish(reg.encode({
                        status = "unauthorized",
                        message = "CSStats requires login for this profile (403). It may be private.",
                    }))
                    return
                end
                p:finish(reg.provider_error("CSStats", resp.status, "HTTP " .. tostring(resp.status)))
                return
            end

            handle_body(resp.body or "", false)
        elseif req.tag == "fs" then
            local solution, err = http_utils.fs_solution(resp)
            if solution == nil then
                logger:warn("CSStats: FlareSolverr failed: " .. tostring(err))
                p:finish(reg.encode({
                    status = "error",
                    message = "CSStats returned no stat data.",
                }))
                return
            end
            handle_body(solution.response or "", true)
        end
    end

    return p
end

reg.register({
    name = "csstats",
    display_name = "CSStats.GG",
    config_key = "csstats_enabled",
    fetch = csstats.fetch,
    pipeline = csstats.pipeline,
})

return csstats
