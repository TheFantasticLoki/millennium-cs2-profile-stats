---Minimal pure-Lua JSON for local test harnesses (system LuaJIT has no
---cjson). JSON null decodes to nil — safe with the registry's is_null
---guards (nil and cjson.null are both treated as absent).
local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local decode_value

local function decode_string(s, i)
    -- i points at opening quote
    local buf = {}
    i = i + 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(buf), i + 1
        elseif c == "\\" then
            local n = s:sub(i + 1, i + 1)
            if n == "n" then buf[#buf + 1] = "\n"
            elseif n == "t" then buf[#buf + 1] = "\t"
            elseif n == "r" then buf[#buf + 1] = "\r"
            elseif n == "b" then buf[#buf + 1] = "\b"
            elseif n == "f" then buf[#buf + 1] = "\f"
            elseif n == "u" then
                local hex = s:sub(i + 2, i + 5)
                local cp = tonumber(hex, 16) or 63
                if cp < 0x80 then
                    buf[#buf + 1] = string.char(cp)
                elseif cp < 0x800 then
                    buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
                else
                    buf[#buf + 1] = string.char(0xE0 + math.floor(cp / 0x1000),
                        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
                end
                i = i + 4
            else
                buf[#buf + 1] = n
            end
            i = i + 2
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    error("unterminated string")
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then
        return decode_string(s, i)
    elseif c == "{" then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            local k
            k, i = decode_string(s, i)
            i = skip_ws(s, i)
            assert(s:sub(i, i) == ":", "expected : in object")
            local v
            v, i = decode_value(s, i + 1)
            obj[k] = v
            i = skip_ws(s, i)
            local ch = s:sub(i, i)
            if ch == "}" then return obj, i + 1 end
            assert(ch == ",", "expected , in object")
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v
            v, i = decode_value(s, i)
            arr[#arr + 1] = v
            i = skip_ws(s, i)
            local ch = s:sub(i, i)
            if ch == "]" then return arr, i + 1 end
            assert(ch == ",", "expected , in array")
            i = i + 1
        end
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        assert(num and #num > 0, "invalid JSON value at " .. i)
        return tonumber(num), i + #num
    end
end

function json.decode(s)
    local v = decode_value(s, 1)
    return v
end

local encode_value

local function is_array(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n == #t
end

encode_value = function(v)
    local tv = type(v)
    if v == nil or v == json.null then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
            return string.format("%d", v)
        end
        return string.format("%.14g", v)
    elseif tv == "string" then
        return '"' .. v:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
    elseif tv == "table" then
        if is_array(v) and #v > 0 then
            local parts = {}
            for i = 1, #v do parts[i] = encode_value(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                if val ~= nil and val ~= json.null then
                    parts[#parts + 1] = encode_value(tostring(k)) .. ":" .. encode_value(val)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    error("cannot encode " .. tv)
end

function json.encode(v)
    return encode_value(v)
end

return json
