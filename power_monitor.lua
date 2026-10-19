local CONFIG = {
    title = "Power Monitor",
    monitorName = nil,
    textScale = 0.5,
    refreshSeconds = 1,
    rateWindowSeconds = 10,
    pageSeconds = 8,
    returnToOverviewSeconds = 120,
    idleThreshold = 0.05,
    ignoreDirectSides = true,
    groups = {
        {
            id = "solar",
            prefix = "advanced_solar_generator",
            tab = "SOLAR",
            title = "SOLAR GENERATORS",
            single = "Solar Generator",
            short = "SOLAR",
            unit = "EU",
            colorName = "orange",
            emptyStatus = "IDLE",
            empty = "No advanced solar generators were found on the wired network.",
        },
        {
            id = "cell",
            prefix = "cofh_thermalexpansion_energycell",
            tab = "CELLS",
            title = "ENERGY CELLS",
            single = "Energy Cell",
            short = "CELLS",
            unit = "RF",
            colorName = "green",
            emptyStatus = "EMPTY",
            empty = "No Thermal Expansion energy cells were found on the wired network.",
        },
    },
}

local unpack = table.unpack or unpack

local STORED_METHODS = {
    "getEnergyStored", "getEUStored", "getEnergy", "getStored",
    "getStoredEnergy", "getRFStored", "getStoredEU", "getEnergyLevel",
}

local CAPACITY_METHODS = {
    "getMaxEnergyStored", "getEUCapacity", "getEnergyCapacity", "getMaxEnergy",
    "getCapacity", "getMaxStoredEnergy", "getRFCapacity", "getMaxEU", "getMaxEnergyLevel",
}

local CALL_ARGS = { {}, { "unknown" }, { "north" }, { "up" } }

local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

local mon, monName
local ui
local W, H = 0, 0
local forceRedraw = true
local hotspots = {}
local currentTab = "overview"
local pageByTab = {}
local pageCountByTab = {}
local pageClock = 0
local idleClock = 0
local devices = {}
local readers = {}
local history = {}

local IS_COLOR = false
local C_BG, C_HEADER, C_DIV, C_INSET, C_ACCENT, C_TEXT, C_MUTED, C_BRAND
local C_OK, C_WARN, C_BAD, C_FULL, C_HDR_TEXT

local function applyPalette(m)
    IS_COLOR = (m.isColor and m.isColor()) or false
    C_BG       = colors.black
    C_HEADER   = IS_COLOR and colors.lightGray or colors.black
    C_DIV      = IS_COLOR and colors.gray or colors.black
    C_INSET    = colors.black
    C_ACCENT   = IS_COLOR and colors.cyan or colors.white
    C_TEXT     = colors.white
    C_MUTED    = IS_COLOR and colors.lightGray or colors.white
    C_BRAND    = IS_COLOR and colors.blue or colors.white
    C_OK       = IS_COLOR and colors.lime or colors.white
    C_WARN     = IS_COLOR and colors.yellow or colors.white
    C_BAD      = IS_COLOR and colors.red or colors.white
    C_FULL     = IS_COLOR and colors.cyan or colors.white
    C_HDR_TEXT = IS_COLOR and colors.gray or colors.white
    for _, g in ipairs(CONFIG.groups) do
        g.color = IS_COLOR and colors[g.colorName] or colors.white
    end
end

local function clamp(n, a, b)
    if n < a then return a end
    if n > b then return b end
    return n
end

local function fmtFixed(n, digits)
    n = tonumber(n) or 0
    digits = math.max(0, math.floor(tonumber(digits) or 0))
    if n ~= n or n == math.huge or n == -math.huge then return "0" end
    local scale = 1
    for _ = 1, digits do scale = scale * 10 end
    local scaled
    if n >= 0 then
        scaled = math.floor(n * scale + 0.5)
    else
        scaled = math.ceil(n * scale - 0.5)
    end
    local negative = scaled < 0
    if negative then scaled = -scaled end
    local whole = math.floor(scaled / scale)
    local sign = negative and "-" or ""
    if digits == 0 then return sign .. tostring(whole) end
    local frac = math.floor(scaled - whole * scale)
    if frac == 0 then return sign .. tostring(whole) end
    local fracText = tostring(frac)
    while #fracText < digits do fracText = "0" .. fracText end
    fracText = fracText:gsub("0+$", "")
    return sign .. tostring(whole) .. "." .. fracText
end

local SUFFIXES = { { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "K" } }

local function fmtAmount(n)
    n = tonumber(n) or 0
    local a = math.abs(n)
    for _, s in ipairs(SUFFIXES) do
        if a >= s[1] then
            local v = n / s[1]
            local av = math.abs(v)
            if av >= 100 then return fmtFixed(v, 0) .. s[2] end
            if av >= 10 then return fmtFixed(v, 1) .. s[2] end
            return fmtFixed(v, 2) .. s[2]
        end
    end
    if a >= 10 then return fmtFixed(n, 0) end
    return fmtFixed(n, 1)
end

local function fmtPct(p)
    local s = fmtFixed(clamp(p, 0, 100), 1)
    if not s:find("%.") then s = s .. ".0" end
    return s .. "%"
end

local function fmtRate(rate, unit)
    if rate == nil then return "-- " .. unit .. "/T" end
    if math.abs(rate) < CONFIG.idleThreshold then return "0 " .. unit .. "/T" end
    local sign = rate > 0 and "+" or ""
    return sign .. fmtAmount(rate) .. " " .. unit .. "/T"
end

local function fmtDuration(seconds)
    seconds = math.floor(seconds + 0.5)
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if d > 0 then return tostring(d) .. "D " .. tostring(h) .. "H" end
    if h > 0 then return tostring(h) .. "H " .. tostring(m) .. "M" end
    if m > 0 then return tostring(m) .. "M " .. tostring(s) .. "S" end
    return tostring(s) .. "S"
end

local function rateColor(rate)
    if rate == nil or math.abs(rate) < CONFIG.idleThreshold then return C_MUTED end
    return rate > 0 and C_OK or C_BAD
end

local function percentColor(p)
    if p < 30 then return C_BAD end
    if p < 70 then return C_WARN end
    return C_OK
end

local function statusOf(d, g)
    if not d.stored then return "NO DATA" end
    if d.rate == nil then return "SAMPLING" end
    if d.rate > CONFIG.idleThreshold then return "CHARGING" end
    if d.rate < -CONFIG.idleThreshold then return "DISCHARGING" end
    if d.capacity > 0 and d.stored >= d.capacity then return "FULL" end
    if d.stored <= 0 then return g.emptyStatus or "EMPTY" end
    return "IDLE"
end

local function statusColors(status)
    if status == "CHARGING" then return colors.green, colors.white, C_OK end
    if status == "DISCHARGING" then return colors.red, colors.white, C_BAD end
    if status == "FULL" then return colors.cyan, colors.black, C_FULL end
    if status == "EMPTY" then return colors.orange, colors.black, C_WARN end
    if status == "NO DATA" then return colors.red, colors.white, C_BAD end
    if status == "SAMPLING" then return colors.lightGray, colors.black, C_MUTED end
    return colors.gray, colors.white, C_MUTED
end

local function wrapText(text, width)
    width = math.max(1, width)
    local lines = {}
    local line = ""
    for word in tostring(text or ""):gmatch("%S+") do
        while #word > width do
            if line ~= "" then
                lines[#lines + 1] = line
                line = ""
            end
            lines[#lines + 1] = word:sub(1, width)
            word = word:sub(width + 1)
        end
        if word ~= "" then
            if line == "" then
                line = word
            elseif #line + 1 + #word <= width then
                line = line .. " " .. word
            else
                lines[#lines + 1] = line
                line = word
            end
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if #lines == 0 then lines[1] = "" end
    return lines
end

local function fitText(s, width)
    s = tostring(s or "")
    if width <= 0 then return "" end
    if #s <= width then return s end
    if width <= 3 then return s:sub(1, width) end
    return s:sub(1, width - 3) .. "..."
end

local function makeUI(m)
    local w, h = m.getSize()
    local total = w * h
    local fc, ff, fb = {}, {}, {}
    local pc, pf, pb = {}, {}, {}

    local function idx(x, y)
        return (y - 1) * w + x
    end

    local function setBg(bg)
        if IS_COLOR then m.setBackgroundColor(bg) else m.setBackgroundColor(colors.black) end
    end

    local function setFg(fg)
        if IS_COLOR then m.setTextColor(fg) else m.setTextColor(colors.white) end
    end

    local function beginFrame()
        for i = 1, total do
            fc[i] = " "
            ff[i] = C_TEXT
            fb[i] = C_BG
        end
    end

    local function rect(x, y, ww, hh, bg)
        if ww <= 0 or hh <= 0 then return end
        local x1, y1 = clamp(x, 1, w), clamp(y, 1, h)
        local x2, y2 = clamp(x + ww - 1, 1, w), clamp(y + hh - 1, 1, h)
        if x2 < x1 or y2 < y1 then return end
        for yy = y1, y2 do
            for xx = x1, x2 do
                local i = idx(xx, yy)
                fc[i] = " "
                ff[i] = C_TEXT
                fb[i] = bg
            end
        end
    end

    local function text(x, y, s, fg, bg)
        if y < 1 or y > h then return end
        s = tostring(s or "")
        for n = 1, #s do
            local xx = x + n - 1
            if xx >= 1 and xx <= w then
                local i = idx(xx, y)
                fc[i] = s:sub(n, n)
                ff[i] = fg or C_TEXT
                if bg then fb[i] = bg end
            end
        end
    end

    local function field(x, y, ww, s, fg, bg, align)
        if ww <= 0 then return end
        s = fitText(s, ww)
        local pad = ww - #s
        local left = 0
        if align == "right" then
            left = pad
        elseif align == "center" then
            left = math.floor(pad / 2)
        end
        text(x, y, string.rep(" ", left) .. s .. string.rep(" ", pad - left), fg, bg)
    end

    local function invalidate()
        pc, pf, pb = {}, {}, {}
    end

    local function flush(force)
        for y = 1, h do
            local x = 1
            while x <= w do
                local i = idx(x, y)
                if force or pc[i] ~= fc[i] or pf[i] ~= ff[i] or pb[i] ~= fb[i] then
                    local fg, bg = ff[i], fb[i]
                    local startX = x
                    local chars = {}
                    while x <= w do
                        local j = idx(x, y)
                        local changed = force or pc[j] ~= fc[j] or pf[j] ~= ff[j] or pb[j] ~= fb[j]
                        if not changed or ff[j] ~= fg or fb[j] ~= bg then break end
                        chars[#chars + 1] = fc[j]
                        pc[j], pf[j], pb[j] = fc[j], ff[j], fb[j]
                        x = x + 1
                    end
                    setBg(bg)
                    setFg(fg)
                    m.setCursorPos(startX, y)
                    m.write(table.concat(chars))
                else
                    x = x + 1
                end
            end
        end
    end

    beginFrame()
    return {
        w = w, h = h, rect = rect, text = text, field = field,
        beginFrame = beginFrame, flush = flush, invalidate = invalidate,
    }
end

local function addHotspot(x, y, ww, hh, action)
    hotspots[#hotspots + 1] = { x1 = x, y1 = y, x2 = x + ww - 1, y2 = y + hh - 1, action = action }
end

local function hotspotAt(x, y)
    for _, hs in ipairs(hotspots) do
        if x >= hs.x1 and x <= hs.x2 and y >= hs.y1 and y <= hs.y2 then return hs.action end
    end
end

local function cardSurface(x, y, ww, hh, accentColor)
    if ww < 4 or hh < 3 then return end
    ui.rect(x, y, ww, hh, C_BG)
    ui.rect(x, y, ww, 1, C_DIV)
    ui.rect(x, y + hh - 1, ww, 1, C_DIV)
    ui.rect(x, y, 1, hh, C_DIV)
    ui.rect(x + ww - 1, y, 1, hh, C_DIV)
    ui.rect(x + 1, y + 1, ww - 2, hh - 2, C_INSET)
    ui.rect(x + 1, y + 1, 1, hh - 2, accentColor or C_ACCENT)
end

local function sectionTitle(x, y, ww, title, right)
    local avail = ww - 5
    if right and right ~= "" then
        ui.field(x + 3 + avail - #right, y, #right, right, C_MUTED, C_DIV)
        avail = avail - #right - 2
    end
    ui.field(x + 3, y, math.max(0, avail), string.upper(title or ""), C_TEXT, C_DIV)
end

local function drawBar(x, y, width, height, percent, fillColor)
    if width <= 0 then return end
    percent = clamp(percent or 0, 0, 100)
    local filled = clamp(math.floor(width * percent / 100 + 0.5), 0, width)
    if percent > 0 and filled == 0 then filled = 1 end
    if percent < 100 and filled == width and width > 1 then filled = width - 1 end
    if IS_COLOR then
        if filled > 0 then ui.rect(x, y, filled, height, fillColor) end
        if width - filled > 0 then ui.rect(x + filled, y, width - filled, height, C_DIV) end
    else
        for r = 0, height - 1 do
            ui.text(x, y + r, string.rep("#", filled) .. string.rep(".", width - filled), C_TEXT, C_INSET)
        end
    end
end

local function pillText(status)
    if IS_COLOR then return " " .. status .. " " end
    return "[" .. status .. "]"
end

local function drawPill(x, y, status)
    local bg, fg = statusColors(status)
    local s = pillText(status)
    ui.text(x, y, s, IS_COLOR and fg or C_TEXT, IS_COLOR and bg or C_INSET)
    return #s
end

local function kvRow(x, y, width, label, value, valueColor)
    if width <= 0 then return end
    value = tostring(value or "")
    if #value > width then value = fitText(value, width) end
    local labelW = width - #value - 1
    if labelW > 0 then ui.field(x, y, labelW, label, C_MUTED, C_INSET) end
    ui.text(x + width - #value, y, value, valueColor or C_TEXT, C_INSET)
end

local function drawButton(x, y, ww, hh, label, bg, fg, action)
    if ww <= 0 or hh <= 0 then return end
    ui.rect(x, y, ww, hh, bg)
    ui.field(x, y + math.floor(hh / 2), ww, label, fg or C_TEXT, bg, "center")
    if action then addHotspot(x, y, ww, hh, action) end
end

local function splitTwo(x, ww, gap)
    local leftW = math.floor((ww - gap) / 2)
    return leftW, x + leftW + gap, ww - gap - leftW
end

local function deviceIndex(name)
    return tonumber(name:match("_(%d+)$"))
end

local function scanDevices()
    local found = {}
    for _, g in ipairs(CONFIG.groups) do found[g.id] = {} end
    for _, name in ipairs(peripheral.getNames()) do
        if not (CONFIG.ignoreDirectSides and SIDES[name]) then
            local ptype = peripheral.getType(name) or ""
            for _, g in ipairs(CONFIG.groups) do
                if ptype:sub(1, #g.prefix) == g.prefix or name:sub(1, #g.prefix) == g.prefix then
                    table.insert(found[g.id], name)
                    break
                end
            end
        end
    end
    for _, list in pairs(found) do
        table.sort(list, function(a, b)
            local ia, ib = deviceIndex(a), deviceIndex(b)
            if ia and ib and ia ~= ib then return ia < ib end
            return a < b
        end)
    end
    return found
end

local function tryCall(name, method)
    for i, args in ipairs(CALL_ARGS) do
        local ok, v = pcall(peripheral.call, name, method, unpack(args))
        if ok and tonumber(v) then return tonumber(v), i end
    end
end

local function metaEnergy(meta)
    for _, key in ipairs({ "energy", "rf", "eu", "fe" }) do
        local e = meta[key]
        if type(e) == "table" then
            local s = tonumber(e.stored)
            local c = tonumber(e.capacity or e.max or e.maxStored)
            if s and c then return s, c end
        end
    end
end

local function buildReader(name, defaultUnit)
    local has = {}
    for _, m in ipairs(peripheral.getMethods(name) or {}) do has[m] = true end

    local function pick(list)
        for _, m in ipairs(list) do
            if has[m] then
                local v, argIndex = tryCall(name, m)
                if v then return m, CALL_ARGS[argIndex] end
            end
        end
    end

    local sm, sa = pick(STORED_METHODS)
    local cm, ca = pick(CAPACITY_METHODS)
    if sm and cm then
        local unit = defaultUnit
        if sm:find("EU") then unit = "EU" elseif sm:find("RF") then unit = "RF" end
        return {
            unit = unit,
            read = function()
                local ok1, s = pcall(peripheral.call, name, sm, unpack(sa))
                local ok2, c = pcall(peripheral.call, name, cm, unpack(ca))
                s, c = tonumber(s), tonumber(c)
                if ok1 and ok2 and s and c then return s, c end
            end,
        }
    end

    if has.getMetadata then
        return {
            unit = defaultUnit,
            read = function()
                local ok, meta = pcall(peripheral.call, name, "getMetadata")
                if ok and type(meta) == "table" then return metaEnergy(meta) end
            end,
        }
    end
end

local function sampleAll()
    local now = os.clock()
    local seen = {}
    local state = {}
    for _, g in ipairs(CONFIG.groups) do
        local list = {}
        for _, name in ipairs(devices[g.id] or {}) do
            seen[name] = true
            local reader = readers[name]
            if not reader then
                reader = buildReader(name, g.unit)
                readers[name] = reader
            end
            local index = deviceIndex(name)
            local d = {
                name = name,
                index = index,
                label = index and (g.single .. " " .. index) or (g.single .. " (" .. name .. ")"),
                tag = index and ("#" .. index) or name,
                unit = reader and reader.unit or g.unit,
            }
            local s, c
            if reader then s, c = reader.read() end
            if s and c then
                d.stored, d.capacity = s, c
                d.pct = c > 0 and clamp(s / c * 100, 0, 100) or 0
                local hist = history[name] or {}
                hist[#hist + 1] = { t = now, e = s }
                while #hist > 2 and now - hist[1].t > CONFIG.rateWindowSeconds do
                    table.remove(hist, 1)
                end
                history[name] = hist
                local first, last = hist[1], hist[#hist]
                if #hist >= 2 and last.t > first.t then
                    d.rate = (last.e - first.e) / ((last.t - first.t) * 20)
                end
            else
                readers[name] = nil
                history[name] = nil
            end
            list[#list + 1] = d
        end
        state[g.id] = list
    end
    for name in pairs(history) do
        if not seen[name] then history[name] = nil end
    end
    for name in pairs(readers) do
        if not seen[name] then readers[name] = nil end
    end
    return state
end

local function summarize(g, list)
    local sum = {
        count = #list, online = 0, unit = g.unit,
        stored = 0, capacity = 0, rate = 0,
        counts = { CHARGING = 0, DISCHARGING = 0, IDLE = 0, FULL = 0, EMPTY = 0, SAMPLING = 0, ["NO DATA"] = 0 },
    }
    local pending = false
    for _, d in ipairs(list) do
        local st = statusOf(d, g)
        sum.counts[st] = (sum.counts[st] or 0) + 1
        if d.stored then
            sum.online = sum.online + 1
            sum.stored = sum.stored + d.stored
            sum.capacity = sum.capacity + d.capacity
            sum.unit = d.unit
            if d.rate then sum.rate = sum.rate + d.rate else pending = true end
            if not sum.lowest or d.pct < sum.lowest.pct then sum.lowest = d end
        end
    end
    if sum.online == 0 then
        sum.stored, sum.capacity, sum.rate = nil, nil, nil
    else
        if pending then sum.rate = nil end
        sum.pct = sum.capacity > 0 and clamp(sum.stored / sum.capacity * 100, 0, 100) or 0
    end
    return sum
end

local function timeEstimate(sum)
    if not sum.stored or sum.rate == nil then return "TIME LEFT", "--", C_MUTED end
    if sum.rate < -CONFIG.idleThreshold then
        return "EMPTY IN", fmtDuration(sum.stored / (-sum.rate * 20)), C_BAD
    end
    if sum.rate > CONFIG.idleThreshold then
        if sum.capacity <= sum.stored then return "FULL IN", "NOW", C_FULL end
        return "FULL IN", fmtDuration((sum.capacity - sum.stored) / (sum.rate * 20)), C_OK
    end
    return "TIME LEFT", "STABLE", C_MUTED
end

local function clockText()
    if os.date then
        local ok, s = pcall(os.date, "%H:%M:%S")
        if ok and s then return s end
    end
    return textutils.formatTime(os.time(), true)
end

local function groupById(id)
    for _, g in ipairs(CONFIG.groups) do
        if g.id == id then return g end
    end
end

local function drawHeader()
    ui.rect(1, 1, W, 1, C_HEADER)
    ui.rect(1, 2, W, 1, C_DIV)
    ui.field(1, 1, W, CONFIG.title, C_TEXT, C_HEADER, "center")
    ui.text(2, 1, clockText(), C_HDR_TEXT, C_HEADER)
    ui.text(W - 5, 1, "ZelOS", C_BRAND, C_HEADER)
end

local function drawTabs(state)
    local tabs = { { id = "overview", label = "OVERVIEW", color = C_BRAND } }
    for _, g in ipairs(CONFIG.groups) do
        tabs[#tabs + 1] = { id = g.id, label = g.tab .. " (" .. #(state[g.id] or {}) .. ")", color = g.color }
    end
    local x0, total, gap = 2, W - 2, 1
    local each = math.floor((total - gap * (#tabs - 1)) / #tabs)
    local extra = total - gap * (#tabs - 1) - each * #tabs
    local x = x0
    for i, t in ipairs(tabs) do
        local ww = each + ((i <= extra) and 1 or 0)
        local active = currentTab == t.id
        local bg = active and t.color or C_DIV
        local label = t.label
        if not IS_COLOR and active then label = "> " .. label .. " <" end
        drawButton(x, 4, ww, 3, label, bg, active and C_TEXT or C_MUTED, "tab_" .. t.id)
        x = x + ww + gap
    end
end

local function drawGroupCard(x, y, ww, g, list)
    local hh = 9
    local sum = summarize(g, list)
    local ix, iw = x + 3, ww - 5
    cardSurface(x, y, ww, hh, g.color)
    local right = sum.count > 0 and (sum.online .. "/" .. sum.count .. " ONLINE") or ""
    sectionTitle(x, y, ww, g.title, right)

    if sum.count == 0 then
        local lines = wrapText(g.empty, iw)
        for i = 1, math.min(#lines, hh - 3) do
            ui.field(ix, y + 1 + i, iw, lines[i], C_MUTED, C_INSET)
        end
        return hh, sum
    end

    local status = statusOf(sum, g)
    drawPill(ix, y + 2, status)
    if sum.stored then
        local pctS = fmtPct(sum.pct)
        ui.text(ix + iw - #pctS, y + 2, pctS, percentColor(sum.pct), C_INSET)
        drawBar(ix, y + 3, iw, 2, sum.pct, percentColor(sum.pct))
        kvRow(ix, y + 5, iw, "STORED", fmtAmount(sum.stored) .. " / " .. fmtAmount(sum.capacity) .. " " .. sum.unit, C_TEXT)
        kvRow(ix, y + 6, iw, "NET RATE", fmtRate(sum.rate, sum.unit), rateColor(sum.rate))
        local label, value, color = timeEstimate(sum)
        kvRow(ix, y + 7, iw, label, value, color)
    else
        local lines = wrapText("None of these devices are reporting energy values.", iw)
        for i = 1, math.min(#lines, 4) do
            ui.field(ix, y + 3 + i, iw, lines[i], C_MUTED, C_INSET)
        end
    end
    return hh, sum
end

local function drawStatusColumn(x, y, width, rows, g, sum)
    ui.field(x, y, width, g.title, g.color, C_INSET)
    if rows < 2 then return end
    local items = {
        { "CHARGING", sum.counts.CHARGING, sum.counts.CHARGING > 0 and C_OK or C_MUTED },
        { "DISCHARGING", sum.counts.DISCHARGING, sum.counts.DISCHARGING > 0 and C_BAD or C_MUTED },
        { "IDLE / FULL", sum.counts.IDLE + sum.counts.FULL + sum.counts.SAMPLING, C_TEXT },
        { "EMPTY", sum.counts.EMPTY, sum.counts.EMPTY > 0 and C_WARN or C_MUTED },
        { "NO DATA", sum.counts["NO DATA"], sum.counts["NO DATA"] > 0 and C_BAD or C_MUTED },
    }
    if sum.lowest then
        items[#items + 1] = { "LOWEST", sum.lowest.tag .. " " .. fmtPct(sum.lowest.pct), percentColor(sum.lowest.pct) }
    end
    for i = 1, math.min(#items, rows - 1) do
        local it = items[i]
        kvRow(x, y + i, width, it[1], tostring(it[2]), it[3])
    end
end

local function drawOverview(state)
    local x, ww = 2, W - 2
    local y = 8
    local sums = {}
    for _, g in ipairs(CONFIG.groups) do
        local hh, sum = drawGroupCard(x, y, ww, g, state[g.id] or {})
        sums[#sums + 1] = sum
        y = y + hh + 1
    end
    local hh = H - y
    if hh < 5 or #CONFIG.groups < 2 then return end
    cardSurface(x, y, ww, hh, C_BRAND)
    sectionTitle(x, y, ww, "DEVICE STATUS")
    local ix, iw = x + 3, ww - 5
    local lw, rx, rw = splitTwo(ix, iw, 3)
    local rows = hh - 3
    drawStatusColumn(ix, y + 2, lw, rows, CONFIG.groups[1], sums[1])
    drawStatusColumn(rx, y + 2, rw, rows, CONFIG.groups[2], sums[2])
    ui.rect(rx - 2, y + 2, 1, rows, C_DIV)
end

local function entryLines(d, g, cw)
    local lines = {}
    if not d.stored then
        for _, n in ipairs(wrapText(d.label, cw)) do lines[#lines + 1] = { n, C_ACCENT } end
        lines[#lines + 1] = { "NO DATA", C_BAD }
        for _, s in ipairs(wrapText("Not reporting energy values.", cw)) do lines[#lines + 1] = { s, C_MUTED } end
        return lines
    end
    local pctS = fmtPct(d.pct)
    local names = wrapText(d.label, math.max(1, cw - #pctS - 1))
    for i, n in ipairs(names) do
        lines[#lines + 1] = { n, C_ACCENT, i == 1 and pctS or nil, percentColor(d.pct) }
    end
    lines[#lines + 1] = { bar = d.pct }
    local status = statusOf(d, g)
    local _, _, sc = statusColors(status)
    local rate = fmtRate(d.rate, d.unit)
    if #status + 1 + #rate <= cw then
        lines[#lines + 1] = { status, sc, rate, rateColor(d.rate) }
    else
        lines[#lines + 1] = { status, sc }
        lines[#lines + 1] = { rate, rateColor(d.rate) }
    end
    local amount = fmtAmount(d.stored) .. " / " .. fmtAmount(d.capacity) .. " " .. d.unit
    for _, s in ipairs(wrapText(amount, cw)) do lines[#lines + 1] = { s, C_MUTED } end
    return lines
end

local function paginate(entries, cols, listH)
    local rowsOfEntries = {}
    for i = 1, #entries, cols do
        local row, height = {}, 0
        for c = 0, cols - 1 do
            local e = entries[i + c]
            if e then
                row[#row + 1] = e
                if #e > height then height = #e end
            end
        end
        rowsOfEntries[#rowsOfEntries + 1] = { items = row, height = height }
    end
    local pages, cur, used = {}, {}, 0
    for _, r in ipairs(rowsOfEntries) do
        local need = r.height + ((#cur > 0) and 1 or 0)
        if #cur > 0 and used + need > listH then
            pages[#pages + 1] = cur
            cur, used = {}, 0
            need = r.height
        end
        cur[#cur + 1] = r
        used = used + need
    end
    if #cur > 0 or #pages == 0 then pages[#pages + 1] = cur end
    return pages
end

local function drawEntry(x, y, cw, lines, maxY)
    for i, ln in ipairs(lines) do
        local yy = y + i - 1
        if yy > maxY then return end
        if ln.bar then
            drawBar(x, yy, cw, 1, ln.bar, percentColor(ln.bar))
        else
            local right = ln[3]
            local leftW = cw
            if right then
                leftW = cw - #right - 1
                ui.text(x + cw - #right, yy, right, ln[4] or C_TEXT, C_INSET)
            end
            ui.field(x, yy, math.max(0, leftW), ln[1], ln[2] or C_TEXT, C_INSET)
        end
    end
end

local function drawGroupPage(g, state)
    local list = state[g.id] or {}
    local x, ww = 2, W - 2
    local hh = drawGroupCard(x, 8, ww, g, list)
    local y = 8 + hh + 1
    local cardH = H - y
    if cardH < 5 then return end

    local ix, iw = x + 3, ww - 5
    local cols = math.max(1, math.floor((iw + 2) / 24))
    local gap = 2
    local cw = math.floor((iw - gap * (cols - 1)) / cols)

    local entries = {}
    for _, d in ipairs(list) do entries[#entries + 1] = entryLines(d, g, cw) end

    local listH = cardH - 3
    local pages = paginate(entries, cols, listH)
    if #pages > 1 then
        listH = cardH - 4
        pages = paginate(entries, cols, listH)
    end
    pageCountByTab[g.id] = #pages
    local page = clamp(pageByTab[g.id] or 1, 1, #pages)
    pageByTab[g.id] = page

    cardSurface(x, y, ww, cardH, g.color)
    sectionTitle(x, y, ww, g.single .. " DETAILS", #pages > 1 and ("PAGE " .. page .. "/" .. #pages) or "")

    local top = y + 2
    local maxY = top + listH - 1
    if #list == 0 then
        local lines = wrapText(g.empty, iw)
        for i = 1, math.min(#lines, listH) do
            ui.field(ix, top + i - 1, iw, lines[i], C_MUTED, C_INSET, "center")
        end
    else
        local yy = top
        for _, row in ipairs(pages[page]) do
            for c, e in ipairs(row.items) do
                drawEntry(ix + (c - 1) * (cw + gap), yy, cw, e, maxY)
            end
            yy = yy + row.height + 1
        end
        for c = 1, cols - 1 do
            ui.rect(ix + c * (cw + gap) - 1 - math.floor(gap / 2), top, 1, listH, C_DIV)
        end
    end

    if #pages > 1 then
        local py = y + cardH - 2
        local bw = 8
        drawButton(ix, py, bw, 1, "< PREV", C_DIV, C_TEXT, "prev")
        drawButton(ix + iw - bw, py, bw, 1, "NEXT >", C_DIV, C_TEXT, "next")
        ui.field(ix + bw, py, iw - bw * 2, "PAGE " .. page .. " OF " .. #pages, C_MUTED, C_INSET, "center")
    end
end

local function drawTooSmall()
    ui.rect(1, 1, W, H, C_BG)
    local lines = wrapText("Monitor too small. Use at least a 3x3 advanced monitor.", math.max(1, W - 2))
    for i, l in ipairs(lines) do ui.field(2, i + 1, W - 2, l, C_BAD, C_BG) end
end

local function draw(state)
    hotspots = {}
    ui.beginFrame()
    if W < 40 or H < 30 then
        drawTooSmall()
    else
        drawHeader()
        drawTabs(state)
        local g = groupById(currentTab)
        if g then drawGroupPage(g, state) else drawOverview(state) end
    end
    ui.flush(forceRedraw)
    forceRedraw = false
end

local function findMonitor()
    if CONFIG.monitorName then
        if peripheral.isPresent(CONFIG.monitorName) and peripheral.getType(CONFIG.monitorName) == "monitor" then
            return CONFIG.monitorName
        end
        return nil
    end
    local fallback
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            if name:sub(1, 8) == "monitor_" then return name end
            fallback = fallback or name
        end
    end
    return fallback
end

local function printStatus(lines)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    for _, l in ipairs(lines) do print(l) end
end

local function setupMonitor()
    applyPalette(mon)
    pcall(mon.setTextScale, CONFIG.textScale)
    W, H = mon.getSize()
    ui = makeUI(mon)
    mon.setBackgroundColor(colors.black)
    mon.clear()
    forceRedraw = true
end

local function attachMonitor()
    local name = findMonitor()
    if not name then
        mon, monName = nil, nil
        return false
    end
    monName = name
    mon = peripheral.wrap(name)
    setupMonitor()
    return true
end

local function applyAction(action)
    local tab = action:match("^tab_(.+)$")
    if tab then
        currentTab = tab
        pageByTab[tab] = 1
        return
    end
    local count = pageCountByTab[currentTab] or 1
    local page = pageByTab[currentTab] or 1
    if action == "next" then
        pageByTab[currentTab] = (page % count) + 1
    elseif action == "prev" then
        pageByTab[currentTab] = ((page - 2) % count) + 1
    end
end

local function terminalInfo()
    printStatus({
        "ZelOS Power Monitor",
        "",
        "Monitor: " .. tostring(monName) .. " (" .. W .. "x" .. H .. ")",
        "Solar generators: " .. #(devices.solar or {}),
        "Energy cells:     " .. #(devices.cell or {}),
        "",
        "Hold Ctrl+T to stop.",
    })
end

local function run()
    local timer = os.startTimer(0)
    local state
    local lastSig
    local waitingShown = false

    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "timer" and a == timer then
            if not mon then attachMonitor() end
            if mon then
                waitingShown = false
                devices = scanDevices()
                state = sampleAll()
                local sig = tostring(monName)
                for _, g in ipairs(CONFIG.groups) do sig = sig .. ";" .. #(devices[g.id] or {}) end
                if sig ~= lastSig then
                    lastSig = sig
                    terminalInfo()
                end
                if currentTab ~= "overview" then
                    pageClock = pageClock + CONFIG.refreshSeconds
                    idleClock = idleClock + CONFIG.refreshSeconds
                    if CONFIG.pageSeconds > 0 and pageClock >= CONFIG.pageSeconds then
                        pageClock = 0
                        local count = pageCountByTab[currentTab] or 1
                        if count > 1 then pageByTab[currentTab] = ((pageByTab[currentTab] or 1) % count) + 1 end
                    end
                    if CONFIG.returnToOverviewSeconds > 0 and idleClock >= CONFIG.returnToOverviewSeconds then
                        currentTab = "overview"
                        idleClock = 0
                    end
                end
                draw(state)
            elseif not waitingShown then
                waitingShown = true
                printStatus({
                    "ZelOS Power Monitor",
                    "",
                    "No monitor found on the wired network.",
                    "Connect a monitor with a wired modem and",
                    "right click the modem to attach it.",
                    "",
                    "Waiting...",
                })
            end
            timer = os.startTimer(CONFIG.refreshSeconds)
        elseif ev == "monitor_touch" and a == monName and state then
            local action = hotspotAt(b, c)
            if action then
                applyAction(action)
                pageClock = 0
                idleClock = 0
                draw(state)
            end
        elseif ev == "monitor_resize" and a == monName and mon then
            local nw, nh = mon.getSize()
            if nw ~= W or nh ~= H then
                setupMonitor()
                if state then draw(state) end
            end
        elseif ev == "peripheral_detach" and a == monName then
            mon, monName = nil, nil
        end
    end
end

while true do
    local ok, err = pcall(run)
    if not ok then
        if tostring(err):find("Terminated") then
            if mon then
                mon.setBackgroundColor(colors.black)
                mon.clear()
            end
            printStatus({ "ZelOS Power Monitor stopped." })
            break
        end
        printStatus({ "[Power Monitor Error]", tostring(err), "", "Restarting in 3 seconds..." })
        mon, monName = nil, nil
        sleep(3)
    end
end
