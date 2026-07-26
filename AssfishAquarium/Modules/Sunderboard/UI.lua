-- Sunderboard :: UI.lua
-- A compact Details!-style leaderboard: one class-colored bar per player,
-- sorted by points, with a draggable title bar and reset/close buttons.
--
-- Assfish Aquarium module: the umbrella owns the single minimap button, so this
-- file has NO minimap of its own. Visibility + lock are driven by the shared
-- tri-state (see Core.lua's Enable/Disable/SetDisplayState), not a private flag.

local ADDON, ns = ...
local core = ns.core
local W = core.widgets
local M = ns.modules.sb
local D = M.Data

local UI = {}
M.UI = UI

local WIDTH   = 236
local ROW_H   = 18
local TOPPAD  = 22    -- title-bar height
local BOTPAD  = 6
local MAXROWS = 25
local COUNT_W = 24    -- width of the left "landed applications" column
local NAME_X  = COUNT_W + 8
local BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"

local frame, header, rows
local dirty, elapsed = false, 0

local function fmt(n)
	return string.format("%d", n / 1000 + 0.5)  -- score/1000, no decimals, no suffix
end

local function sortedPlayers()
	local list = {}
	for _, p in pairs(M.session.points) do
		if p.total and p.total > 0 then list[#list + 1] = p end
	end
	table.sort(list, function(a, b)
		if a.total == b.total then return (a.name or "") < (b.name or "") end
		return a.total > b.total
	end)
	return list
end

-- header text: "Sunderboard - <raid>" plus a hint when empty
local function headerText()
	local s = M.session
	local base = "Sunderboard"
	if s.label then base = base .. " - " .. s.label end
	if not next(s.points) then base = base .. " (no data)" end
	return base
end

-- ------------------------------------------------------------------ build --

function UI:SavePos()
	if not (frame and M.db) then return end
	local point, _, relPoint, x, y = frame:GetPoint()
	M.db.framePos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function restorePos()
	frame:ClearAllPoints()
	local fp = M.db and M.db.framePos
	if fp then
		frame:SetPoint(fp.point, UIParent, fp.relPoint, fp.x, fp.y)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
	end
end

local function makeTextButton(parent, text)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(16, 16)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetAllPoints(b)
	fs:SetJustifyH("CENTER")
	fs:SetText(text)
	b:SetFontString(fs)
	b:SetScript("OnEnter", function(s) fs:SetTextColor(1, 0.82, 0) end)
	b:SetScript("OnLeave", function(s) fs:SetTextColor(1, 1, 1) end)
	return b
end

-- The "?" help tooltip: explains how points are computed.
local function showHelpTooltip(anchor)
	GameTooltip:SetOwner(anchor, "ANCHOR_BOTTOMRIGHT")
	GameTooltip:AddLine("Sunderboard - how points work")
	GameTooltip:AddLine("Each physical hit on a debuffed target is divided among the active armor debuffs in proportion to how much armor each one removes, and credited to whoever applied them.", 1, 1, 1, true)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("- Only physical damage counts; bleeds ignore armor and are excluded.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- Sunder credit is split among warriors by how many stacks they land. Refreshing an already-maxed (5-stack) debuff, and missed or resisted casts, do not count.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- The number left of each name is that player's count of landed, non-refresh applications.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- Score shown = points / 1000.", 0.9, 0.9, 0.9, true)
	GameTooltip:Show()
end

local function createRow(i)
	local bar = CreateFrame("StatusBar", nil, frame)
	bar:SetStatusBarTexture(BAR_TEX)
	bar:SetSize(WIDTH - 8, ROW_H - 2)
	bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -(TOPPAD + (i - 1) * ROW_H))

	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetColorTexture(0.15, 0.15, 0.15, 0.8)

	-- left column: landed, non-refresh applications (right-justified so it lines up)
	bar.count = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.count:SetPoint("LEFT", bar, "LEFT", 4, 0)
	bar.count:SetWidth(COUNT_W)
	bar.count:SetJustifyH("RIGHT")

	bar.left = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.left:SetPoint("LEFT", bar, "LEFT", NAME_X, 0)
	bar.left:SetPoint("RIGHT", bar, "RIGHT", -44, 0)
	bar.left:SetJustifyH("LEFT")
	bar.left:SetWordWrap(false)

	bar.right = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.right:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
	bar.right:SetJustifyH("RIGHT")

	rows[i] = bar
	return bar
end

function UI:Build()
	if frame then return end

	frame = CreateFrame("Frame", "SunderboardFrame", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, TOPPAD + ROW_H + BOTPAD)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 1,
	})
	frame:SetBackdropColor(0, 0, 0, 0.82)
	frame:SetBackdropBorderColor(0, 0, 0, 1)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", function(s) if not M.db.locked then s:StartMoving() end end)
	frame:SetScript("OnDragStop", function(s) s:StopMovingOrSizing(); UI:SavePos() end)
	restorePos()

	-- title bar
	local strip = frame:CreateTexture(nil, "ARTWORK")
	strip:SetPoint("TOPLEFT", 1, -1)
	strip:SetPoint("TOPRIGHT", -1, -1)
	strip:SetHeight(TOPPAD - 2)
	strip:SetColorTexture(0.5, 0.19, 0.0, 0.9)  -- burnt orange

	header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	header:SetPoint("LEFT", strip, "LEFT", 6, 0)
	header:SetText("Sunderboard")

	-- X: turn the whole module off (the umbrella's master switch = hidden state).
	local close = makeTextButton(frame, "X")
	close:SetPoint("RIGHT", strip, "RIGHT", -4, 0)
	close:SetScript("OnClick", function() core.SetModuleState("sb", "hidden") end)

	local reset = makeTextButton(frame, "R")
	reset:SetPoint("RIGHT", close, "LEFT", -2, 0)
	reset:SetScript("OnClick", function() M.Core:Reset() end)

	local help = makeTextButton(frame, "?")
	help:SetPoint("RIGHT", reset, "LEFT", -2, 0)
	help:SetScript("OnEnter", function(self) showHelpTooltip(self) end)
	help:SetScript("OnLeave", function() GameTooltip:Hide() end)

	rows = {}
	createRow(1)

	frame:SetScript("OnUpdate", function(_, e)
		elapsed = elapsed + e
		if elapsed >= 0.5 then
			elapsed = 0
			if dirty then dirty = false; UI:Refresh() end
		end
	end)

	UI:ApplyLock()
	UI:Refresh()
	UI:UpdateVisibility()
end

-- ---------------------------------------------------------------- refresh --

function UI:MarkDirty()
	dirty = true
end

function UI:Refresh()
	if not frame then return end
	local list = sortedPlayers()
	local maxv = (list[1] and list[1].total) or 1
	local n = math.min(#list, MAXROWS)

	for i = 1, n do
		local p = list[i]
		local bar = rows[i] or createRow(i)
		local c = (p.class and RAID_CLASS_COLORS[p.class]) or { r = 0.7, g = 0.7, b = 0.7 }
		bar:SetStatusBarColor(c.r, c.g, c.b)
		bar:SetMinMaxValues(0, maxv)
		bar:SetValue(p.total)
		local eff = 0
		if p.effective then
			for _, key in ipairs(D.KEYS) do eff = eff + (p.effective[key] or 0) end
		end
		bar.count:SetText(eff > 0 and tostring(math.floor(eff)) or "")
		bar.left:SetText(p.name or "?")
		bar.right:SetText(fmt(p.total))
		bar:Show()
	end
	for i = n + 1, #rows do rows[i]:Hide() end

	header:SetText(headerText())
	frame:SetHeight(TOPPAD + math.max(n, 1) * ROW_H + BOTPAD)
end

-- ------------------------------------------------------------- visibility --

-- Shown while UNLOCKED (so it can always be positioned) or, when LOCKED, only
-- while grouped / in an instance (session.visible). Hiding the module entirely is
-- the "hidden" tri-state, handled by Disable.
function UI:UpdateVisibility()
	if not frame then return end
	if (not M.db.locked) or M.session.visible then
		frame:Show()
		UI:Refresh()
	else
		frame:Hide()
	end
end

-- Force-hide (used by Disable and the /sb hide path via SetModuleState).
function UI:Hide()
	if frame then frame:Hide() end
end

-- --------------------------------------------------------------- lock ------

-- Synthesized lock: locked = the board can't be dragged (its background stays, so
-- it remains readable). Unlocked = draggable.
function UI:ApplyLock()
	if not frame then return end
	frame:EnableMouse(not M.db.locked)
end

-- --------------------------------------------------------------- settings --

-- Fill the shared Settings canvas with Sunderboard's controls (core registers the
-- subcategory + calls this). Replaces the standalone addon's own options screen.
function M.BuildSettings(panel)
	if M.InitDB then M.InitDB() end -- ensure M.db.settings exists (this runs at login, before Enable)
	local syncs = {}

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 14, -14)
	title:SetText("Sunderboard")
	title:SetTextColor(1, 0.82, 0)

	core.DisplayControl(panel, 14, -40, M) -- shared Hidden / Unlocked / Locked tri-state

	syncs[#syncs + 1] = W.radioRow(panel, 14, -74, "Fall-off alerts:",
		{ { text = "Mine", value = "mine" }, { text = "All", value = "all" }, { text = "Off", value = "off" } },
		function() return M.db.settings.notifyFalloff or "mine" end,
		function(v) M.db.settings.notifyFalloff = v end).sync

	syncs[#syncs + 1] = W.slider(panel, 14, -110, "Fall-off min uptime (s)", 0, 10, 1,
		function() return M.db.settings.falloffMinUptime or 3 end,
		function(v) M.db.settings.falloffMinUptime = v end).sync

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(160, 22)
	reset:SetPoint("TOPLEFT", 14, -158)
	reset:SetText("Reset leaderboard")
	reset:SetScript("OnClick", function()
		M.Core:Reset()
		print("|cffff8000Sunderboard|r: leaderboard reset.")
	end)

	local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 14, -190)
	note:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
	note:SetJustifyH("LEFT")
	note:SetWordWrap(true)
	note:SetText("Scores physical damage dealt through armor debuffs (Sunder / Expose / Faerie Fire / Curse of Recklessness). Only counts inside a dungeon or raid.")

	local function refresh() for _, s in ipairs(syncs) do s() end end
	panel.refresh = refresh
	panel:SetScript("OnShow", refresh)
	refresh()
end
