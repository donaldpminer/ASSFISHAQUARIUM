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

-- Display only: abbreviate the raw points (~ extra physical damage enabled) with K / M so big
-- raid totals stay readable. Sorting + bar length use the raw p.total, never this string.
local function fmt(n)
	if n >= 1e3 then
		local v, suffix = n / 1e3, "K"
		if v >= 999.5 then v, suffix = v / 1e3, "M" end -- would round to "1000K" -> show as M
		return string.format(v >= 10 and "%.0f%s" or "%.1f%s", v, suffix)
	end
	return string.format("%d", n + 0.5)
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

-- The "?" help tooltip: how points are computed + the assumptions behind them.
local function showHelpTooltip(anchor)
	GameTooltip:SetOwner(anchor, "ANCHOR_BOTTOMRIGHT")
	GameTooltip:AddLine("Sunderboard - how points work")
	GameTooltip:AddLine("For each physical, non-bleed hit on a debuffed target, it works out the EXTRA damage the stripped armor let through (versus the mob's full armor), then splits that among the active armor debuffs by how much armor each one removes, credited to whoever applied them. Points are that extra physical damage enabled.", 1, 1, 1, true)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Assumptions:", 1, 0.82, 0)
	GameTooltip:AddLine("- Target base armor is ESTIMATED from level, not read: melee/boss tier is 3731 at level 63 and ~55 less per level below; caster bosses ~3009. Low-level mobs are rough.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- Damage reduction assumes a level-60 attacker:  armor / (armor + 5500).", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- Only physical damage counts; bleeds ignore armor and are excluded.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- Armor stripped (max rank): Sunder 450/stack, Expose 3825, Faerie Fire 505, Curse of Recklessness 640.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- Sunder credit is split among warriors by stacks landed; refreshing a maxed (5) stack and missed/resisted casts don't count.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- The number left of each name is that player's landed, non-refresh applications.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine("- Runs where the Show setting says: while grouped, only in an instance, or always.", 0.9, 0.9, 0.9, true)
	GameTooltip:Show()
end

local function createRow(i)
	local bar = CreateFrame("StatusBar", nil, frame)
	bar:SetStatusBarTexture(BAR_TEX)
	bar:SetSize(WIDTH - 12, ROW_H - 2)
	bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -(TOPPAD + (i - 1) * ROW_H))

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
	frame:SetBackdrop(core.WINDOW_BACKDROP) -- shared dark-parchment window (like FF Tracker / Mobber)
	frame:SetBackdropColor(0, 0, 0, 0.85)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", function(s) if not M.db.locked then s:StartMoving() end end)
	frame:SetScript("OnDragStop", function(s) s:StopMovingOrSizing(); UI:SavePos() end)
	restorePos()

	-- header: title + buttons sit on the backdrop, no coloured title strip
	header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	header:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -7)
	header:SetText("Sunderboard")

	-- Textured header buttons (matching FF Tracker's icon-button style), not letters.
	-- X: standard textured close button; turns the module off.
	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetSize(20, 20)
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
	close:SetScript("OnClick", function() core.SetModuleState("sb", "hidden") end)
	UI.closeBtn = close -- hidden while locked (see ApplyLock)

	-- R: reset the leaderboard (refresh icon).
	local reset = W.iconButton(frame, 16, "Interface\\Icons\\Ability_Hunter_Readiness",
		"Reset the leaderboard", function() M.Core:Reset() end)
	core.CropIcon(reset:GetNormalTexture())
	reset:SetPoint("RIGHT", close, "LEFT", 0, 0)

	-- ?: how scoring works (question-mark icon).
	local help = W.iconButton(frame, 16, "Interface\\Icons\\INV_Misc_QuestionMark", nil, nil)
	core.CropIcon(help:GetNormalTexture())
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

-- Synthesized lock, matching FF Tracker / Mobber: locked = not draggable AND no window
-- backdrop (clean borderless HUD; the per-row bars keep their own background so it stays
-- readable), and the close button hides. Unlocked = draggable, backdrop + close shown.
function UI:ApplyLock()
	if not frame then return end
	local locked = M.db.locked
	frame:EnableMouse(not locked)
	if locked then
		frame:SetBackdrop(nil)
	else
		frame:SetBackdrop(core.WINDOW_BACKDROP)
		frame:SetBackdropColor(0, 0, 0, 0.85)
	end
	if UI.closeBtn then UI.closeBtn:SetShown(not locked) end
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

	core.DisplayControl(panel, 14, -40, M) -- shared Disabled / Unlocked / Locked tri-state

	syncs[#syncs + 1] = W.radioRow(panel, 14, -74, "Show:",
		{ { text = "Group", value = "group" }, { text = "Instance", value = "instance" }, { text = "Always", value = "always" } },
		function() return M.db.settings.scope or "group" end,
		function(v) M.db.settings.scope = v; if M.UpdateSession then M.UpdateSession() end end).sync

	syncs[#syncs + 1] = W.radioRow(panel, 14, -104, "Fall-off alerts:",
		{ { text = "Mine", value = "mine" }, { text = "All", value = "all" }, { text = "Off", value = "off" } },
		function() return M.db.settings.notifyFalloff or "mine" end,
		function(v) M.db.settings.notifyFalloff = v end).sync

	syncs[#syncs + 1] = W.slider(panel, 14, -140, "Fall-off min uptime (s)", 0, 10, 1,
		function() return M.db.settings.falloffMinUptime or 3 end,
		function(v) M.db.settings.falloffMinUptime = v end).sync

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(160, 22)
	reset:SetPoint("TOPLEFT", 14, -188)
	reset:SetText("Reset leaderboard")
	reset:SetScript("OnClick", function()
		M.Core:Reset()
		print("|cffff8000Sunderboard|r: leaderboard reset.")
	end)

	local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 14, -220)
	note:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
	note:SetJustifyH("LEFT")
	note:SetWordWrap(true)
	note:SetText("Scores physical damage dealt through armor debuffs (Sunder / Expose / Faerie Fire / Curse of Recklessness). Use Show to choose where it runs: while grouped, only in an instance, or always.")

	local function refresh() for _, s in ipairs(syncs) do s() end end
	panel.refresh = refresh
	panel:SetScript("OnShow", refresh)
	refresh()
end
