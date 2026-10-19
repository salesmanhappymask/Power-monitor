local CONFIG = {
    title = "Power Monitor",
    pageTitle = "Energy Overview",
    monitorName = nil,
    refreshSeconds = 1,
    rateWindowSeconds = 10,
    pageSeconds = 6,
    idleThreshold = 0.05,
    textScales = { 1, 0.5 },
    groups = {
        {
            id = "solar",
            prefix = "advanced_solar_generator",
            title = "Solar Generators",
            single = "Solar Generator",
            totalLabel = "All Solar Generators",
            unit = "EU",
            empty = "No advanced solar generators were found on the wired network.",
        },
        {
            id = "cell",
            prefix = "cofh_thermalexpansion_energycell",
            title = "Energy Cells",
            single = "Energy Cell",
            totalLabel = "All Energy Cells",
            unit = "RF",
            empty = "No Thermal Expansion energy cells were found on the wired network.",
        },
    },
}

local unpack = table.unpack or unpack

local STORED_METHODS = {
    "getEnergyStored", "getEUStored", "getEnergy", "getStored",
    "getStoredEnergy", "getRFStored", "getStoredEU",
}

local CAPACITY_METHODS = {
    "getMaxEnergyStored", "getEUCapacity", "getEnergyCapacity", "getMaxEnergy",
    "getCapacity", "getMaxStoredEnergy", "getRFCapacity", "getMaxEU",
}

local CALL_ARGS = { {}, { "unknown" }, { "north" }, { "up" } }

local mon, monName
local ui
local layout
local needLayout = true
local pageTick = 0
local devices = {}
local readers = {}
local history = {}

local IS_COLOR = false
local C_BG, C_HEADER, C_DIV, C_INSET, C_ACCENT, C_TEXT, C_MUTED, C_BRAND, C_BAR_EMPTY

local function applyPalette(m)
    IS_COLOR = (m.isColor and m.isColor()) or false
    C_BG        = colors.black
    C_HEADER    = IS_COLOR and colors.lightGray or colors.black
    C_DIV       = IS_COLOR and colors.gray or colors.black
    C_INSET     = colors.black
    C_ACCENT    = IS_COLOR and colors.cyan or colors.white
    C_TEXT      = colors.white
    C_MUTED     = IS_COLOR and colors.lightGray or colors.white
    C_BRAND     = IS_COLOR and colors.blue or colors.white
    C_BAR_EMPTY = IS_COLOR and colors.gray or colors.black
end

local STATUS_STYLE = {
    CHARGING      = { colors.green, colors.white },
    DISCHARGING   = { colors.red, colors.white },
    IDLE          = { colors.gray, colors.white },
    FULL          = { colors.cyan, colors.black },
    EMPTY         = { colors.orange, colors.black },
    SAMPLING      = { colors.lightGray, colors.black },
    ["NO DATA"]   = { colors.red, colors.white },
}

local function clamp(n, a, b)
    if n < a then return a elseif n > b then return b else return n end
end

local function toBlit(c)
    if colors.toBlit then return colors.toBlit(c) end
    local i = math.floor(math.log(c) / math.log(2) + 0.5)
    return string.sub("0123456789abcdef", i + 1, i + 1)
end

local function fgHex(c)
    if IS_COLOR then return toBlit(c) end
    return "0"
end

local function bgHex(c)
    if IS_COLOR then return toBlit(c) end
    return "f"
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
        if line == "" then
            line = word
        elseif #line + 1 + #word <= width then
            line = line .. " " .. word
        else
            lines[#lines + 1] = line
            line = word
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if #lines == 0 then lines[1] = "" end
    return lines
end

local function makeUI(m)
    local w, h = m.getSize()
    local cache = {}

    local function setBg(bg)
        if IS_COLOR then m.setBackgroundColor(bg) else m.setBackgroundColor(colors.black) end
    end
    local function setFg(fg)
        if IS_COLOR then m.setTextColor(fg) else m.setTextColor(colors.white) end
    end

    local function rect(x, y, ww, hh, bg)
        if ww <= 0 or hh <= 0 then return end
        local x1 = clamp(x, 1, w)
        local y1 = clamp(y, 1, h)
        local x2 = clamp(x + ww - 1, 1, w)
        local y2 = clamp(y + hh - 1, 1, h)
        if x2 < x1 or y2 < y1 then return end
        setBg(bg)
        local line = string.rep(" ", x2 - x1 + 1)
        for yy = y1, y2 do
            m.setCursorPos(x1, yy)
            m.write(line)
        end
    end

    local function field(key, x, y, ww, s, fg, bg)
        if ww <= 0 or y < 1 or y > h then return end
        s = tostring(s or "")
        if #s > ww then s = s:sub(1, ww) end
        local out = s .. string.rep(" ", ww - #s)

        local k1, k2, k3 = key .. "_out", key .. "_fg", key .. "_bg"
        if cache[k1] == out and cache[k2] == fg and cache[k3] == bg then return end
        setBg(bg or colors.black)
        setFg(fg or colors.white)
        m.setCursorPos(x, y)
        m.write(out)
        cache[k1], cache[k2], cache[k3] = out, fg, bg
    end

    local function row(key, x, y, r)
        if y < 1 or y > h or x > w then return end
        local sig = r.t .. "|" .. r.f .. "|" .. r.b
        if cache[key] == sig then return end
        m.setCursorPos(x, y)
        if m.blit then
            m.blit(r.t, r.f, r.b)
        else
            local i, n = 1, #r.t
            while i <= n do
                local fc, bc = r.f:sub(i, i), r.b:sub(i, i)
                local j = i
                while j < n and r.f:sub(j + 1, j + 1) == fc and r.b:sub(j + 1, j + 1) == bc do
                    j = j + 1
                end
                m.setTextColor(2 ^ tonumber(fc, 16))
                m.setBackgroundColor(2 ^ tonumber(bc, 16))
                m.write(r.t:sub(i, j))
                i = j + 1
            end
        end
        cache[key] = sig
    end

    local function clearAll()
        setBg(C_BG)
        setFg(C_TEXT)
        m.clear()
        cache = {}
    end

    return { w = w, h = h, rect = rect, field = field, row = row, clearAll = clearAll }
end

local function cardSurface(x, y, ww, hh, accentColor)
    ui.rect(x, y, ww, hh, C_BG)
    ui.rect(x, y, ww, 1, C_DIV)
    ui.rect(x, y + hh - 1, ww, 1, C_DIV)
    ui.rect(x, y, 1, hh, C_DIV)
    ui.rect(x + ww - 1, y, 1, hh, C_DIV)
    ui.rect(x + 1, y + 1, ww - 2, hh - 2, C_INSET)
    ui.rect(x + 1, y + 1, 1, hh - 2, accentColor or C_ACCENT)
end

local function drawHeader(title)
    local w = ui.w
    ui.rect(1, 1, w, 1, C_HEADER)
    ui.rect(1, 2, w, 1, C_DIV)
    local brand = "ZelOS"
    ui.field("hdr_brand", w - #brand + 1, 1, #brand, brand, C_BRAND, C_HEADER)
    local maxTitle = math.max(1, w - #brand - 2)
    if #title > maxTitle then title = title:sub(1, maxTitle) end
    local tx = 1 + math.floor((w - #title) / 2)
    if tx + #title - 1 > w - #brand - 1 then tx = math.max(1, w - #brand - #title) end
    ui.field("hdr_title", tx, 1, #title, title, C_TEXT, C_HEADER)
end

local function centerTextX(areaX, areaW, text)
    return areaX + math.max(0, math.floor((areaW - #text) / 2))
end

local SUFFIXES = { { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }

local function fmtNum(n)
    local a = math.abs(n)
    for _, s in ipairs(SUFFIXES) do
        if a >= s[1] then
            local v = n / s[1]
            local av = math.abs(v)
            if av >= 100 then return string.format("%.0f%s", v, s[2]) end
            if av >= 10 then return string.format("%.1f%s", v, s[2]) end
            return string.format("%.2f%s", v, s[2])
        end
    end
    if a >= 100 or a == math.floor(a) then return string.format("%.0f", n) end
    return string.format("%.1f", n)
end

local function rateText(rate, unit)
    if rate == nil then return "-- " .. unit .. "/t" end
    if math.abs(rate) < CONFIG.idleThreshold then return "0 " .. unit .. "/t" end
    local sign = rate > 0 and "+" or ""
    return sign .. fmtNum(rate) .. " " .. unit .. "/t"
end

local function rateColor(rate)
    if rate == nil or math.abs(rate) < CONFIG.idleThreshold then return C_MUTED end
    return rate > 0 and colors.lime or colors.red
end

local function statusOf(d)
    if not d.stored then return "NO DATA" end
    if d.rate == nil then return "SAMPLING" end
    if d.rate > CONFIG.idleThreshold then return "CHARGING" end
    if d.rate < -CONFIG.idleThreshold then return "DISCHARGING" end
    if d.capacity > 0 and d.stored >= d.capacity then return "FULL" end
    if d.stored <= 0 then return "EMPTY" end
    return "IDLE"
end

local function newRow(w, bg)
    w = math.max(1, w)
    return {
        w = w,
        t = string.rep(" ", w),
        f = string.rep(fgHex(C_TEXT), w),
        b = string.rep(bgHex(bg or C_INSET), w),
    }
end

local function put(r, x, s, fg, bg)
    s = tostring(s or "")
    if x < 1 then
        s = s:sub(2 - x)
        x = 1
    end
    if x > r.w or s == "" then return r end
    s = s:sub(1, r.w - x + 1)
    local n = #s
    local e = x + n
    r.t = r.t:sub(1, x - 1) .. s .. r.t:sub(e)
    r.f = r.f:sub(1, x - 1) .. string.rep(fgHex(fg or C_TEXT), n) .. r.f:sub(e)
    if bg then
        r.b = r.b:sub(1, x - 1) .. string.rep(bgHex(bg), n) .. r.b:sub(e)
    end
    return r
end

local function textRow(w, s, fg)
    return put(newRow(w), 1, s, fg or C_TEXT)
end

local function titleRow(w, s)
    local r = newRow(w, C_DIV)
    if #s > w then s = s:sub(1, w) end
    return put(r, math.floor((w - #s) / 2) + 1, s, C_TEXT, C_DIV)
end

local function pillText(status)
    if IS_COLOR then return " " .. status .. " " end
    return "[" .. status .. "]"
end

local function putPill(r, x, status)
    local st = STATUS_STYLE[status] or STATUS_STYLE.IDLE
    return put(r, x, pillText(status), st[2], st[1])
end

local function barFill(frac)
    if frac >= 0.6 then return colors.lime, colors.black end
    if frac >= 0.25 then return colors.yellow, colors.black end
    return colors.red, colors.white
end

local function barRow(w, frac, label)
    w = math.max(1, w)
    frac = clamp(frac, 0, 1)
    local fill, fillFg = barFill(frac)
    local filled = math.floor(frac * w + 0.5)
    if frac > 0 and filled < 1 then filled = 1 end
    if frac < 1 and filled >= w and w > 1 then filled = w - 1 end
    label = " " .. label .. " "
    if #label > w then label = label:sub(1, w) end
    local lx = math.floor((w - #label) / 2) + 1
    local t, f, b = {}, {}, {}
    for i = 1, w do
        local on = i <= filled
        local ch
        if i >= lx and i < lx + #label then
            ch = label:sub(i - lx + 1, i - lx + 1)
        elseif IS_COLOR then
            ch = " "
        else
            ch = on and "#" or "."
        end
        t[i] = ch
        f[i] = fgHex(on and fillFg or colors.white)
        b[i] = bgHex(on and fill or C_BAR_EMPTY)
    end
    return { w = w, t = table.concat(t), f = table.concat(f), b = table.concat(b) }
end

local function deviceBlock(d, w, labelColor)
    local rows = {}
    for _, ln in ipairs(wrapText(d.label, w)) do
        rows[#rows + 1] = textRow(w, ln, labelColor)
    end
    local status = statusOf(d)
    if not d.stored then
        rows[#rows + 1] = putPill(newRow(w), 1, status)
        for _, ln in ipairs(wrapText("This peripheral is not reporting energy values.", w)) do
            rows[#rows + 1] = textRow(w, ln, C_MUTED)
        end
    else
        local frac = d.capacity > 0 and (d.stored / d.capacity) or 0
        rows[#rows + 1] = barRow(w, frac, string.format("%.1f%%", clamp(frac, 0, 1) * 100))
        local pill = pillText(status)
        local rate = rateText(d.rate, d.unit)
        if #pill + 1 + #rate <= w then
            local r = putPill(newRow(w), 1, status)
            rows[#rows + 1] = put(r, w - #rate + 1, rate, rateColor(d.rate))
        else
            rows[#rows + 1] = putPill(newRow(w), 1, status)
            for _, ln in ipairs(wrapText(rate, w)) do
                rows[#rows + 1] = textRow(w, ln, rateColor(d.rate))
            end
        end
        local amount = fmtNum(d.stored) .. " / " .. fmtNum(d.capacity) .. " " .. d.unit
        for _, ln in ipairs(wrapText(amount, w)) do
            rows[#rows + 1] = textRow(w, ln, C_MUTED)
        end
    end
    rows[#rows + 1] = newRow(w)
    return rows
end

local function summarize(g, list)
    local t = { label = g.totalLabel, unit = g.unit, stored = 0, capacity = 0, rate = 0 }
    local readable, pending = 0, false
    for _, d in ipairs(list) do
        if d.stored then
            readable = readable + 1
            t.stored = t.stored + d.stored
            t.capacity = t.capacity + d.capacity
            t.unit = d.unit
            if d.rate then t.rate = t.rate + d.rate else pending = true end
        end
    end
    if readable == 0 then
        t.stored, t.capacity, t.rate = nil, nil, nil
    elseif pending then
        t.rate = nil
    end
    if readable < #list then
        t.label = t.label .. " (" .. readable .. "/" .. #list .. " reporting)"
    end
    return t
end

local function buildSection(g, list, w, bodyH)
    local sec = { g = g, count = #list, header = { newRow(w) }, pages = {} }
    if #list == 0 then
        for _, ln in ipairs(wrapText(g.empty, w)) do
            sec.header[#sec.header + 1] = textRow(w, ln, C_MUTED)
        end
        sec.pages[1] = {}
        return sec
    end

    local total = deviceBlock(summarize(g, list), w, C_TEXT)
    total[#total] = textRow(w, string.rep("-", w), C_DIV)
    for _, r in ipairs(total) do sec.header[#sec.header + 1] = r end

    local avail = bodyH - 1 - #sec.header
    local cur, used = {}, 0
    for _, d in ipairs(list) do
        local block = deviceBlock(d, w, C_ACCENT)
        if #cur > 0 and used + #block - 1 > avail then
            sec.pages[#sec.pages + 1] = cur
            cur, used = {}, 0
        end
        cur[#cur + 1] = block
        used = used + #block
    end
    sec.pages[#sec.pages + 1] = cur
    return sec
end

local function sectionRows(sec, page, w)
    local title = sec.g.title .. " (" .. sec.count .. ")"
    if #sec.pages > 1 then
        local tag = page .. "/" .. #sec.pages
        title = title .. "  " .. tag
        if #title > w then title = sec.g.title .. " " .. tag end
        if #title > w then title = sec.g.title:sub(1, math.max(1, w - #tag - 1)) .. " " .. tag end
    end
    local rows = { titleRow(w, title) }
    for _, r in ipairs(sec.header) do rows[#rows + 1] = r end
    for _, block in ipairs(sec.pages[page] or {}) do
        for _, r in ipairs(block) do rows[#rows + 1] = r end
    end
    return rows
end

local function computeLayout(W, H)
    local L = { W = W, H = H }
    L.cx, L.cy = 2, 4
    L.cw = W - 2
    L.ch = math.max(6, H - L.cy)
    L.innerX = L.cx + 3
    L.innerY = L.cy + 1
    L.innerW = math.max(1, L.cw - 4)
    L.footerY = L.cy + L.ch - 2
    L.bodyY = L.innerY + 2
    L.bodyH = math.max(1, L.footerY - 1 - L.bodyY)
    if L.innerW >= 44 then
        local splitX = L.innerX + math.floor(L.innerW / 2)
        local rightX = splitX + 2
        L.splitX = splitX
        L.columns = {
            { x = L.innerX, w = splitX - L.innerX - 1 },
            { x = rightX, w = L.innerX + L.innerW - rightX },
        }
    else
        L.columns = { { x = L.innerX, w = L.innerW } }
    end
    return L
end

local function buildSections(state, L)
    local secs = {}
    for gi, g in ipairs(CONFIG.groups) do
        local col = L.columns[gi] or L.columns[1]
        if #L.columns == 1 then col = L.columns[1] end
        secs[gi] = buildSection(g, state[g.id] or {}, col.w, L.bodyH)
    end
    return secs
end

local function chooseLayout(state)
    local scales = CONFIG.textScales
    for i, s in ipairs(scales) do
        pcall(mon.setTextScale, s)
        local W, H = mon.getSize()
        local L = computeLayout(W, H)
        if i == #scales then return L end
        if #L.columns >= #CONFIG.groups and L.bodyH >= 10 then
            local fits = true
            for _, sec in ipairs(buildSections(state, L)) do
                if #sec.pages > 1 then fits = false end
            end
            if fits then return L end
        end
    end
end

local function drawStatics()
    local L = layout
    ui.clearAll()
    drawHeader(CONFIG.title)
    cardSurface(L.cx, L.cy, L.cw, L.ch, C_ACCENT)
    local barX, barW = L.innerX - 1, L.innerW + 1
    ui.rect(barX, L.innerY, barW, 1, C_BRAND)
    local t = CONFIG.pageTitle
    if #t > barW then t = t:sub(1, barW) end
    ui.field("page_bar", centerTextX(barX, barW, t), L.innerY, #t, t, C_TEXT, C_BRAND)
    if L.splitX then ui.rect(L.splitX, L.bodyY, 1, L.bodyH, C_DIV) end
end

local function drawColumn(key, col, rows)
    for r = 1, layout.bodyH do
        ui.row(key .. "_" .. r, col.x, layout.bodyY + r - 1, rows[r] or newRow(col.w))
    end
end

local function clockText()
    if os.date then
        local ok, s = pcall(os.date, "%H:%M:%S")
        if ok and s then return s end
    end
    return textutils.formatTime(os.time(), true)
end

local function drawFooter(paged, count)
    local w = layout.innerW
    local right = paged and "Touch for next page" or (count .. (count == 1 and " device" or " devices"))
    local left = "Updated " .. clockText()
    local r = newRow(w)
    if paged and #left + 1 + #right > w then right = "Tap for more" end
    if #left + 1 + #right > w then right = "" end
    put(r, 1, left, C_MUTED)
    if right ~= "" then put(r, w - #right + 1, right, C_MUTED) end
    ui.row("footer", layout.innerX, layout.footerY, r)
end

local function render(state)
    local L = layout
    local secs = buildSections(state, L)
    local paged = false
    local count = 0
    for _, g in ipairs(CONFIG.groups) do count = count + #(state[g.id] or {}) end

    if #L.columns >= #secs then
        for i, sec in ipairs(secs) do
            local page = (pageTick % #sec.pages) + 1
            if #sec.pages > 1 then paged = true end
            drawColumn("col" .. i, L.columns[i], sectionRows(sec, page, L.columns[i].w))
        end
    else
        local views = {}
        for _, sec in ipairs(secs) do
            for p = 1, #sec.pages do views[#views + 1] = { sec, p } end
        end
        local v = views[(pageTick % #views) + 1]
        paged = #views > 1
        drawColumn("col1", L.columns[1], sectionRows(v[1], v[2], L.columns[1].w))
    end
    drawFooter(paged, count)
end

local function deviceIndex(name)
    return tonumber(name:match("_(%d+)$"))
end

local function scanDevices()
    local found = {}
    for _, g in ipairs(CONFIG.groups) do found[g.id] = {} end
    for _, name in ipairs(peripheral.getNames()) do
        local ptype = peripheral.getType(name) or ""
        for _, g in ipairs(CONFIG.groups) do
            if ptype:sub(1, #g.prefix) == g.prefix or name:sub(1, #g.prefix) == g.prefix then
                table.insert(found[g.id], name)
                break
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
        if ok and type(v) == "number" then return v, i end
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
                if ok1 and ok2 and type(s) == "number" and type(c) == "number" then return s, c end
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
            local idx = deviceIndex(name)
            local d = {
                name = name,
                label = idx and (g.single .. " " .. idx) or name,
                unit = reader and reader.unit or g.unit,
            }
            local s, c
            if reader then s, c = reader.read() end
            if s and c then
                d.stored, d.capacity = s, c
                local h = history[name] or {}
                h[#h + 1] = { t = now, e = s }
                while #h > 2 and now - h[1].t > CONFIG.rateWindowSeconds do
                    table.remove(h, 1)
                end
                history[name] = h
                local first, last = h[1], h[#h]
                if #h >= 2 and last.t > first.t then
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

local function deviceSignature()
    local parts = {}
    for _, g in ipairs(CONFIG.groups) do
        parts[#parts + 1] = table.concat(devices[g.id] or {}, ",")
    end
    return table.concat(parts, ";")
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

local function attachMonitor()
    local name = findMonitor()
    if not name then
        monName, mon = nil, nil
        return false
    end
    monName = name
    mon = peripheral.wrap(name)
    needLayout = true
    return true
end

local function relayout(state)
    applyPalette(mon)
    layout = chooseLayout(state)
    ui = makeUI(mon)
    drawStatics()
    needLayout = false
    local solar = #(devices.solar or {})
    local cells = #(devices.cell or {})
    printStatus({
        "ZelOS Power Monitor",
        "",
        "Monitor:  " .. monName .. " (" .. layout.W .. "x" .. layout.H .. ")",
        "Solar generators: " .. solar,
        "Energy cells:     " .. cells,
        "",
        "Hold Ctrl+T to stop.",
    })
end

local function run()
    local timer = os.startTimer(0)
    local sig
    local state
    local pageClock = 0
    local waitingShown = false

    while true do
        local ev, a = os.pullEvent()
        if ev == "timer" and a == timer then
            if not mon then attachMonitor() end
            if mon then
                waitingShown = false
                devices = scanDevices()
                state = sampleAll()
                local s = deviceSignature()
                if s ~= sig or needLayout then
                    sig = s
                    relayout(state)
                end
                pageClock = pageClock + CONFIG.refreshSeconds
                if pageClock >= CONFIG.pageSeconds then
                    pageClock = 0
                    pageTick = pageTick + 1
                end
                render(state)
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
        elseif ev == "monitor_touch" and a == monName and state and layout then
            pageTick = pageTick + 1
            pageClock = 0
            render(state)
        elseif ev == "monitor_resize" and a == monName and mon then
            local W, H = mon.getSize()
            if not layout or W ~= layout.W or H ~= layout.H then needLayout = true end
        elseif ev == "peripheral_detach" and a == monName then
            mon, monName, layout = nil, nil, nil
            needLayout = true
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
        mon, monName, layout = nil, nil, nil
        needLayout = true
        sleep(3)
    end
end
