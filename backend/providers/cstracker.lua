---CSTracker.GG provider module.
---Highest priority new provider. Tracks matches independently, provides trust
---rating system with explanations, and detailed player statistics.
---
---Data source: HTML scraping of profile pages at cstracker.gg/players/{steamId}
---Page uses Tailwind CSS with structured sections:
---  - Stat analysis cards: // label in one div, value in next div
---  - Kill breakdown: donut charts with counts
---  - Detailed stats: key-value rows
---  - Match history: table rows
---  - Map performance: per-map stat cards
---  - Clutch performance: 1v1 through 1v5
---  - Teammates: table with per-teammate stats
---
---Parsing is split into two pure stages shared by the legacy fetch path and
---the parallel pipeline:
---  extract_pre(html)                 → main-page fields + hx-get URLs
---  build_cstracker_result(...)       → merge HTMX sections + final encode

local cjson = require("json")
local logger = require("logger")
local http_utils = require("providers.http")
local reg = require("providers/init")

local cstracker = {}

---Strip HTML tags and collapse whitespace to get plain text.
---@param html string
---@return string
local function strip_html(html)
    local text = html:gsub("<[^>]+>", " ")
    text = text:gsub("&amp;", "&")
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&#%d+;", "")
    text = text:gsub("%s+", " ")
    return text:match("^%s*(.-)%s*$") or ""
end

---Extract a numeric value from text using a pattern.
---@param text string
---@param pattern string Lua pattern with one capture group
---@return number|nil
local function extract_number(text, pattern)
    local match = text:match(pattern)
    if match == nil then return nil end
    local cleaned = (match:match("^%s*(.-)%s*$"):gsub(",", ""):gsub("%%", ""))
    return tonumber(cleaned)
end

---Extract text content from HTML.
---@param text string
---@param pattern string
---@return string|nil
local function extract_text(text, pattern)
    local match = text:match(pattern)
    if match == nil then return nil end
    return match:match("^%s*(.-)%s*$")
end

---Extract a stat value from a CSTracker stat card.
---Finds "// label" markers and grabs the next value element.
---Handles: ms, %, ° (UTF-8 \194\176), and plain numbers.
---Skips data-histogram-config JSON attributes to avoid false matches.
---@param html string
---@param label string The section label (case-insensitive)
---@return number|nil
local function extract_stat(html, label)
    local flat = html:gsub("\r?\n", " ")
    local lc_label = label:lower()
    local search_start = 1

    while search_start <= #flat do
        local label_pos = flat:find(lc_label, search_start, true)
        if label_pos == nil then return nil end

        local before = flat:sub(math.max(1, label_pos - 10), label_pos - 1)
        local is_label = before:match("//%s*$") ~= nil or before:match(">%s*$") ~= nil

        local config_check = flat:sub(math.max(1, label_pos - 300), label_pos)
        local in_config = config_check:match('data%-histogram%-config="[^"]*$') ~= nil

        if in_config then
            search_start = label_pos + #lc_label
        elseif is_label then
            local after_section = flat:sub(label_pos + #lc_label, label_pos + #lc_label + 600)

            -- Match value with optional unit suffix in an HTML element
            local value = after_section:match('>([%d%.]+)ms<')
                or after_section:match('>([%d%.]+)%%<')
                or after_section:match('>([%d%.]+)\194\176<')   -- ° (2-byte UTF-8)
                or after_section:match('>([%d%.]+)[^0-9<]*<')   -- any other unit

            if value ~= nil then
                local num = tonumber((value:gsub(",", "")))
                if num ~= nil and num > 0 then
                    return num
                end
            end
        end

        search_start = label_pos + #lc_label
    end

    return nil
end

---Extract a value from a detail stat row (key-value pair format).
---The HTML uses: <span>LABEL</span></span><span>VALUE</span>
---Value may contain commas (e.g. "138,183") and may have unit suffixes.
---@param html string
---@param label string The label text (e.g. "K/D/A", "Enemy damage")
---@return string|nil value The raw value text, nil if not found
local function extract_detail_value(html, label)
    local flat = html:gsub("\r?\n", " ")
    local escaped_label = label:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    -- Primary: label span, closing span, then value span
    local pattern = escaped_label .. '</span>%s*</span>%s*<span[^>]*>([^<]+)</span>'
    local v1 = flat:match(pattern)
    if v1 then return v1 end
    -- Fallback: find label and grab the next span content after it
    local pos = flat:find(escaped_label .. '</span>', 1, true)
    if pos then
        local after = flat:sub(pos, pos + 300)
        local v2 = after:match('>([%d,][^<]*)</span>')
        return v2 and v2:match("^%s*(.-)%s*$")
    end
    return nil
end

---Stage 1 parsing: everything extractable from the main profile page alone.
---Returns a `pre` table of fields plus the HTMX hx-get URLs discovered in
---the page. Pure function of `html`.
---@param html string
---@return table pre, string[] hx_urls
local function extract_pre(html)
    -- Flatten HTML for cross-line pattern matching
    local flat = html:gsub("\r?\n", " ")
    local pre = { flat = flat, html = html }

    pre.player_name = extract_text(html, '<h1[^>]*>(.-)</h1>')
        or extract_text(html, '<title>(.-)</title>')

    -- ── Trust rating ──
    local trust_rating = nil
    local trust_section = flat:match('player%-trust%-rating%-card(.-)$') or ""
    pre.trust_section = trust_section
    if trust_section ~= "" then
        trust_rating = extract_number(trust_section, 'tabular%-nums text%-emerald%-300">([%d%.]+)<')
    end
    if trust_rating == nil then
        trust_rating = extract_number(flat, '// trust rating.-tabular%-nums text%-emerald%-300">([%d%.]+)<')
    end
    pre.trust_rating = trust_rating

    -- ── Trust breakdown ──
    -- Format: <span ...>-3.2%</span>...<span ...>Teammates</span>
    local trust_breakdown = {}
    if trust_section ~= "" then
        for delta, factor in trust_section:gmatch('>([%+%-][%d%.]+)%%<[^>]*>[^<]*</span>[^>]*>[^<]*<span[^>]*>([^<]+)</span>') do
            trust_breakdown[#trust_breakdown + 1] = {
                factor = factor:match("^%s*(.-)%s*$"),
                delta = tonumber(delta),
            }
        end
    end
    -- Fallback: simpler pattern
    if #trust_breakdown == 0 and trust_section ~= "" then
        for delta, factor in trust_section:gmatch('text%-rose%-300">([%+%-][%d%.]+)%%</span>.-text%-slate%-400">([^<]+)</span>') do
            trust_breakdown[#trust_breakdown + 1] = {
                factor = factor:match("^%s*(.-)%s*$"),
                delta = tonumber(delta),
            }
        end
    end
    pre.trust_breakdown = trust_breakdown

    -- Extract ban status
    pre.has_ban = flat:match("community ban") ~= nil
        or flat:match("VAC Ban") ~= nil
        or flat:match("Game Ban") ~= nil

    -- ── Key stat cards ──
    local kd = extract_stat(html, "k/d ratio") or extract_stat(html, "k/d")
    local adr = extract_stat(html, "adr")
    local hltv_rating = extract_stat(html, "hltv rating")
    local kast = extract_stat(html, "kast")
    local accuracy = extract_stat(html, "accuracy")
    local ttd = extract_stat(html, "ttd") or extract_stat(html, "spot to damage")
    local preaim = extract_stat(html, "preaim")
    local aim_offset = extract_stat(html, "aim offset")

    logger:info("CSTracker stat cards: kd=" .. tostring(kd) .. " adr=" .. tostring(adr)
        .. " hltv=" .. tostring(hltv_rating) .. " kast=" .. tostring(kast)
        .. " accuracy=" .. tostring(accuracy) .. " ttd=" .. tostring(ttd)
        .. " preaim=" .. tostring(preaim) .. " aim_offset=" .. tostring(aim_offset)
        .. " trust=" .. tostring(trust_rating))

    pre.kd = kd
    pre.adr = adr
    pre.hltv_rating = hltv_rating
    pre.kast = kast
    pre.accuracy = accuracy
    pre.ttd = ttd
    pre.preaim = preaim
    pre.aim_offset = aim_offset

    -- ── Detailed stats section (key-value rows) ──
    local kda_raw = extract_detail_value(html, "K/D/A")
    local kills_total, deaths_total, assists_total
    if kda_raw then
        kills_total, deaths_total, assists_total = kda_raw:match("(%d[%d,]*) / (%d[%d,]*) / (%d[%d,]*)")
        if kills_total then
            kills_total = tonumber((kills_total:gsub(",", "")))
            deaths_total = tonumber((deaths_total:gsub(",", "")))
            assists_total = tonumber((assists_total:gsub(",", "")))
        end
    end
    pre.kills_total = kills_total
    pre.deaths_total = deaths_total
    pre.assists_total = assists_total

    local winrate_str = extract_detail_value(html, "Win rate")
    pre.winrate = winrate_str and extract_number(winrate_str, "([%d%.]+)") or nil

    local hs_kills_str = extract_detail_value(html, "HS kills")
    local hs_kills, hs_pct
    if hs_kills_str then
        hs_kills = extract_number(hs_kills_str, "(%d[%d,]*)")
        hs_pct = extract_number(hs_kills_str, "%(([%d%.]+)%%%)")
    end
    pre.hs_kills = hs_kills
    pre.hs_pct = hs_pct

    local first_kills_str = extract_detail_value(html, "First kills")
    pre.first_kills = first_kills_str and extract_number(first_kills_str, "(%d+)") or nil

    local trade_kills_str = extract_detail_value(html, "Trade kills")
    pre.trade_kills = trade_kills_str and extract_number(trade_kills_str, "(%d+)") or nil

    local enemy_damage_str = extract_detail_value(html, "Enemy damage")
    pre.enemy_damage = enemy_damage_str and tonumber((enemy_damage_str:gsub(",", ""))) or nil

    local bhop_str = extract_detail_value(html, "Bhop success")
    pre.bhop_success = bhop_str and extract_number(bhop_str, "([%d%.]+)") or nil

    local spray_accuracy_str = extract_detail_value(html, "Spray accuracy")
    pre.spray_accuracy = spray_accuracy_str and extract_number(spray_accuracy_str, "([%d%.]+)") or nil

    local spot_to_damage_str = extract_detail_value(html, "Spot to damage")
    pre.spot_to_damage = spot_to_damage_str and extract_number(spot_to_damage_str, "(%d+)") or nil

    local spot_to_kill_str = extract_detail_value(html, "Spot to kill")
    pre.spot_to_kill = spot_to_kill_str and extract_number(spot_to_kill_str, "(%d+)") or nil

    local counter_strafing_str = extract_detail_value(html, "Counter%-strafing")
    pre.counter_strafing = counter_strafing_str and extract_number(counter_strafing_str, "([%d%.]+)") or nil

    -- Utility
    local grenade_throws_str = extract_detail_value(html, "Grenade throws")
    pre.grenade_throws = grenade_throws_str and tonumber((grenade_throws_str:gsub(",", ""))) or nil

    local flash_assists_str = extract_detail_value(html, "Flash assists")
    pre.flash_assists = flash_assists_str and extract_number(flash_assists_str, "(%d+)") or nil

    local enemies_flashed_str = extract_detail_value(html, "Enemies flashed")
    pre.enemies_flashed = enemies_flashed_str and extract_number(enemies_flashed_str, "([%d%.]+)") or nil

    local avg_flash_dur_str = extract_detail_value(html, "Avg flash duration")
    pre.avg_flash_duration = avg_flash_dur_str and extract_number(avg_flash_dur_str, "([%d%.]+)") or nil

    local util_dmg_str = extract_detail_value(html, "Util dmg")
    pre.util_dmg_per_match = util_dmg_str and extract_number(util_dmg_str, "([%d%.]+)") or nil

    local he_dmg_str = extract_detail_value(html, "HE dmg")
    pre.he_dmg_per_throw = he_dmg_str and extract_number(he_dmg_str, "([%d%.]+)") or nil

    local fire_dmg_str = extract_detail_value(html, "Fire dmg")
    pre.fire_dmg_per_throw = fire_dmg_str and extract_number(fire_dmg_str, "([%d%.]+)") or nil

    local unused_util_str = extract_detail_value(html, "Unused util")
    pre.unused_util_on_death = unused_util_str and extract_number(unused_util_str, "(%d+)") or nil

    -- Behavior
    local afk_time_str = extract_detail_value(html, "AFK time")
    pre.afk_time_per_match = afk_time_str and extract_number(afk_time_str, "(%d+)") or nil

    local teamkills_str = extract_detail_value(html, "Teamkills")
    pre.teamkills_per_match = teamkills_str and extract_number(teamkills_str, "([%d%.]+)") or nil

    local team_damage_str = extract_detail_value(html, "Team damage")
    pre.team_damage_per_match = team_damage_str and extract_number(team_damage_str, "([%d%.]+)") or nil

    local avg_teammates_flashed_str = extract_detail_value(html, "Avg teammates flashed")
    pre.avg_teammates_flashed = avg_teammates_flashed_str and extract_number(avg_teammates_flashed_str, "([%d%.]+)") or nil

    local teammate_flash_dur_str = extract_detail_value(html, "Teammate flash duration")
    pre.teammate_flash_duration = teammate_flash_dur_str and extract_number(teammate_flash_dur_str, "([%d%.]+)") or nil

    local input_automation_str = extract_detail_value(html, "Input automation")
    pre.input_automation = input_automation_str and extract_number(input_automation_str, "([%d%.]+)") or nil

    local vote_kicked_str = extract_detail_value(html, "Vote kicked")
    pre.vote_kicked = vote_kicked_str and extract_number(vote_kicked_str, "(%d+)") or nil

    local team_dmg_kicks_str = extract_detail_value(html, "Team DMG kicks")
    pre.team_dmg_kicks = team_dmg_kicks_str and extract_number(team_dmg_kicks_str, "(%d+)") or nil

    -- ── Kill breakdown ──
    local kill_breakdown = {}
    local breakdown_items = {
        { key = "wallbangs", label = "wallbangs" },
        { key = "through_smokes", label = "through smokes" },
        { key = "in_air", label = "in%-air" },
        { key = "noscope", label = "noscope" },
        { key = "headshots", label = "headshots" },
    }
    for _, item in ipairs(breakdown_items) do
        local pos = flat:find("// " .. item.label, 1, true)
        if pos == nil then
            pos = flat:find("// " .. item.label:gsub("%%", ""), 1, true)
        end
        if pos then
            local section = flat:sub(pos, pos + 500)
            local pct = extract_number(section, '>([%d%.]+)%%<')
            local count_raw, total_raw = section:match('(%d[%d,]*)%s*/%s*(%d[%d,]*)%s*kills')
            kill_breakdown[item.key] = {
                percentage = pct,
                count = count_raw and tonumber((count_raw:gsub(",", ""))),
                total = total_raw and tonumber((total_raw:gsub(",", ""))),
            }
        end
    end
    pre.kill_breakdown = kill_breakdown

    -- ── Clutch performance (1v1 through 1v5) ──
    local clutch = {}
    for label, wins, losses, winpct in flat:gmatch(
        '// (%dv%d)</div>.-display%-num text%-xl text%-white">'
        .. '<span class="text%-emerald%-300">(%d+)</span>'
        .. '.-<span class="text%-rose%-300">(%d+)</span>'
        .. '.-text%-slate%-500">(%d+)%%'
    ) do
        clutch[#clutch + 1] = {
            label = label,
            wins = tonumber(wins),
            losses = tonumber(losses),
            winrate = tonumber(winpct),
        }
    end
    pre.clutch = clutch

    -- ── HTMX lazy-loaded section URLs ──
    -- CSTracker uses HTMX to lazy-load match history, teammates, and maps.
    -- The main page has hx-get attributes pointing to partial HTML endpoints.
    local hx_urls = {}
    for hx_url in flat:gmatch('hx%-get="([^"]+)"') do
        hx_urls[#hx_urls + 1] = hx_url
    end
    logger:info("CSTracker: found " .. #hx_urls .. " hx-get URLs: " .. table.concat(hx_urls, ", "))

    return pre, hx_urls
end

---Stage 2 parsing: merge HTMX section HTML with the pre-extracted main-page
---fields and encode the final provider response. Pure function of its
---inputs.
---@param steam_id string
---@param profile_url string
---@param pre table result of extract_pre
---@param extra_html string concatenated HTMX section bodies (may be "")
---@return string JSON-encoded provider response
local function build_cstracker_result(steam_id, profile_url, pre, extra_html)
    local flat = pre.flat
    local html = pre.html

    -- Merge extra HTML into flat for extraction
    local flat_extra = extra_html:gsub("\r?\n", " ")
    flat = flat .. " " .. flat_extra

    -- ── Map performance ──
    -- The map performance section is identified by the header "// 09 · maps"
    -- (or variants like "// 08–09 · HISTORY INSIGHTS" containing "Ranks and maps").
    -- The section itself has no unique class, so we find the header then parse
    -- all map_icon references within that section's HTML.
    local map_performance = {}

    -- Find the maps/ranks section by its header
    local maps_section = nil
    local maps_header_pos = flat:find("// 09 · maps", 1, true)
        or flat:find("// 08–09 ·", 1, true)
        or flat:find("Ranks and maps", 1, true)
    if maps_header_pos then
        -- Take a generous chunk from the header onwards (the section content)
        -- Stop before the next major section header (// 10 ·, // 11 ·, etc.)
        local section_chunk = flat:sub(maps_header_pos, maps_header_pos + 30000)
        -- Trim at the next section header if present
        local next_section = section_chunk:find("// %d+ ·", 100)
        if next_section then
            maps_section = section_chunk:sub(1, next_section - 1)
        else
            maps_section = section_chunk
        end
        logger:info("CSTracker MAP: found maps section via header, length=" .. #maps_section)
    else
        logger:info("CSTracker MAP: no maps section header found, trying fallback")
        maps_section = flat
    end

    -- Find all map icons within the maps section and extract per-map stats
    local seen_maps = {}
    for map_file in maps_section:gmatch('map_icon_([%w_]+)%.svg') do
        if not seen_maps[map_file] then
            seen_maps[map_file] = true
            local icon_pos = maps_section:find('map_icon_' .. map_file .. '.svg', 1, true)
            if icon_pos then
                -- Look at the surrounding context for this map card
                local nearby = maps_section:sub(icon_pos, icon_pos + 2000)

                -- Extract map name from the icon filename
                local map_name = map_file:gsub("^de_", ""):gsub("^cs_", ""):gsub("_", " ")
                if map_name then map_name = map_name:sub(1, 1):upper() .. map_name:sub(2) end

                -- Look for match count, W/L/T, winrate in the card
                local match_count = extract_number(nearby, '(%d+)%s*matches')
                    or extract_number(nearby, '(%d+)%s*m')
                local wins = extract_number(nearby, '(%d+)W')
                local losses = extract_number(nearby, '(%d+)L')
                local ties = extract_number(nearby, '(%d+)T')
                local winrate_map = extract_number(nearby, '(%d+)%%')

                -- Only add if we found at least a match count or W/L data
                if match_count or wins or losses then
                    map_performance[#map_performance + 1] = {
                        map_name = map_name, matches = match_count,
                        wins = wins, losses = losses, ties = ties, winrate = winrate_map,
                    }
                end
            end
        end
    end

    -- Fallback: if no map icons in the section, try finding map names as text
    if #map_performance == 0 then
        -- CSTracker lists maps like "Mirage", "Dust2", etc. in the ranks section
        local map_names_section = maps_section or flat
        for map_display_name in map_names_section:gmatch('<span>([A-Z][a-z]+)</span>') do
            local key = map_display_name:lower()
            if not seen_maps[key] and key ~= "loading" and key ~= "waiting" and key ~= "general" then
                seen_maps[key] = true
                local map_pos = map_names_section:find(map_display_name, 1, true)
                if map_pos then
                    local nearby = map_names_section:sub(map_pos, map_pos + 1500)
                    local match_count = extract_number(nearby, '(%d+)%s*matches')
                        or extract_number(nearby, '(%d+)%s*m')
                    local wins = extract_number(nearby, '(%d+)W')
                    local losses = extract_number(nearby, '(%d+)L')
                    local ties = extract_number(nearby, '(%d+)T')
                    local winrate_map = extract_number(nearby, '(%d+)%%')
                    if match_count or wins or losses then
                        map_performance[#map_performance + 1] = {
                            map_name = map_display_name, matches = match_count,
                            wins = wins, losses = losses, ties = ties, winrate = winrate_map,
                        }
                    end
                end
            end
        end
    end
    logger:info("CSTracker MAP: extracted " .. #map_performance .. " map performance entries")

    -- ── Match history ──
    local match_history = {}
    local en_dash = "\226\128\147"

    -- Debug: find match history section and log a sample
    local mh_start = flat:find('player%-match%-history%-section', 1)
    if mh_start then
        local mh_sample = flat:sub(mh_start, math.min(mh_start + 2000, #flat))
        logger:info("CSTracker MH section sample: " .. mh_sample:sub(1, 500))
    else
        logger:info("CSTracker MH: player-match-history-section NOT found")
    end

    -- Try multiple patterns for match history rows
    local match_rows = {}
    for row in flat:gmatch('<tr class="transition hover:brightness%-125"[^>]*>(.-)</tr>') do
        match_rows[#match_rows + 1] = row
    end
    if #match_rows == 0 then
        for row in flat:gmatch('<tr [^>]*brightness[^>]*>(.-)</tr>') do
            match_rows[#match_rows + 1] = row
        end
    end
    if #match_rows == 0 then
        for row in flat:gmatch('<tr>(.-)</tr>') do
            if row:match('href="/matches/%d+"') then
                match_rows[#match_rows + 1] = row
            end
        end
    end
    logger:info("CSTracker MH: collected " .. #match_rows .. " match rows")
    -- Debug: log first match row to see HTML structure
    if #match_rows > 0 then
        logger:info("CSTracker MH DEBUG row[1] first 800 chars: " .. match_rows[1]:sub(1, 800))
    end

    for _, row in ipairs(match_rows) do
        local map_name = row:match('font%-medium text%-white[^>]*>([^<]+)<')
            or row:match('font%-medium text%-white">([^<]+)<')

        local score_text = row:match('text%-rose%-400">(%d+' .. en_dash .. '%d+)<')
            or row:match('text%-emerald%-400">(%d+' .. en_dash .. '%d+)<')
            or row:match('text%-slate%-300">(%d+' .. en_dash .. '%d+)<')
            or row:match('rose%-400">(%d+[%–—%-]+%d+)<')
            or row:match('emerald%-400">(%d+[%–—%-]+%d+)<')
            or row:match('slate%-300">(%d+[%–—%-]+%d+)<')

        local outcome = "unknown"
        if score_text then
            local s1, s2 = score_text:match("(%d+)" .. en_dash .. "(%d+)")
            if s1 == nil then s1, s2 = score_text:match("(%d+)[%–—%-]+(%d+)") end
            if s1 and s2 then
                local a, b = tonumber(s1), tonumber(s2)
                if a > b then outcome = "win" elseif a < b then outcome = "loss" else outcome = "tie" end
            end
        end

        local k1, d1, a1 = row:match('(%d+) / (%d+) / (%d+)')
        local kills_m = k1 and tonumber(k1)
        local deaths_m = d1 and tonumber(d1)
        local assists_m = a1 and tonumber(a1)

        local when_text = row:match('title="played ([^"]+)"')
            or row:match('data%-time%-ago="%d+"[^>]*>([^<]+)<')
        local match_link = row:match('href="(/matches/%d+)"')

        local stat_cells = {}
        for cell_content in row:gmatch('align%-middle">(.-)</td>') do
            local stripped = strip_html(cell_content):match("^%s*(.-)%s*$")
            if stripped ~= "" and stripped then stat_cells[#stat_cells + 1] = stripped end
        end

        if map_name then
            match_history[#match_history + 1] = {
                outcome = outcome, map_name = map_name, score = score_text,
                kills = kills_m, deaths = deaths_m, assists = assists_m,
                kd = stat_cells[2] and tonumber(stat_cells[2]),
                adr = stat_cells[3] and tonumber(stat_cells[3]),
                rating = stat_cells[4] and tonumber(stat_cells[4]),
                kast = stat_cells[5] and extract_number(stat_cells[5], "([%d%.]+)"),
                accuracy = stat_cells[6] and extract_number(stat_cells[6], "([%d%.]+)"),
                preaim = stat_cells[7] and extract_number(stat_cells[7], "([%d%.]+)"),
                ttd = stat_cells[8] and extract_number(stat_cells[8], "([%d%.]+)"),
                when_text = when_text, match_link = match_link,
                data_source = "cstracker",
            }
        end
        if #match_history >= 20 then break end
    end
    logger:info("CSTracker MH: extracted " .. #match_history .. " match history entries")

    -- ── Teammates ──
    local teammates = {}

    for row in flat:gmatch('<tr>(.-)</tr>') do
        local sid = row:match('href="/players/(%d+)"')
        if sid then
            local name = row:match('href="/players/%d+">([^<]+)</a>')
            local together = extract_number(row, 'text%-white">(%d+)<div')
                or extract_number(row, 'font%-medium text%-white">(%d+)</div>')
                or extract_number(row, 'font%-medium text%-white">(%d+)<')
            local wins_t = extract_number(row, 'text%-emerald%-400">(%d+)</span>')
            local losses_t = extract_number(row, 'text%-rose%-400">(%d+)</span>')
            local winrate_t = extract_number(row, 'tabular%-nums text%-white">(%d+)%%')
                or extract_number(row, 'text%-xs[^>]*>(%d+)%%')
            local last_map = row:match('hover:text%-amber%-100" href="/matches/%d+">([^<]+)<')
            local last_score = row:match('hover:text%-amber%-100" href="/matches/%d+">[^<]+<span[^>]*>([^<]+)</span>')
            local last_ago = row:match('data%-time%-ago="%d+"[^>]*>([^<]+)<')
            local hidden_cells = {}
            for cell in row:gmatch('hidden md:table%-cell[^>]*>([^<]+)') do
                local n = tonumber(cell)
                if n then hidden_cells[#hidden_cells + 1] = n end
            end

            if name and sid then
                teammates[#teammates + 1] = {
                    name = name, steam64_id = sid,
                    matches_together = together,
                    wins = wins_t, losses = losses_t,
                    winrate = winrate_t,
                    kd = hidden_cells[1],
                    rating = hidden_cells[2],
                    adr = hidden_cells[3],
                    last_match_map = last_map,
                    last_match_score = last_score,
                    last_match_ago = last_ago,
                }
            end
        end
    end
    logger:info("CSTracker TM: extracted " .. #teammates .. " teammates")

    -- ── Legacy compatibility fields ──
    local total_matches = extract_number(html, '(%d+)%s*matches')
    local premier = extract_number(html, "premier[^\"]*\"[^\"]*>>([%d,]+)")
    local faceit_level = extract_number(html, "FACEIT[^<]*level%s*(%d+)")
    local faceit_elo = extract_number(html, "FACEIT[^<]*([%d,]+)%s*ELO")

    return reg.encode({
        status = "ok",
        data = {
            name = pre.player_name,
            steam64_id = steam_id,
            profile_url = profile_url,

            -- Trust & ban
            trust_rating = pre.trust_rating,
            trust_breakdown = pre.trust_breakdown,
            has_ban = pre.has_ban,

            -- Core stats (from stat cards)
            kd = pre.kd, adr = pre.adr, hltv_rating = pre.hltv_rating, kast = pre.kast,
            accuracy = pre.accuracy, ttd = pre.ttd, preaim = pre.preaim, aim_offset = pre.aim_offset,
            winrate = pre.winrate, total_matches = total_matches,

            -- Detailed totals
            kills = pre.kills_total, deaths = pre.deaths_total, assists = pre.assists_total,
            hs_kills = pre.hs_kills, hs_pct = pre.hs_pct,
            first_kills = pre.first_kills, trade_kills = pre.trade_kills,
            enemy_damage = pre.enemy_damage, bhop_success = pre.bhop_success,

            -- Aim & reactions
            spray_accuracy = pre.spray_accuracy, spot_to_damage = pre.spot_to_damage,
            spot_to_kill = pre.spot_to_kill, counter_strafing = pre.counter_strafing,

            -- Utility
            grenade_throws = pre.grenade_throws, flash_assists = pre.flash_assists,
            enemies_flashed_per_flash = pre.enemies_flashed,
            avg_flash_duration = pre.avg_flash_duration,
            util_dmg_per_match = pre.util_dmg_per_match,
            he_dmg_per_throw = pre.he_dmg_per_throw,
            fire_dmg_per_throw = pre.fire_dmg_per_throw,
            unused_util_on_death = pre.unused_util_on_death,

            -- Behavior
            afk_time_per_match = pre.afk_time_per_match,
            teamkills_per_match = pre.teamkills_per_match,
            team_damage_per_match = pre.team_damage_per_match,
            avg_teammates_flashed = pre.avg_teammates_flashed,
            teammate_flash_duration = pre.teammate_flash_duration,
            input_automation = pre.input_automation,
            vote_kicked = pre.vote_kicked,
            team_dmg_kicks = pre.team_dmg_kicks,

            -- Kill breakdown
            kill_breakdown = pre.kill_breakdown,

            -- Clutch performance
            clutch = pre.clutch,

            -- Map performance
            map_performance = map_performance,

            -- Match history
            match_history = match_history,
            recent_matches = match_history,

            -- Teammates
            teammates = teammates,

            -- Rank / FACEIT
            premier = premier,
            faceit_level = faceit_level,
            faceit_elo = faceit_elo,
        },
        fetched_at = os.time(),
    })
end

---Shared post-fetch checks for the profile page body: Cloudflare challenge
---detection (when not already solved) and the empty-profile heuristic.
---@param html string
---@param fs_used boolean
---@param response table|nil
---@param profile_url string
---@return string|nil error_json  when the page must not be parsed
local function page_guard(html, fs_used, response, profile_url)
    if not fs_used and http_utils.is_cloudflare_challenge(response) then
        logger:warn("CSTracker: Cloudflare challenge detected (HTTP " .. tostring(response.status) .. ")")
        return reg.encode({ status = "cloudflare_required", message = "Visit cstracker.gg to complete verification, then retry.", url = profile_url })
    end
    if not html:match("premier") and not html:match("trust") and not html:match("rating") then
        return reg.encode({ status = "not_found", message = "CSTracker profile appears empty for this account." })
    end
    return nil
end

---HTMX section request descriptor (shared by fetch + pipeline).
local function htmx_section_req(hx_url, profile_url)
    return http_utils.get_req("https://cstracker.gg" .. hx_url, {
        ["Accept"] = "text/html, */*; q=0.01",
        ["HX-Request"] = "true",
        ["HX-Current-URL"] = profile_url,
        ["Referer"] = profile_url,
    }, 10)
end

function cstracker.fetch(steam_id)
    if not reg.valid_steam_id(steam_id) then
        return reg.encode({ status = "error", message = "Invalid SteamID64." })
    end

    local profile_url = "https://cstracker.gg/players/" .. steam_id
    logger:info("CSTracker: fetching " .. profile_url)
    local response, request_error, fs_used = http_utils.get_raw(profile_url, {
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
    }, 12)

    if response == nil then
        if http_utils.is_cloudflare_error(request_error) then
            logger:warn("CSTracker: Cloudflare challenge and no FlareSolverr — failing fast")
            return reg.encode({
                status = "cloudflare_required",
                message = "Visit cstracker.gg to complete verification, then retry.",
                url = profile_url,
            })
        end
        logger:warn("CSTracker: HTTP request failed: " .. tostring(request_error))
        return reg.provider_error("CSTracker", 0, request_error or "Network request failed.")
    end
    logger:info("CSTracker: HTTP " .. tostring(response.status) .. ", body length " .. tostring(#response.body))

    if response.status == 404 then
        return reg.encode({ status = "not_found", message = "CSTracker has no profile for this Steam account." })
    end

    if response.status < 200 or response.status >= 300 then
        return reg.provider_error("CSTracker", response.status, "HTTP " .. tostring(response.status))
    end

    local html = response.body

    local guard_err = page_guard(html, fs_used, response, profile_url)
    if guard_err ~= nil then
        return guard_err
    end

    local pre, hx_urls = extract_pre(html)

    -- Fetch each HTMX section and merge the HTML
    local extra_html = ""
    for _, hx_url in ipairs(hx_urls) do
        logger:info("CSTracker: fetching HTMX section https://cstracker.gg" .. hx_url)
        local section_resp, section_err, section_fs = http_utils.get_raw("https://cstracker.gg" .. hx_url, {
            ["Accept"] = "text/html, */*; q=0.01",
            ["HX-Request"] = "true",
            ["HX-Current-URL"] = profile_url,
            ["Referer"] = profile_url,
        }, 10)
        if section_resp and section_resp.status == 200 then
            extra_html = extra_html .. " " .. section_resp.body
            logger:info("CSTracker: HTMX section fetched OK, body length " .. #section_resp.body)
        else
            logger:warn("CSTracker: HTMX section failed: " .. tostring(section_err or section_resp and section_resp.status))
        end
    end

    return build_cstracker_result(steam_id, profile_url, pre, extra_html)
end

---Parallel pipeline: page → (optional FlareSolverr) → HTMX sections → build.
function cstracker.pipeline(steam_id)
    local p = { phase = "page", queue = {}, finished = false }
    local profile_url = "https://cstracker.gg/players/" .. steam_id
    local PAGE_HEADERS = {
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
    }

    local function handle_page_body(html, fs_used, response)
        local guard_err = page_guard(html, fs_used, response, profile_url)
        if guard_err ~= nil then
            p:finish(guard_err)
            return
        end
        local pre, hx_urls = extract_pre(html)
        p.pre = pre
        p.extra_html = ""
        if #hx_urls == 0 then
            p:finish(build_cstracker_result(steam_id, profile_url, pre, ""))
            return
        end
        p.pending = #hx_urls
        p.phase = "htmx"
        for i, hx_url in ipairs(hx_urls) do
            local req = htmx_section_req(hx_url, profile_url)
            req.tag = "htmx"
            req.section_index = i
            p.queue[#p.queue + 1] = req
        end
    end

    function p.next()
        if p.phase == "page" then
            logger:info("CSTracker: fetching " .. profile_url)
            local req = http_utils.get_req(profile_url, PAGE_HEADERS, 12)
            req.tag = "page"
            p.queue = { req }
        elseif p.phase == "fs_page" then
            local fs_url = http_utils.flaresolverr_url()
            local req = http_utils.fs_req(fs_url, {
                cmd = "request.get",
                url = profile_url,
                maxTimeout = 12000,
                userAgent = http_utils.chrome_user_agent(),
            }, 30)
            req.tag = "fs_page"
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
                logger:warn("CSTracker: HTTP request failed: " .. tostring(resp.error))
                p:finish(reg.provider_error("CSTracker", 0, resp.error or "Network request failed."))
                return
            end
            logger:info("CSTracker: HTTP " .. tostring(resp.status) .. ", body length " .. tostring(#(resp.body or "")))
            if resp.status == 404 then
                p:finish(reg.encode({ status = "not_found", message = "CSTracker has no profile for this Steam account." }))
                return
            end
            if resp.status < 200 or resp.status >= 300 then
                p:finish(reg.provider_error("CSTracker", resp.status, "HTTP " .. tostring(resp.status)))
                return
            end
            if http_utils.is_cloudflare_challenge(resp) then
                if http_utils.flaresolverr_url() ~= nil then
                    p.phase = "fs_page"
                    return
                end
                logger:warn("CSTracker: Cloudflare challenge and no FlareSolverr — failing fast")
                p:finish(reg.encode({
                    status = "cloudflare_required",
                    message = "Visit cstracker.gg to complete verification, then retry.",
                    url = profile_url,
                }))
                return
            end
            handle_page_body(resp.body or "", false, resp)
        elseif req.tag == "fs_page" then
            local solution, err = http_utils.fs_solution(resp)
            if solution == nil then
                logger:warn("CSTracker: FlareSolverr retry failed: " .. tostring(err))
                p:finish(reg.encode({
                    status = "cloudflare_required",
                    message = "Visit cstracker.gg to complete verification, then retry.",
                    url = profile_url,
                }))
                return
            end
            handle_page_body(solution.response or "", true, { status = solution.status or 200, body = solution.response or "" })
        elseif req.tag == "htmx" then
            if resp.status == 200 and type(resp.body) == "string" then
                p.extra_html = p.extra_html .. " " .. resp.body
                logger:info("CSTracker: HTMX section fetched OK, body length " .. #resp.body)
            else
                logger:warn("CSTracker: HTMX section failed: " .. tostring(resp.error or resp.status))
            end
            p.pending = p.pending - 1
            if p.pending <= 0 then
                p:finish(build_cstracker_result(steam_id, profile_url, p.pre, p.extra_html))
            end
        end
    end

    return p
end

reg.register({
    name = "cstracker",
    display_name = "CSTracker.GG",
    config_key = "cstracker_enabled",
    fetch = cstracker.fetch,
    pipeline = cstracker.pipeline,
})

return cstracker
