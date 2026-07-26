--[[--------------------------------------------------------------------------
	FF Tracker - Window (display + per-window config)

	Each aura is a big spell icon (flashes near expiry, glows gold while expired)
	with the countdown centered in it, then a full cooldown bar (80% opacity, drains
	only, no background) behind the source name stacked over the target name. Items
	stack; a window grows down (fixed top, header on top) or up (fixed bottom, header
	on the bottom), soonest-to-expire nearest the header, and aligns left or right
	(the icon and its bar mirror). CollectSorted + the entry helpers below feed the
	layout in RebuildIcons.

	Names are colored by class (yours / another player's), bright red for an enemy
	mob, bright green for a friendly one; the colors come from Core. The countdown
	is green, red in its final seconds, and red/purple when frozen.

	Window state lives in M.db.windows[i]:
	  { point, width, locked, growUp, rightAlign, rowScale, fontSize,
	    barMax (seconds, nil = longest), onlyMine, sound5/soundExpire (+ *Id),
	    spells = { [key] = { enabled, color } } }
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local M = ns.modules.ff

local PAD, ROW_SP, HEADER_H = 6, 2, 18 -- ROW_SP = vertical gap between stacked items
local MIN_W, MAX_W, DEFAULT_W = 120, 500, 315
local COL_W, COL_GAP = 185, 8 -- gear config panel: 3 columns, no scroll
local CLASS_GAP = 16 -- extra space above a class header that isn't first in its column
-- Fixed gear-menu column layout. Empty classes and the wrong-faction class are
-- skipped; a class reappears automatically if it gains a spell.
local COLUMN_CLASSES = {
	{ "WARRIOR", "DRUID" },
	{ "WARLOCK", "ROGUE" },
	{ "MAGE", "HUNTER", "PRIEST", "SHAMAN", "PALADIN" },
}
local OPT_H = 280 -- vertical space the per-window options block takes atop the gear list
local sliderSeq = 0 -- for unique slider frame names
local BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"
local BACKDROP = {
	bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

M.windows = M.windows or {}

-- Built-in alert sounds for the optional 5s / expiry options (SoundKit ids).
local SOUNDS = {}
do
	local sk = SOUNDKIT or {}
	local function add(name, id) if id then SOUNDS[#SOUNDS + 1] = { name = name, id = id } end end
	add("Raid Warning", sk.RAID_WARNING or 8959)
	add("Ready Check", sk.READY_CHECK or 8960)
	add("Alarm Clock", sk.ALARM_CLOCK_WARNING_3 or 12867)
	add("Auction Bell", sk.AUCTION_WINDOW_OPEN or 5274)
	add("Whisper", sk.TELL_MESSAGE or 3081)
end
local function soundName(id)
	for _, s in ipairs(SOUNDS) do if s.id == id then return s.name end end
	return (SOUNDS[1] and SOUNDS[1].name) or "-"
end

-- Glow / countdown colors.
local GLOW_WARM   = { 1, 0.85, 0.3 }     -- glowing in the final seconds
local GLOW_PURPLE = { 0.72, 0.26, 0.98 } -- ended EARLY (dispelled / overridden), frozen
local GLOW_RED    = { 1, 0.15, 0.15 }    -- ran out naturally (< 1s left), frozen
local COUNT_GREEN = { 0.45, 1, 0.45 }    -- countdown, healthy
local COUNT_RED   = { 1, 0.35, 0.35 }    -- countdown, final seconds
local COUNT_DIM   = { 0.65, 0.65, 0.65 } -- countdown, unknown ("?" / "??")

-- Sort: expired (frozen at the top, nearest the header), then live (soonest first),
-- then unknown-time rows.
local function rowTier(e)
	if e.expired then return 1 elseif not e.expiration then return 3 else return 2 end
end
local function byRow(a, b)
	local ta, tb = rowTier(a), rowTier(b)
	if ta ~= tb then return ta < tb end
	local va, vb
	if ta == 1 then va, vb = a.expiredAt or 0, b.expiredAt or 0
	else va, vb = a.expiration or 0, b.expiration or 0 end
	if va ~= vb then return va < vb end
	-- Stable tiebreak so equal-time rows keep a fixed order across rebuilds
	-- (Lua's table.sort isn't stable; without this, tied rows visibly swap).
	if a.key ~= b.key then return a.key < b.key end
	return (a.guid or "") < (b.guid or "")
end

local function spellColor(cfg, spell)
	local s = cfg.spells and cfg.spells[spell.key]
	return (s and s.color) or spell.color
end

-- Apply a font size (+ fake "bold" via outline, since Classic has no bold small
-- font). Default size = the game's small font size.
local _, DEFAULT_FONT_SIZE = GameFontHighlightSmall:GetFont()
DEFAULT_FONT_SIZE = math.floor((DEFAULT_FONT_SIZE or 10) + 0.5)
local function applyFont(fs, size, bold)
	local file = fs:GetFont()
	if file then fs:SetFont(file, size, bold and "OUTLINE" or "") end
end

-- Format a size multiplier like 1x / 1.5x / 2.25x (drop trailing zeros).
local function fmtScale(v)
	local s = ("%.2f"):format(v):gsub("0+$", ""):gsub("%.$", "")
	return s .. "x"
end

-- Drop the "-Realm" suffix cross-realm names carry (e.g. "Bob-Kurinnaxx" -> "Bob").
local function shortName(name)
	if not name or name == "" then return "" end
	return (name:gsub("%-.*$", ""))
end

-- Show the raid target marker icon (index 1-8: Star..Skull) on a texture. (Shared impl.)
local function setMarkerTexture(tex, index)
	core.SetRaidMarker(tex, index)
end

-- ===== shared per-entry display helpers (used by both views) ================

-- Target + source text and their class/reaction colors (colors come from Core).
local function nameParts(e, spell)
	local tText
	if e.guid == M.playerGUID then
		tText = "ME"
	else
		tText = e.name or "?"
		if spell and spell.maxStacks and e.stacks then
			tText = ("%s (%d/%d)"):format(tText, e.stacks, spell.maxStacks)
		elseif e.stacks and e.stacks > 1 then
			-- Show-all debuff with no known stack cap: bare count.
			tText = ("%s (%d)"):format(tText, e.stacks)
		end
	end
	local tc = e.tgtColor
	local sText = e.mine and "ME" or shortName(e.srcName)
	local sc = e.srcColor
	return tText, (tc and tc[1] or 1), (tc and tc[2] or 1), (tc and tc[3] or 1),
	       sText, (sc and sc[1] or 1), (sc and sc[2] or 1), (sc and sc[3] or 1)
end

-- Brightness: your casts full, others' dimmer, expired/untimed dimmest.
local function entryDim(e)
	if e.expired or e.unknown then return 0.4 elseif not e.mine then return 0.6 end
	return 1
end

-- Per-frame bar/countdown state. Returns fill (0-1), sec (int or nil), fixedStr
-- ("?"/"??" or nil), glow (color table or nil).
local function entryBars(e, now, maxDur)
	if e.expired then
		local f = e.frozen or 0
		local g = (f < 1) and GLOW_RED or GLOW_PURPLE
		return f / maxDur, math.floor(f), nil, g
	elseif e.unknown or not e.expiration then
		local spell = M.SPELL_BY_KEY[e.key] or (e.dbKey and M.SPELL_BY_KEY[e.dbKey])
		return ((spell and spell.duration) or e.seenDur or 1) / maxDur, nil,
			(spell and spell.approx) and "??" or "?", nil
	else
		local rem = e.expiration - now
		if rem < 0 then rem = 0 end
		return rem / maxDur, math.floor(rem), nil, (rem <= 5 and GLOW_WARM or nil)
	end
end

-- Countdown text color: green healthy, red final-seconds, glow color when frozen,
-- dim for unknown.
local function countColor(glow, fixedStr)
	if fixedStr then return COUNT_DIM end
	if glow == GLOW_WARM then return COUNT_RED end
	if glow then return glow end
	return COUNT_GREEN
end

-- ===========================================================================

local function openColorPicker(r, g, b, onChange)
	local function apply()
		local nr, ng, nb = ColorPickerFrame:GetColorRGB()
		onChange(nr, ng, nb)
	end
	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({
			r = r, g = g, b = b, hasOpacity = false,
			swatchFunc = apply,
			cancelFunc = function() onChange(r, g, b) end,
		})
	else
		ColorPickerFrame.func = apply
		ColorPickerFrame.swatchFunc = apply
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.cancelFunc = function() onChange(r, g, b) end
		ColorPickerFrame.previousValues = { r = r, g = g, b = b }
		ColorPickerFrame:SetColorRGB(r, g, b)
		ColorPickerFrame:Hide()
		ColorPickerFrame:Show()
	end
end

-- The shared header-button style (mouse-over highlight + tooltip); see Core/Lib_Widgets.lua.
local iconButton = core.widgets.iconButton

-- Hide pooled widgets from index `from` (default 1) to the end, dropping the entry
-- reference so a stale row/icon can't be re-animated.
local function hidePool(pool, from)
	if not pool then return end
	for i = from or 1, #pool do
		pool[i]:Hide()
		pool[i].entry = nil
	end
end

-- Trim the built-in transparent border off a WoW icon texture. (Shared impl.)
local function cropIcon(tex)
	core.CropIcon(tex)
end

-- ==========================================================================
-- Window class
-- ==========================================================================
local Window = {}
Window.__index = Window

-- --- icon view widget ------------------------------------------------------
function Window:GetIcon(i)
	self.icons = self.icons or {}
	local ic = self.icons[i]
	if ic then return ic end

	ic = CreateFrame("Frame", nil, self.frame)

	ic.icon = ic:CreateTexture(nil, "ARTWORK", nil, 0)
	cropIcon(ic.icon)

	-- Color flash over the ICON (not the bar): warm in the final seconds, red/purple
	-- when frozen.
	ic.glow = ic:CreateTexture(nil, "ARTWORK", nil, 2)
	ic.glow:SetAllPoints(ic.icon)
	ic.glow:SetColorTexture(1, 0.85, 0.3)
	ic.glow:SetBlendMode("ADD")
	ic.glow:Hide()

	-- A soft glow AROUND the icon while the aura has expired.
	ic.expGlow = ic:CreateTexture(nil, "ARTWORK", nil, 5)
	ic.expGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	ic.expGlow:SetBlendMode("ADD")
	ic.expGlow:SetVertexColor(1, 0.82, 0) -- gold (this glow texture tints from white)
	ic.expGlow:Hide()

	-- Cooldown swipe for the compact grid view: a dark wedge over the icon that grows
	-- as the aura runs out (standard debuff-timer look). Hidden in the row view.
	ic.cd = CreateFrame("Cooldown", nil, ic, "CooldownFrameTemplate")
	ic.cd:SetAllPoints(ic.icon)
	ic.cd:SetDrawEdge(false)
	ic.cd:SetHideCountdownNumbers(true) -- we draw our own number (below)
	-- Opt this swipe out of OmniCC / tullaCTC: both honor `noCooldownCount` and would
	-- otherwise stack their own countdown text on top of ours. (Their hooks ignore
	-- SetHideCountdownNumbers, so this flag is what actually stops them.)
	ic.cd.noCooldownCount = true
	ic.cd:Hide()

	-- The countdown number lives on a frame ABOVE the swipe so it's never covered.
	ic.textLayer = CreateFrame("Frame", nil, ic)
	ic.textLayer:SetAllPoints(ic)
	ic.textLayer:SetFrameLevel(ic:GetFrameLevel() + 6)

	ic.count = ic.textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	ic.count:SetPoint("CENTER", ic.icon, "CENTER", 0, 0)

	-- The cooldown bar behind the two names (right of the icon): it drains only (no
	-- flash), no background (undrained part is transparent). The names and markers are
	-- children of the bar so they draw on top of it.
	ic.bar = CreateFrame("StatusBar", nil, ic)
	ic.bar:SetStatusBarTexture(BAR_TEX)
	ic.bar:SetMinMaxValues(0, 1)

	ic.source = ic.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ic.source:SetJustifyH("LEFT")
	ic.source:SetWordWrap(false)

	ic.target = ic.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ic.target:SetJustifyH("LEFT")
	ic.target:SetWordWrap(false)

	ic.marker = ic.bar:CreateTexture(nil, "OVERLAY")
	ic.marker:Hide()

	ic.srcMarker = ic.bar:CreateTexture(nil, "OVERLAY")
	ic.srcMarker:Hide()

	-- "Your target" indicator: a dark-backed red chip that sits just OUTSIDE the
	-- icon's edge. Drawn as an overhang so toggling it as you change targets never
	-- shifts the row's alignment.
	ic.tgtBg = ic:CreateTexture(nil, "OVERLAY", nil, 6)
	ic.tgtBg:SetColorTexture(0, 0, 0, 0.9)
	ic.tgtBg:Hide()
	ic.tgtDot = ic:CreateTexture(nil, "OVERLAY", nil, 7)
	ic.tgtDot:SetColorTexture(0.95, 0.15, 0.15) -- red
	ic.tgtDot:Hide()
	ic.tgtState = 0

	self.icons[i] = ic
	return ic
end

-- Small header icon showing a tracked spell.
function Window:GetHeaderIcon(i)
	self.headerIcons = self.headerIcons or {}
	local t = self.headerIcons[i]
	if t then return t end
	t = self.frame:CreateTexture(nil, "OVERLAY")
	t:SetSize(12, 12)
	cropIcon(t)
	self.headerIcons[i] = t
	return t
end

function Window:UpdateHeaderIcons()
	if self.cfg.locked then -- locked windows hide the whole header, icons included
		if self.headerIcons then
			for i = 1, #self.headerIcons do self.headerIcons[i]:Hide() end
		end
		return
	end
	local up = self.cfg.growUp
	local maxIcons = math.max(0, math.floor((self.frame:GetWidth() - 74) / 14))
	local n = 0
	for _, spell in ipairs(M.SPELLS) do
		local s = self.cfg.spells and self.cfg.spells[spell.key]
		if s and s.enabled and n < maxIcons then
			n = n + 1
			local t = self:GetHeaderIcon(n)
			t:ClearAllPoints()
			if up then
				t:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", PAD + (n - 1) * 14, PAD - 1)
			else
				t:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PAD + (n - 1) * 14, -(PAD - 1))
			end
			t:SetTexture(spell.icon or M.FALLBACK_ICON)
			t:Show()
		end
	end
	if self.headerIcons then
		for i = n + 1, #self.headerIcons do self.headerIcons[i]:Hide() end
	end
end

function Window:CollectSorted()
	local out = self.sortBuf
	wipe(out)
	local cfg = self.cfg
	local onlyMine = cfg.onlyMine
	local maxDur = 1
	if cfg.allEnemyDebuffs then
		-- Every scanned enemy debuff (synthetic "@" bucket). The enabled spells below
		-- just stay bright; RebuildIcons dims everything else. Curated keys are NOT
		-- also collected here, so an enabled+present debuff shows once (via its "@").
		local now = GetTime()
		for key, t in pairs(M.state) do
			if key:byte(1) == 64 then
				for _, e in pairs(t) do
					if not (onlyMine and not e.mine) then
						local d = e.seenDur or (e.expiration and (e.expiration - now)) or 0
						if d and d > maxDur then maxDur = d end
						out[#out + 1] = e
					end
				end
			end
		end
	end
	if cfg.spells then
		for key, s in pairs(cfg.spells) do
			local spell = M.SPELL_BY_KEY[key]
			if s.enabled and spell then
				if spell.duration > maxDur then maxDur = spell.duration end
				if not cfg.allEnemyDebuffs then
					local t = M.state[key]
					if t then
						for _, e in pairs(t) do
							if not (onlyMine and not e.mine) then out[#out + 1] = e end
						end
					end
				end
			end
		end
	end
	self.maxDur = maxDur
	table.sort(out, byRow)
	return out
end

-- Partition the sorted entries by target GUID into groups, ordered by when each mob
-- was first seen (M.guidSeen). Rows keep their soonest-first order within a group
-- because we append them in the already-sorted order CollectSorted produced.
function Window:CollectGroups()
	local flat = self:CollectSorted() -- fills sortBuf (byRow-sorted), sets self.maxDur
	self.groupBuf = self.groupBuf or {}
	self.groupByGuid = self.groupByGuid or {}
	local groups, byGuid = self.groupBuf, self.groupByGuid
	wipe(groups)
	wipe(byGuid)
	local seen = M.guidSeen
	for _, e in ipairs(flat) do
		local guid = e.guid
		local g = byGuid[guid]
		if not g then
			g = { guid = guid, name = e.name, color = e.tgtColor,
			      order = (seen and seen[guid]) or math.huge, entries = {} }
			byGuid[guid] = g
			groups[#groups + 1] = g
		end
		g.entries[#g.entries + 1] = e
		if e.name and e.name ~= "" then g.name = e.name end
		if e.tgtColor then g.color = e.tgtColor end
	end
	table.sort(groups, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return (a.guid or "") < (b.guid or "")
	end)
	return groups
end

-- Anchor the header controls (buttons + resize) to the top or bottom edge.
function Window:LayoutHeader()
	local up = self.cfg.growUp
	self.closeBtn:ClearAllPoints()
	if up then
		self.closeBtn:SetPoint("BOTTOMRIGHT", -PAD, PAD - 1)
	else
		self.closeBtn:SetPoint("TOPRIGHT", -PAD, -PAD + 1)
	end
	if self.resize then
		self.resize:ClearAllPoints()
		self.resize:SetPoint(up and "TOPRIGHT" or "BOTTOMRIGHT", 0, 0)
	end
end

function Window:Rebuild()
	local frame, cfg = self.frame, self.cfg
	self:LayoutHeader()
	self:UpdateHeaderIcons()

	local headerSpace = cfg.locked and 0 or (HEADER_H + PAD)
	local edgePad = cfg.locked and 0 or PAD
	local n, totalH
	if cfg.groupByTarget then
		local groups = self:CollectGroups()
		n = 0
		for i = 1, #groups do n = n + #groups[i].entries end
		if cfg.iconGrid then
			totalH = self:RebuildGroupedGrid(groups, n, headerSpace, edgePad)
		else
			totalH = self:RebuildGrouped(groups, n, headerSpace, edgePad)
		end
	else
		local sorted = self:CollectSorted()
		n = #sorted
		if cfg.iconGrid then
			totalH = self:RebuildGrid(sorted, n, headerSpace, edgePad)
		else
			totalH = self:RebuildIcons(sorted, n, headerSpace, edgePad)
			if self.groupHeaders then -- clear any leftover group headers from grouped mode
				for i = 1, #self.groupHeaders do self.groupHeaders[i]:Hide() end
			end
		end
	end

	if n > 0 or not cfg.locked or (self.configPanel and self.configPanel:IsShown()) then
		-- Unlocked totalH already includes the header + pads (>= a header-sized
		-- frame); locked windows are exactly their content, no empty mouse strip.
		frame:SetHeight(totalH)
		frame:Show()
	else
		frame:Hide()
	end
end

-- Anchor a stacked item at slot i: grow down from the top edge, or up from the
-- bottom edge. `leftInset` insets the left (rows leave room for the outside icon).
function Window:_anchorItem(item, off, leftInset)
	local frame, up = self.frame, self.cfg.growUp
	item:ClearAllPoints()
	if up then
		item:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", leftInset, off)
		item:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, off)
	else
		item:SetPoint("TOPLEFT", frame, "TOPLEFT", leftInset, -off)
		item:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -off)
	end
end

-- Shared row metrics (icon size / vertical step / fonts) from the window's scale+font.
function Window:_iconMetrics()
	local cfg = self.cfg
	local scale = cfg.rowScale or 1
	local fontSize = cfg.fontSize or DEFAULT_FONT_SIZE
	local lineH = fontSize + 4 -- approx height of one name line
	local iconSz = math.floor(2 * lineH * scale + 0.5) -- icon (and bar) height = the two names
	local itemH = iconSz
	local step = itemH + ROW_SP + 2
	local countFont = math.max(9, math.floor(iconSz * 0.5))
	return iconSz, itemH, step, countFont, fontSize
end

-- Configure one pooled icon widget for entry e. Does everything EXCEPT the vertical
-- anchor (the flat and grouped layouts each set that). Shared by both.
function Window:_fillIcon(ic, e, iconSz, itemH, fontSize, countFont)
	local cfg = self.cfg
	local spell = M.SPELL_BY_KEY[e.key] or (e.dbKey and M.SPELL_BY_KEY[e.dbKey])
	ic.entry = e
	ic.countTbl = nil
	ic:SetHeight(itemH)
	ic.cd:Hide() -- no swipe in the row view
	ic.bar:Show() -- (re)show the widgets the compact grid view hides
	ic.source:Show()
	ic.target:Show()

	local d = entryDim(e)
	local right = cfg.rightAlign
	-- Icon on the LEFT (or the RIGHT when right-aligned); countdown centered in it.
	ic.icon:ClearAllPoints()
	ic.icon:SetPoint(right and "TOPRIGHT" or "TOPLEFT", ic, right and "TOPRIGHT" or "TOPLEFT", 0, 0)
	ic.icon:SetSize(iconSz, iconSz)
	ic.icon:SetTexture((spell and spell.icon) or e.icon or M.FALLBACK_ICON)
	ic.icon:SetVertexColor(d, d, d)
	local gPad = math.floor(iconSz * 0.22)
	ic.expGlow:ClearAllPoints()
	ic.expGlow:SetPoint("TOPLEFT", ic.icon, "TOPLEFT", -gPad, gPad)
	ic.expGlow:SetPoint("BOTTOMRIGHT", ic.icon, "BOTTOMRIGHT", gPad, -gPad)
	applyFont(ic.count, countFont, true)

	-- Target chip on the icon's OUTER edge (mirrors with align), overhanging the
	-- margin so it never pushes the icon/bar around. State is set in UpdateVisible.
	local dotSz = math.max(6, math.floor(iconSz * 0.34 + 0.5))
	ic.tgtBg:ClearAllPoints()
	if right then
		ic.tgtBg:SetPoint("LEFT", ic.icon, "RIGHT", 3, 0)
	else
		ic.tgtBg:SetPoint("RIGHT", ic.icon, "LEFT", -3, 0)
	end
	ic.tgtBg:SetSize(dotSz + 2, dotSz + 2)
	ic.tgtDot:ClearAllPoints()
	ic.tgtDot:SetPoint("CENTER", ic.tgtBg, "CENTER", 0, 0)
	ic.tgtDot:SetSize(dotSz, dotSz)
	ic.tgtState = 0
	ic.tgtBg:Hide()
	ic.tgtDot:Hide()

	-- Cooldown bar on the opposite side of the icon, filling toward the icon.
	local c = (spell and spellColor(cfg, spell)) or COUNT_DIM
	ic.bar:ClearAllPoints()
	if right then
		ic.bar:SetPoint("TOPRIGHT", ic.icon, "TOPLEFT", -3, 0)
		ic.bar:SetPoint("BOTTOMLEFT", ic, "BOTTOMLEFT", 0, 0)
	else
		ic.bar:SetPoint("TOPLEFT", ic.icon, "TOPRIGHT", 3, 0)
		ic.bar:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 0, 0)
	end
	ic.bar:SetReverseFill(right and true or false)
	ic.bar:SetStatusBarColor(c[1] * d, c[2] * d, c[3] * d, 0.8)

	local tText, tR, tG, tB, sText, sR, sG, sB = nameParts(e, spell)

	-- Source (top) + target (bottom) on the bar, justified toward the icon, each
	-- with its raid marker hugging the icon side.
	local nearJ = right and "RIGHT" or "LEFT"
	local farJ = right and "LEFT" or "RIGHT"
	local mx = right and -2 or 2
	local mSz = fontSize + 4
	ic.source:SetJustifyH(nearJ)
	ic.target:SetJustifyH(nearJ)

	ic.source:ClearAllPoints()
	if e.srcMarker then
		ic.srcMarker:ClearAllPoints()
		ic.srcMarker:SetSize(mSz, mSz)
		ic.srcMarker:SetPoint("TOP" .. nearJ, ic.bar, "TOP" .. nearJ, mx, -1)
		setMarkerTexture(ic.srcMarker, e.srcMarker)
		ic.srcMarker:Show()
		ic.source:SetPoint("TOP" .. nearJ, ic.srcMarker, "TOP" .. farJ, mx, 0)
	else
		ic.srcMarker:Hide()
		ic.source:SetPoint("TOP" .. nearJ, ic.bar, "TOP" .. nearJ, right and -3 or 3, -1)
	end
	ic.source:SetPoint(farJ, ic.bar, farJ, -mx, 0)
	ic.source:SetText(sText)
	ic.source:SetTextColor(sR, sG, sB)
	applyFont(ic.source, fontSize, e.mine)

	ic.target:ClearAllPoints()
	if e.marker then
		ic.marker:ClearAllPoints()
		ic.marker:SetSize(mSz, mSz)
		ic.marker:SetPoint("BOTTOM" .. nearJ, ic.bar, "BOTTOM" .. nearJ, mx, 1)
		setMarkerTexture(ic.marker, e.marker)
		ic.marker:Show()
		ic.target:SetPoint("BOTTOM" .. nearJ, ic.marker, "BOTTOM" .. farJ, mx, 0)
	else
		ic.marker:Hide()
		ic.target:SetPoint("BOTTOM" .. nearJ, ic.bar, "BOTTOM" .. nearJ, right and -3 or 3, 1)
	end
	ic.target:SetPoint(farJ, ic.bar, farJ, -mx, 0)
	ic.target:SetText(tText)
	ic.target:SetTextColor(tR, tG, tB)
	applyFont(ic.target, fontSize, e.guid == M.playerGUID)
end

function Window:RebuildIcons(sorted, n, headerSpace, edgePad)
	local iconSz, itemH, step, countFont, fontSize = self:_iconMetrics()
	for i = 1, n do
		local ic = self:GetIcon(i)
		self:_anchorItem(ic, headerSpace + (i - 1) * step, PAD)
		self:_fillIcon(ic, sorted[i], iconSz, itemH, fontSize, countFont)
		ic:Show()
	end
	hidePool(self.icons, n + 1)
	return headerSpace + n * step + edgePad
end

-- --- grouped-by-target layout ----------------------------------------------
-- A group header (mob name) drawn above each target's rows.
function Window:GetGroupHeader(i)
	self.groupHeaders = self.groupHeaders or {}
	local h = self.groupHeaders[i]
	if h then return h end
	h = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	h:SetJustifyH("LEFT")
	h:SetWordWrap(false)
	self.groupHeaders[i] = h
	return h
end

-- Anchor a full-width group header `off` from the fixed edge (top for grow-down,
-- bottom for grow-up), mirroring _anchorItem.
function Window:_anchorHeaderAt(h, off)
	local frame, up = self.frame, self.cfg.growUp
	h:ClearAllPoints()
	if up then
		h:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, off)
		h:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, off)
	else
		h:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -off)
		h:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -off)
	end
end

-- Lay out grouped-by-target: a header per group, then its rows, then a gap. Groups
-- are pre-ordered (first-seen) and their rows pre-sorted (soonest first). Grow-up
-- lays the same visual order from the bottom, so total height is measured first.
function Window:RebuildGrouped(groups, n, headerSpace, edgePad)
	local iconSz, itemH, step, countFont, fontSize = self:_iconMetrics()
	local hdrH = fontSize + 4
	local hdrGap = 2   -- header to its first row
	local groupGap = 7 -- between groups
	local up = self.cfg.growUp

	local contentH = 0
	for gi = 1, #groups do
		contentH = contentH + hdrH + hdrGap + #groups[gi].entries * step
		if gi < #groups then contentH = contentH + groupGap end
	end

	local y = 0 -- distance from the content's top edge
	local iconIdx = 0
	for gi = 1, #groups do
		local g = groups[gi]
		local hdr = self:GetGroupHeader(gi)
		hdr:SetText(g.name or "?")
		local hc = g.color
		if hc then hdr:SetTextColor(hc[1], hc[2], hc[3]) else hdr:SetTextColor(1, 0.82, 0) end
		applyFont(hdr, fontSize + 1, true)
		self:_anchorHeaderAt(hdr, up and (headerSpace + (contentH - y - hdrH)) or (headerSpace + y))
		hdr:Show()
		y = y + hdrH + hdrGap
		for _, e in ipairs(g.entries) do
			iconIdx = iconIdx + 1
			local ic = self:GetIcon(iconIdx)
			self:_anchorItem(ic, up and (headerSpace + (contentH - y - itemH)) or (headerSpace + y), PAD)
			self:_fillIcon(ic, e, iconSz, itemH, fontSize, countFont)
			ic:Show()
			y = y + step
		end
		if gi < #groups then y = y + groupGap end
	end
	hidePool(self.icons, iconIdx + 1)
	if self.groupHeaders then
		for i = #groups + 1, #self.groupHeaders do self.groupHeaders[i]:Hide() end
	end
	return headerSpace + contentH + edgePad
end

-- --- compact icon-grid view ------------------------------------------------
-- Fill one icon for the grid view: just the icon, a cooldown swipe, and the number
-- (row-view bar/names/markers hidden). The vertical/grid anchor is set by _gridPlace.
function Window:_fillIconCompact(ic, e, iconSz, fontSize, countFont)
	local spell = M.SPELL_BY_KEY[e.key] or (e.dbKey and M.SPELL_BY_KEY[e.dbKey])
	ic.entry = e
	ic.countTbl = nil
	ic:SetSize(iconSz, iconSz)

	local d = entryDim(e)
	ic.icon:ClearAllPoints()
	ic.icon:SetPoint("TOPLEFT", ic, "TOPLEFT", 0, 0)
	ic.icon:SetSize(iconSz, iconSz)
	ic.icon:SetTexture((spell and spell.icon) or e.icon or M.FALLBACK_ICON)
	ic.icon:SetVertexColor(d, d, d)

	local gPad = math.floor(iconSz * 0.22)
	ic.expGlow:ClearAllPoints()
	ic.expGlow:SetPoint("TOPLEFT", ic.icon, "TOPLEFT", -gPad, gPad)
	ic.expGlow:SetPoint("BOTTOMRIGHT", ic.icon, "BOTTOMRIGHT", gPad, -gPad)

	applyFont(ic.count, countFont, true)

	-- Swipe only for a live, timed aura; "?" and expired rows have no swipe.
	if e.expiration and not e.expired and not e.unknown then
		local full = (spell and spell.duration) or e.seenDur or (e.expiration - GetTime())
		if full and full > 0 then
			ic.cd:SetCooldown(e.expiration - full, full)
			ic.cd:Show()
		else
			ic.cd:Clear(); ic.cd:Hide()
		end
	else
		ic.cd:Clear(); ic.cd:Hide()
	end

	-- Widgets the row view uses but the grid doesn't.
	ic.bar:Hide()
	ic.source:Hide()
	ic.target:Hide()
	ic.marker:Hide()
	ic.srcMarker:Hide()
	ic.tgtBg:Hide()
	ic.tgtDot:Hide()
end

-- Place `entries` as a wrap grid (across, then down) starting at `yTop` from the
-- content top. Icons are drawn from GetIcon(iconIdx+1..). Grow-up mirrors via contentH.
-- Returns the next iconIdx and the pixel height the grid consumed.
function Window:_gridPlace(entries, iconIdx, yTop, perRow, iconSz, gap, contentH, headerSpace, up, fontSize, countFont)
	local nEntries = #entries
	for i = 1, nEntries do
		local col = (i - 1) % perRow
		local row = math.floor((i - 1) / perRow)
		local x = PAD + col * (iconSz + gap)
		local ry = yTop + row * (iconSz + gap)
		iconIdx = iconIdx + 1
		local ic = self:GetIcon(iconIdx)
		ic:ClearAllPoints()
		if up then
			ic:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", x, headerSpace + (contentH - ry - iconSz))
		else
			ic:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, -(headerSpace + ry))
		end
		self:_fillIconCompact(ic, entries[i], iconSz, fontSize, countFont)
		ic:Show()
	end
	local rows = math.ceil(nEntries / perRow)
	local usedH = rows * iconSz + math.max(0, rows - 1) * gap
	return iconIdx, usedH
end

-- How many icons fit across the current window width.
function Window:_gridPerRow(iconSz, gap)
	local contentW = (self.frame:GetWidth() or DEFAULT_W) - 2 * PAD
	return math.max(1, math.floor((contentW + gap) / (iconSz + gap)))
end

function Window:RebuildGrid(sorted, n, headerSpace, edgePad)
	local iconSz, _, _, countFont, fontSize = self:_iconMetrics()
	local gap = 3
	local perRow = self:_gridPerRow(iconSz, gap)
	local rows = math.ceil(n / perRow)
	local contentH = rows * iconSz + math.max(0, rows - 1) * gap
	local iconIdx = self:_gridPlace(sorted, 0, 0, perRow, iconSz, gap, contentH,
		headerSpace, self.cfg.growUp, fontSize, countFont)
	hidePool(self.icons, iconIdx + 1)
	if self.groupHeaders then
		for i = 1, #self.groupHeaders do self.groupHeaders[i]:Hide() end
	end
	return headerSpace + contentH + edgePad
end

function Window:RebuildGroupedGrid(groups, n, headerSpace, edgePad)
	local iconSz, _, _, countFont, fontSize = self:_iconMetrics()
	local gap = 3
	local hdrH = fontSize + 4
	local hdrGap = 2
	local groupGap = 7
	local up = self.cfg.growUp
	local perRow = self:_gridPerRow(iconSz, gap)

	local function gridH(ne)
		local rows = math.ceil(ne / perRow)
		return rows * iconSz + math.max(0, rows - 1) * gap
	end

	local contentH = 0
	for gi = 1, #groups do
		contentH = contentH + hdrH + hdrGap + gridH(#groups[gi].entries)
		if gi < #groups then contentH = contentH + groupGap end
	end

	local y = 0
	local iconIdx = 0
	for gi = 1, #groups do
		local g = groups[gi]
		local hdr = self:GetGroupHeader(gi)
		hdr:SetText(g.name or "?")
		local hc = g.color
		if hc then hdr:SetTextColor(hc[1], hc[2], hc[3]) else hdr:SetTextColor(1, 0.82, 0) end
		applyFont(hdr, fontSize + 1, true)
		self:_anchorHeaderAt(hdr, up and (headerSpace + (contentH - y - hdrH)) or (headerSpace + y))
		hdr:Show()
		y = y + hdrH + hdrGap
		local usedH
		iconIdx, usedH = self:_gridPlace(g.entries, iconIdx, y, perRow, iconSz, gap, contentH,
			headerSpace, up, fontSize, countFont)
		y = y + usedH
		if gi < #groups then y = y + groupGap end
	end
	hidePool(self.icons, iconIdx + 1)
	if self.groupHeaders then
		for i = #groups + 1, #self.groupHeaders do self.groupHeaders[i]:Hide() end
	end
	return headerSpace + contentH + edgePad
end

-- Current target GUID: refreshed once per frame in UpdateVisibleRows, then read by
-- every window's UpdateVisible to flag the row whose unit is your target.
local curTargetGUID

-- --- per-frame animation (shared math via entryBars) -----------------------
local function updateBarLike(w, bar, glowTex, timeFS, now, maxDur, pulse, glowAlpha, expGlow, cfg)
	local e = w.entry
	local fill, sec, fixedStr, glow = entryBars(e, now, maxDur)
	if fill > 1 then fill = 1 end
	bar:SetValue(fill)
	local str
	if sec then
		if w.lastSec ~= sec then w.lastSec = sec; w.secStr = ("%d"):format(sec) end
		str = w.secStr
	else
		str = fixedStr; w.lastSec = nil
	end
	if w.lastTime ~= str then w.lastTime = str; timeFS:SetText(str) end
	local ctbl = countColor(glow, fixedStr)
	if w.countTbl ~= ctbl then w.countTbl = ctbl; timeFS:SetTextColor(ctbl[1], ctbl[2], ctbl[3]) end
	if glow then
		if w.glowColor ~= glow then glowTex:SetColorTexture(glow[1], glow[2], glow[3]); w.glowColor = glow end
		glowTex:SetAlpha(pulse * glowAlpha)
		glowTex:Show()
	else
		glowTex:Hide()
	end
	-- Soft glow around the icon while expired (icon view only).
	if expGlow then
		if e.expired then
			expGlow:SetAlpha(0.4 + 0.6 * math.abs(math.sin(now * 3)))
			expGlow:Show()
		else
			expGlow:Hide()
		end
	end
	-- Optional per-window alert sounds; fire once on entering the state.
	-- Flags live on the entry (not the widget) so re-sorting can't re-fire them, and
	-- only a window that actually plays the sound sets the flag.
	if cfg then
		if glow == GLOW_WARM then
			if cfg.sound5 and not e.warned5 then
				e.warned5 = true
				local id = cfg.sound5Id or (SOUNDS[1] and SOUNDS[1].id)
				if id then PlaySound(id, "Master") end
			end
		else
			e.warned5 = false
		end
		-- Expiry sound only on a NATURAL run-out (red flash = frozen < 1s), never on a
		-- dispel / override / death / evade (those freeze with time left = purple).
		if glow == GLOW_RED then
			if cfg.soundExpire and not e.warnedExp then
				e.warnedExp = true
				local id = cfg.soundExpireId or (SOUNDS[1] and SOUNDS[1].id)
				if id then PlaySound(id, "Master") end
			end
		else
			e.warnedExp = false
		end
	end
end

function Window:UpdateVisible(now)
	if not self.frame:IsShown() or not self.icons then return end
	local cfg = self.cfg
	local maxDur = cfg.barMax or self.maxDur or 1 -- custom bar width (seconds) or the longest
	local pulse = 0.20 + 0.25 * math.abs(math.sin(now * 3.5))
	for i = 1, #self.icons do
		local ic = self.icons[i]
		if ic:IsShown() and ic.entry then
			updateBarLike(ic, ic.bar, ic.glow, ic.count, now, maxDur, pulse, 0.7, ic.expGlow, cfg)

			-- Flag the row whose unit is your current target (red chip). Only the two
			-- textures toggle; the row never moves. The compact grid omits the chip.
			if not cfg.iconGrid then
				local g = ic.entry.guid
				local want = (g and g == curTargetGUID) and 1 or 0
				if ic.tgtState ~= want then
					ic.tgtState = want
					if want == 1 then
						ic.tgtBg:Show()
						ic.tgtDot:Show()
					else
						ic.tgtBg:Hide()
						ic.tgtDot:Hide()
					end
				end
			end
		end
	end
end

-- --- position (grow-direction aware) ---------------------------------------
function Window:NormalizeAnchor()
	local f = self.frame
	local left = f:GetLeft()
	if not left then return end
	if self.cfg.growUp then
		local bottom = f:GetBottom()
		if not bottom then return end
		f:ClearAllPoints()
		f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
		self.cfg.point = { point = "BOTTOMLEFT", relP = "BOTTOMLEFT", x = left, y = bottom }
	else
		local top = f:GetTop()
		if not top then return end
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
		self.cfg.point = { point = "TOPLEFT", relP = "BOTTOMLEFT", x = left, y = top }
	end
end

function Window:ApplyPosition()
	local p = self.cfg.point
	self.frame:ClearAllPoints()
	if p and p.x and p.y then
		self.frame:SetPoint(p.point or "TOPLEFT", UIParent, p.relP or "BOTTOMLEFT", p.x, p.y)
	else
		self.frame:SetPoint("TOPLEFT", UIParent, "CENTER", -100, 150)
	end
end

function Window:ApplyLock()
	local locked = self.cfg.locked
	self.lockBtn:SetNormalTexture(locked
		and "Interface\\Buttons\\LockButton-Locked-Up"
		or "Interface\\Buttons\\LockButton-Unlocked-Up")
	local t = self.lockBtn:GetNormalTexture()
	if t then t:SetTexCoord(0.12, 0.88, 0.12, 0.88) end -- zoom past the icon padding
	if self.resize then self.resize:SetShown(not locked) end
	-- Locked = just the bars/icons: no background/border, and the whole header
	-- (buttons + spell icons) is hidden. Unlock again with the minimap button.
	if locked then
		self.frame:SetBackdrop(nil)
		if self.configPanel then self.configPanel:Hide() end
	else
		self.frame:SetBackdrop(BACKDROP)
		self.frame:SetBackdropColor(0, 0, 0, 0.85)
	end
	local showHeader = not locked
	self.closeBtn:SetShown(showHeader)
	self.lockBtn:SetShown(showHeader)
	self.addBtn:SetShown(showHeader)
	self.gearBtn:SetShown(showHeader)
end

function Window:ToggleConfig()
	if self.configPanel:IsShown() then
		self.configPanel:Hide()
	else
		self:RenderConfig()
		self:ApplyConfigPos()
		self.configPanel:Show()
	end
end

-- --- gear panel: a reusable checkbox+icon+name+swatch line -----------------
function Window:GetConfigLine(i)
	self.cfgLines = self.cfgLines or {}
	local line = self.cfgLines[i]
	if line then return line end

	line = CreateFrame("Frame", nil, self.configPanel)
	line:SetSize(COL_W, 18)

	line.check = CreateFrame("CheckButton", nil, line, "UICheckButtonTemplate")
	line.check:SetSize(18, 18)
	line.check:SetPoint("LEFT", 0, 0)

	line.icon = line:CreateTexture(nil, "ARTWORK")
	line.icon:SetSize(14, 14)
	line.icon:SetPoint("LEFT", line.check, "RIGHT", 2, 0)
	cropIcon(line.icon)

	line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	line.name:SetPoint("LEFT", line.icon, "RIGHT", 4, 0)

	line.swatch = CreateFrame("Button", nil, line)
	line.swatch:SetSize(14, 14)
	line.swatch:SetPoint("RIGHT", -2, 0)
	local border = line.swatch:CreateTexture(nil, "BACKGROUND")
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	border:SetColorTexture(0, 0, 0, 1)
	line.swatch.tex = line.swatch:CreateTexture(nil, "OVERLAY")
	line.swatch.tex:SetAllPoints(true)

	-- Keep the name within its column (clip long names instead of overlapping).
	line.name:SetPoint("RIGHT", line.swatch, "LEFT", -2, 0)
	line.name:SetJustifyH("LEFT")
	line.name:SetWordWrap(false)

	local win = self
	line.check:SetScript("OnClick", function(btn)
		local sp = line.spell
		if not sp then return end
		local s = win.cfg.spells[sp.key]
		if not s then s = {}; win.cfg.spells[sp.key] = s end
		s.enabled = btn:GetChecked() and true or false
		M.RecomputeActiveSpells()
		if M.Rescan then M.Rescan() end
		M.RefreshAll()
		win:RenderConfig()
	end)
	line.swatch:SetScript("OnClick", function()
		local sp = line.spell
		if not sp then return end
		local c = spellColor(win.cfg, sp)
		openColorPicker(c[1], c[2], c[3], function(nr, ng, nb)
			local s = win.cfg.spells[sp.key]
			if not s then s = {}; win.cfg.spells[sp.key] = s end
			s.color = { nr, ng, nb }
			win:RenderConfig()
			M.RefreshAll()
		end)
	end)

	self.cfgLines[i] = line
	return line
end

function Window:BindConfigLine(line, spell)
	line.spell = spell
	line.icon:SetTexture(spell.icon or M.FALLBACK_ICON)
	line.name:SetText(spell.name)
	local s = self.cfg.spells[spell.key]
	line.check:SetChecked(s and s.enabled)
	local c = spellColor(self.cfg, spell)
	line.swatch.tex:SetColorTexture(c[1], c[2], c[3], 1)
	-- "Show all enemy debuffs" ignores this per-spell list, so grey the whole line out
	-- (checkbox + color swatch disabled, name/icon dimmed) to show the picks do nothing.
	local off = self.cfg.allEnemyDebuffs and true or false
	line.check:SetEnabled(not off)
	line.icon:SetDesaturated(off)
	line.name:SetTextColor(1, 1, 1, off and 0.4 or 1)
	line.swatch:SetEnabled(not off)
	line.swatch.tex:SetAlpha(off and 0.4 or 1)
end

-- A class-name header in the gear list.
function Window:GetClassHeader(i)
	self.classHeaders = self.classHeaders or {}
	local h = self.classHeaders[i]
	if h then return h end
	h = self.configPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	h:SetJustifyH("LEFT")
	self.classHeaders[i] = h
	return h
end

-- Reflect the current per-window option values into their widgets.
function Window:BindOptions()
	local o = self.opt
	if not o then return end
	o.growBtn:SetText(self.cfg.growUp and "Grow: Up" or "Grow: Down")
	o.alignBtn:SetText(self.cfg.rightAlign and "Align: Right" or "Align: Left")
	o.sizeSlider:SetValue(self.cfg.rowScale or 1)
	o.sizeVal:SetText(fmtScale(self.cfg.rowScale or 1))
	o.fontBox:SetText(tostring(self.cfg.fontSize or DEFAULT_FONT_SIZE))
	local longest = not self.cfg.barMax
	o.barChk:SetChecked(longest)
	o.barBox:SetText(tostring(math.floor((self.cfg.barMax or self.maxDur or 1) + 0.5)))
	o.barBox:SetEnabled(not longest)
	o.barBox:SetTextColor(longest and 0.55 or 1, longest and 0.55 or 1, longest and 0.55 or 1)
	o.only:SetChecked(self.cfg.onlyMine)
	o.snd5:SetChecked(self.cfg.sound5)
	o.sndExp:SetChecked(self.cfg.soundExpire)
	UIDropDownMenu_SetText(o.snd5Dd, soundName(self.cfg.sound5Id))
	UIDropDownMenu_SetText(o.sndExpDd, soundName(self.cfg.soundExpireId))
	if self.cfg.sound5 then UIDropDownMenu_EnableDropDown(o.snd5Dd) else UIDropDownMenu_DisableDropDown(o.snd5Dd) end
	if self.cfg.soundExpire then UIDropDownMenu_EnableDropDown(o.sndExpDd) else UIDropDownMenu_DisableDropDown(o.sndExpDd) end
	if o.allEnemy then o.allEnemy:SetChecked(self.cfg.allEnemyDebuffs) end
	if o.groupBy then o.groupBy:SetChecked(self.cfg.groupByTarget) end
	if o.iconGrid then o.iconGrid:SetChecked(self.cfg.iconGrid) end
end

-- Every spell in the fixed 3-column layout, grouped by class. Empty classes and
-- the wrong-faction class (Paladin on Horde / Shaman on Alliance) are skipped.
-- The per-window options block sits above the columns (reserves OPT_H at the top).
function Window:RenderConfig()
	self:BindOptions()
	local byClass = {}
	for _, spell in ipairs(M.SPELLS) do
		local b = byClass[spell.class]
		if not b then b = {}; byClass[spell.class] = b end
		b[#b + 1] = spell
	end

	local faction = UnitFactionGroup("player")
	local hidden = {}
	if faction == "Horde" then
		hidden.PALADIN = true
	elseif faction == "Alliance" then
		hidden.SHAMAN = true
	end

	local li, hi, maxY = 0, 0, PAD + OPT_H
	for c = 1, 3 do
		local x = PAD + (c - 1) * (COL_W + COL_GAP)
		local y = PAD + OPT_H -- leave room for the options block at the top
		local firstInCol = true
		for _, class in ipairs(COLUMN_CLASSES[c]) do
			local spells = byClass[class]
			if spells and #spells > 0 and not hidden[class] then
				if not firstInCol then y = y + CLASS_GAP end -- space above the header
				firstInCol = false
				hi = hi + 1
				local h = self:GetClassHeader(hi)
				h:ClearAllPoints()
				h:SetPoint("TOPLEFT", self.configPanel, "TOPLEFT", x, -y)
				h:SetText(class)
				local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
				if cc then h:SetTextColor(cc.r, cc.g, cc.b) else h:SetTextColor(1, 0.82, 0) end
				h:Show()
				y = y + 17
				for _, spell in ipairs(spells) do
					li = li + 1
					local line = self:GetConfigLine(li)
					line:ClearAllPoints()
					line:SetPoint("TOPLEFT", self.configPanel, "TOPLEFT", x, -y)
					self:BindConfigLine(line, spell)
					line:Show()
					y = y + 20
				end
			end
		end
		if y > maxY then maxY = y end
	end
	if self.cfgLines then
		for i = li + 1, #self.cfgLines do self.cfgLines[i]:Hide() end
	end
	if self.classHeaders then
		for i = hi + 1, #self.classHeaders do self.classHeaders[i]:Hide() end
	end

	local w = PAD + 3 * COL_W + 2 * COL_GAP + PAD
	self.configPanel:SetSize(w, maxY + PAD) -- close ✕ now lives in the top-right corner
end

function Window:Destroy()
	self.frame:Hide()
	if self.configPanel then self.configPanel:Hide() end
	hidePool(self.icons)
	if self.groupHeaders then
		for i = 1, #self.groupHeaders do self.groupHeaders[i]:Hide() end
	end
end

-- --------------------------------------------------------------------------
-- Remember where the (large) config panel was dragged to, per window, in cfg so it
-- survives reload. Stored as TOPLEFT relative to UIParent's BOTTOMLEFT.
function Window:SaveConfigPos()
	local panel = self.configPanel
	if not panel then return end
	local left, top = panel:GetLeft(), panel:GetTop()
	if not left or not top then return end
	self.cfg.configPoint = { x = left, y = top }
end

-- Position the config panel as an independent window: at its saved spot, else just below the
-- display window on first open (an absolute anchor, so it does NOT follow the window afterward).
function Window:ApplyConfigPos()
	local panel = self.configPanel
	if not panel then return end
	panel:ClearAllPoints()
	local p = self.cfg.configPoint
	if p and p.x and p.y then
		panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
		return
	end
	local f = self.frame
	local left, bottom = f:GetLeft(), f:GetBottom()
	if left and bottom then
		panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, bottom - 4)
	else
		panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

local function buildConfigPanel(self)
	-- Its OWN standalone, draggable window -- NOT anchored to the display window, so moving the
	-- tracker doesn't drag the (large) config panel with it and vice-versa. Positioned by
	-- ApplyConfigPos on open (near the window first time; remembers where you drag it).
	local panel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	self.configPanel = panel
	panel:SetSize(200, 200) -- resized to fit the 3 columns in RenderConfig
	panel:SetBackdrop(BACKDROP)
	panel:SetBackdropColor(0, 0, 0, 0.92)
	panel:SetFrameStrata("DIALOG")
	panel:SetClampedToScreen(true)
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:Hide()

	-- Draggable title bar across the top (leaves room for the close X on the right).
	local dragBar = CreateFrame("Frame", nil, panel)
	dragBar:SetPoint("TOPLEFT", 0, 0)
	dragBar:SetPoint("TOPRIGHT", -24, 0)
	dragBar:SetHeight(PAD + 16)
	dragBar:EnableMouse(true)
	dragBar:RegisterForDrag("LeftButton")
	dragBar:SetScript("OnDragStart", function() panel:StartMoving() end)
	dragBar:SetScript("OnDragStop", function() panel:StopMovingOrSizing(); self:SaveConfigPos() end)

	-- Per-window options block across the top of the panel (this window only).
	local opt = {}
	self.opt = opt
	local function fs(text, tmpl)
		local f = panel:CreateFontString(nil, "OVERLAY", tmpl or "GameFontHighlightSmall")
		f:SetText(text)
		return f
	end

	local title = fs("Window options  (this window only)", "GameFontNormalSmall")
	title:SetPoint("TOPLEFT", PAD, -PAD)
	title:SetTextColor(1, 0.82, 0)

	-- Row A: grow + align toggles.
	local growBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	growBtn:SetSize(104, 20)
	growBtn:SetPoint("TOPLEFT", PAD, -(PAD + 18))
	opt.growBtn = growBtn
	growBtn:SetScript("OnClick", function()
		self.cfg.growUp = not self.cfg.growUp
		self:NormalizeAnchor() -- keep the window put across the top/bottom flip
		self:ApplyPosition()
		self:BindOptions()
		self:Rebuild()
	end)

	local alignBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	alignBtn:SetSize(96, 20)
	alignBtn:SetPoint("LEFT", growBtn, "RIGHT", 6, 0)
	opt.alignBtn = alignBtn
	alignBtn:SetScript("OnClick", function()
		self.cfg.rightAlign = not self.cfg.rightAlign
		self:BindOptions()
		self:Rebuild()
	end)

	-- Row B: size slider + text size.
	local szLbl = fs("Size")
	szLbl:SetPoint("TOPLEFT", PAD, -(PAD + 44))
	sliderSeq = sliderSeq + 1
	local slider = CreateFrame("Slider", "FFTrackerSize" .. sliderSeq, panel, "OptionsSliderTemplate")
	slider:SetWidth(110)
	slider:SetPoint("LEFT", szLbl, "RIGHT", 8, 0)
	slider:SetMinMaxValues(1, 3)
	slider:SetValueStep(0.25)
	if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
	local sName = slider:GetName()
	if _G[sName .. "Low"] then _G[sName .. "Low"]:SetText("1x") end
	if _G[sName .. "High"] then _G[sName .. "High"]:SetText("3x") end
	if _G[sName .. "Text"] then _G[sName .. "Text"]:SetText("") end
	opt.sizeSlider = slider
	local szVal = fs("1x")
	szVal:SetPoint("LEFT", slider, "RIGHT", 8, 0)
	opt.sizeVal = szVal
	slider:SetScript("OnValueChanged", function(_, v)
		v = math.floor(v * 4 + 0.5) / 4 -- snap to 0.25 steps
		self.cfg.rowScale = v
		szVal:SetText(fmtScale(v))
		M.RefreshAll()
	end)

	local fsLbl = fs("Text size")
	fsLbl:SetPoint("LEFT", szVal, "RIGHT", 20, 0)
	local fontBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	fontBox:SetSize(34, 18)
	fontBox:SetPoint("LEFT", fsLbl, "RIGHT", 8, 0)
	fontBox:SetAutoFocus(false)
	fontBox:SetNumeric(true)
	fontBox:SetMaxLetters(2)
	fontBox:SetJustifyH("CENTER")
	opt.fontBox = fontBox
	local function commitFont()
		local v = tonumber(fontBox:GetText())
		if v then
			if v < 6 then v = 6 elseif v > 30 then v = 30 end
			self.cfg.fontSize = v
		end
		fontBox:SetText(tostring(self.cfg.fontSize or DEFAULT_FONT_SIZE))
		fontBox:ClearFocus()
		M.RefreshAll()
	end
	fontBox:SetScript("OnEnterPressed", commitFont)
	fontBox:SetScript("OnEditFocusLost", commitFont)
	fontBox:SetScript("OnEscapePressed", function()
		fontBox:SetText(tostring(self.cfg.fontSize or DEFAULT_FONT_SIZE))
		fontBox:ClearFocus()
	end)

	-- Row C: bar width in seconds (checkbox defaults it to the longest tracked duration).
	local barChk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	barChk:SetSize(20, 20)
	barChk:SetPoint("TOPLEFT", PAD - 2, -(PAD + 72))
	local barLbl = fs("Bar = longest duration")
	barLbl:SetPoint("LEFT", barChk, "RIGHT", 0, 0)
	opt.barChk = barChk
	local barBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	barBox:SetSize(40, 18)
	barBox:SetPoint("LEFT", barLbl, "RIGHT", 10, 0)
	barBox:SetAutoFocus(false)
	barBox:SetNumeric(true)
	barBox:SetMaxLetters(4)
	barBox:SetJustifyH("CENTER")
	opt.barBox = barBox
	local barSuffix = fs("sec")
	barSuffix:SetPoint("LEFT", barBox, "RIGHT", 3, 0)
	local function commitBar()
		local v = tonumber(barBox:GetText())
		if v and v > 0 then self.cfg.barMax = v end
		self:BindOptions()
		M.RefreshAll()
	end
	barBox:SetScript("OnEnterPressed", commitBar)
	barBox:SetScript("OnEditFocusLost", commitBar)
	barChk:SetScript("OnClick", function()
		-- Toggle from the config (the source of truth), NOT the widget's checked
		-- state: clicking the box can steal focus from the seconds EditBox, whose
		-- OnEditFocusLost commit re-runs BindOptions and leaves GetChecked() stale,
		-- which made re-checking "longest" silently do nothing.
		if self.cfg.barMax then
			self.cfg.barMax = nil -- back to the longest tracked duration
		else
			self.cfg.barMax = self.maxDur or 10
		end
		self:BindOptions()
		M.RefreshAll()
	end)

	-- Row D: only my auras.
	local onlyChk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	onlyChk:SetSize(20, 20)
	onlyChk:SetPoint("TOPLEFT", PAD - 2, -(PAD + 96))
	local onlyLbl = fs("Only my auras")
	onlyLbl:SetPoint("LEFT", onlyChk, "RIGHT", 0, 0)
	opt.only = onlyChk
	onlyChk:SetScript("OnClick", function(b)
		self.cfg.onlyMine = b:GetChecked() and true or false
		M.RefreshAll()
	end)

	-- Rows E/F: optional alert sounds (a checkbox + a sound dropdown each).
	local function soundRow(label, y, checkKey, idKey)
		local chk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		chk:SetSize(20, 20)
		chk:SetPoint("TOPLEFT", PAD - 2, -y)
		local lbl = fs(label)
		lbl:SetPoint("LEFT", chk, "RIGHT", 0, 0)
		sliderSeq = sliderSeq + 1
		local dd = CreateFrame("Frame", "FFTrackerSnd" .. sliderSeq, panel, "UIDropDownMenuTemplate")
		dd:SetPoint("TOPLEFT", panel, "TOPLEFT", 138, -(y - 4))
		UIDropDownMenu_SetWidth(dd, 96)
		UIDropDownMenu_Initialize(dd, function(_, level)
			for _, s in ipairs(SOUNDS) do
				local info = UIDropDownMenu_CreateInfo()
				info.text = s.name
				info.checked = (self.cfg[idKey] or (SOUNDS[1] and SOUNDS[1].id)) == s.id
				info.func = function()
					self.cfg[idKey] = s.id
					UIDropDownMenu_SetText(dd, s.name)
					if s.id then PlaySound(s.id, "Master") end
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end)
		chk:SetScript("OnClick", function(b)
			self.cfg[checkKey] = b:GetChecked() and true or false
			self:BindOptions()
		end)
		return chk, dd
	end
	opt.snd5, opt.snd5Dd = soundRow("Sound at 5s", PAD + 120, "sound5", "sound5Id")
	opt.sndExp, opt.sndExpDd = soundRow("Sound on expiry", PAD + 150, "soundExpire", "soundExpireId")

	-- Row G: show EVERY debuff on every visible enemy (nameplates + target/mouseover).
	-- This overrides the per-spell list below, which is greyed out while it's on.
	local allChk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	allChk:SetSize(20, 20)
	allChk:SetPoint("TOPLEFT", PAD - 2, -(PAD + 180))
	local allLbl = fs("Show ALL enemy debuffs (overrides the list)")
	allLbl:SetPoint("LEFT", allChk, "RIGHT", 0, 0)
	opt.allEnemy = allChk
	allChk:SetScript("OnClick", function(b)
		self.cfg.allEnemyDebuffs = b:GetChecked() and true or false
		M.RecomputeActiveSpells()
		if M.ScanNameplates then M.ScanNameplates() end
		if M.Rescan then M.Rescan() end
		self:RenderConfig() -- grey / un-grey the per-spell list live
		M.RefreshAll()
	end)

	-- Row H: group rows under a per-target header, ordered by when each mob was seen.
	local grpChk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	grpChk:SetSize(20, 20)
	grpChk:SetPoint("TOPLEFT", PAD - 2, -(PAD + 204))
	local grpLbl = fs("Group by target")
	grpLbl:SetPoint("LEFT", grpChk, "RIGHT", 0, 0)
	opt.groupBy = grpChk
	grpChk:SetScript("OnClick", function(b)
		self.cfg.groupByTarget = b:GetChecked() and true or false
		M.RefreshAll()
	end)

	-- Row I: compact icon-only grid (icon + cooldown swipe + number, wraps across
	-- then down). No names or bar.
	local gridChk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	gridChk:SetSize(20, 20)
	gridChk:SetPoint("TOPLEFT", PAD - 2, -(PAD + 228))
	local gridLbl = fs("Compact icon grid")
	gridLbl:SetPoint("LEFT", gridChk, "RIGHT", 0, 0)
	opt.iconGrid = gridChk
	gridChk:SetScript("OnClick", function(b)
		self.cfg.iconGrid = b:GetChecked() and true or false
		M.RefreshAll()
	end)

	-- Standard round red ✕ in the top-right corner of the panel.
	self.cfgClose = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	self.cfgClose:SetPoint("TOPRIGHT", 2, 2)
	self.cfgClose:SetScript("OnClick", function() panel:Hide() end)
end

local function buildWindow(cfg)
	local self = setmetatable({ cfg = cfg, icons = {}, sortBuf = {}, maxDur = 1 }, Window)

	local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	self.frame = frame
	frame:SetSize(cfg.width or DEFAULT_W, HEADER_H + PAD * 2)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetBackdrop(BACKDROP)
	frame:SetBackdropColor(0, 0, 0, 0.85)
	frame:SetMovable(true)
	frame:SetResizable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	if frame.SetResizeBounds then
		frame:SetResizeBounds(MIN_W, 10, MAX_W, 10000)
	elseif frame.SetMinResize then
		frame:SetMinResize(MIN_W, 10)
		frame:SetMaxResize(MAX_W, 10000)
	end
	frame:SetScript("OnDragStart", function()
		if not self.cfg.locked then frame:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		self:NormalizeAnchor()
	end)

	self.closeBtn = iconButton(frame, 14, nil, "Delete this window", function()
		M.RemoveWindow(self)
	end)
	local x = self.closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	x:SetPoint("CENTER")
	x:SetText("x")

	self.lockBtn = iconButton(frame, 14, nil, "Lock / unlock this window", function()
		self.cfg.locked = not self.cfg.locked
		self:ApplyLock()
		self:Rebuild()
	end)
	self.lockBtn:SetPoint("RIGHT", self.closeBtn, "LEFT", -2, 0)

	self.addBtn = iconButton(frame, 14, "Interface\\Buttons\\UI-PlusButton-Up",
		"New window", function() M.AddWindow() end)
	self.addBtn:SetPoint("RIGHT", self.lockBtn, "LEFT", -2, 0)

	-- A spellbook icon (evokes "spells") opens the spells + per-window options panel.
	self.gearBtn = iconButton(frame, 14, "Interface\\Icons\\INV_Misc_Book_09",
		"Spells & window options", function() self:ToggleConfig() end)
	local gt = self.gearBtn:GetNormalTexture()
	if gt then cropIcon(gt) end
	self.gearBtn:SetPoint("RIGHT", self.addBtn, "LEFT", -2, 0)

	local resize = CreateFrame("Button", nil, frame)
	self.resize = resize
	resize:SetSize(14, 14)
	resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	resize:SetScript("OnMouseDown", function()
		if not self.cfg.locked then frame:StartSizing("RIGHT") end
	end)
	resize:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		self.cfg.width = frame:GetWidth()
		self:NormalizeAnchor()
		self:Rebuild()
	end)

	buildConfigPanel(self)

	if not cfg.spells then cfg.spells = {} end
	self:LayoutHeader()
	self:ApplyPosition()
	self:ApplyLock()
	return self
end

local deadPool = {}
local function acquireWindow(cfg)
	local self = table.remove(deadPool)
	if not self then return buildWindow(cfg) end
	self.cfg = cfg
	if not cfg.spells then cfg.spells = {} end
	hidePool(self.icons)
	self.configPanel:Hide()
	self.frame:SetWidth(cfg.width or DEFAULT_W)
	self:LayoutHeader()
	self:ApplyPosition()
	self:ApplyLock()
	self.frame:Hide()
	return self
end

-- ==========================================================================
-- Module API
-- ==========================================================================
function M.DefaultWindowConfig()
	-- Seed this class's default spells if it has any; classes with none
	-- (Hunter/Shaman/Paladin) start empty rather than seeding a foreign spell. A
	-- manually-added window for those just opens blank for the gear menu.
	local _, cls = UnitClass("player")
	local defaults = M.CLASS_DEFAULT_SPELLS and M.CLASS_DEFAULT_SPELLS[cls]
	local spells = {}
	if defaults then
		for _, key in ipairs(defaults) do spells[key] = { enabled = true } end
	end
	return {
		width = DEFAULT_W,
		locked = false,
		point = { point = "TOPLEFT", relP = "CENTER", x = -100, y = 150 },
		spells = spells,
	}
end

function M.BuildWindows()
	for _, cfg in ipairs(M.db.windows) do
		M.windows[#M.windows + 1] = acquireWindow(cfg)
	end
	M.RefreshAll()
end

function M.RefreshAll()
	for _, w in ipairs(M.windows) do w:Rebuild() end
end

function M.UpdateVisibleRows(now)
	curTargetGUID = UnitGUID("target") -- resolved once per frame; the windows read it
	for _, w in ipairs(M.windows) do w:UpdateVisible(now) end
end

-- Animate the bars/glow every frame (not just on the 0.05s state ticker) so the
-- bars drain smoothly and all in step. This ALWAYS-ON OnUpdate is a module-owned
-- frame gated by Enable/Disable: M.StartAnimator wires it up in M.Enable and
-- M.StopAnimator (frame:SetScript(nil)) clears it in M.Disable, so a disabled
-- module leaves nothing firing per-frame.
local animator = CreateFrame("Frame")
local function animOnUpdate() M.UpdateVisibleRows(GetTime()) end
function M.StartAnimator() animator:SetScript("OnUpdate", animOnUpdate) end
function M.StopAnimator() animator:SetScript("OnUpdate", nil) end

-- Tear down every window (used by M.Disable): hide + pool them and clear the live
-- list so a later M.Enable -> BuildWindows rebuilds fresh without duplicating.
function M.DestroyWindows()
	for _, w in ipairs(M.windows) do
		w:Destroy()
		deadPool[#deadPool + 1] = w
	end
	wipe(M.windows)
end

function M.WindowCount()
	return #M.windows
end

function M.IsUnlocked()
	for _, w in ipairs(M.windows) do
		if not w.cfg.locked then return true end
	end
	return false
end

-- Lock/unlock every window (locked = just the bars/icons). Pure apply: with no
-- windows it does nothing (the umbrella's tri-state drives this via SetDisplayState,
-- which must never silently spawn a window). Create windows via BuildSettings' "New
-- window" button or `/fft new`.
local function setLockAll(locked)
	for _, w in ipairs(M.windows) do
		w.cfg.locked = locked
		w:ApplyLock()
	end
	M.RefreshAll()
end
function M.LockAll() setLockAll(true) end
function M.UnlockAll() setLockAll(false) end
function M.ToggleLockAll() -- slash /fft
	if #M.windows == 0 then M.AddWindow(); return end
	setLockAll(M.IsUnlocked())
end

function M.AddWindow()
	local cfg = M.DefaultWindowConfig() -- starts with the class's default spell
	local last = M.db.windows[#M.db.windows]
	if last and last.point then
		cfg.point = {
			point = "TOPLEFT", relP = last.point.relP or "CENTER",
			x = (last.point.x or 0) + 96, y = (last.point.y or 0) - 96,
		}
	end
	table.insert(M.db.windows, cfg)
	local w = acquireWindow(cfg)
	M.windows[#M.windows + 1] = w
	M.RecomputeActiveSpells()
	if M.Rescan then M.Rescan() end -- show an aura already on your target/mouseover
	M.RefreshAll()
	w:ToggleConfig()
end

function M.RemoveWindow(w)
	for i, win in ipairs(M.windows) do
		if win == w then table.remove(M.windows, i); break end
	end
	for i, cfg in ipairs(M.db.windows) do
		if cfg == w.cfg then table.remove(M.db.windows, i); break end
	end
	w:Destroy()
	deadPool[#deadPool + 1] = w
	-- Zero windows is allowed; recreate one via BuildSettings' "New window" or `/fft new`.
	M.RecomputeActiveSpells()
	M.RefreshAll()
end

-- --- shared Settings page --------------------------------------------------
-- FF Tracker has no single global config: each window carries its OWN spells +
-- options in a pop-out gear panel (the book icon on the window, shown while
-- unlocked). So this umbrella Settings subcategory is just the shared Display
-- tri-state plus a "New window" button; per-window tuning stays on each window.
-- core.AddSubcategory calls this with a fresh canvas frame, titled "FF Tracker".
function M.BuildSettings(panel)
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -16)
	title:SetText("FF Tracker")
	title:SetTextColor(1, 0.82, 0)

	core.DisplayControl(panel, 14, -46, M) -- shared Hidden / Unlocked / Locked tri-state

	local help = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", 16, -80)
	help:SetWidth(440)
	help:SetJustifyH("LEFT")
	help:SetText("Aura countdown bars in movable panels. Unlock the display, then click the "
		.. "book icon on a window to choose spells and per-window options. Each window keeps "
		.. "its own spell list, size, grow direction and sounds.")

	local addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	addBtn:SetSize(150, 22)
	addBtn:SetPoint("TOPLEFT", 16, -128)
	addBtn:SetText("New window")
	addBtn:SetScript("OnClick", function()
		-- A new window must be enabled + unlocked to be visible/configurable.
		if core.GetModuleState("ff") == "hidden" then core.SetModuleState("ff", "unlocked") end
		M.AddWindow()
	end)
end
