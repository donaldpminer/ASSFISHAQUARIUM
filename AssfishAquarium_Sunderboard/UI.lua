-- Sunderboard :: UI.lua
-- A compact Details!-style leaderboard: one class-colored bar per player,
-- sorted by points, with a draggable title bar and reset/close buttons.
--
-- Assfish Aquarium module: the umbrella owns the single minimap button, so this
-- file has NO minimap of its own. Visibility + lock are driven by the shared
-- tri-state (see Core.lua's Enable/Disable/SetDisplayState), not a private flag.
--
-- The window is RESIZABLE while unlocked (drag the bottom-right grip): dragging it
-- SHORTER shows fewer rows and the overflow scrolls (mouse wheel); dragging it WIDER
-- just widens the bars. Until it's resized once it auto-grows to fit its rows.
-- Hovering a row shows a per-debuff breakdown (casts / landed / outcome %).

local ns = AssfishAquarium
local core = ns.core
local W = core.widgets
local M = ns.modules.sb
local D = M.Data

local UI = {}
M.UI = UI

local WIDTH   = 236   -- default width (also the minimum sensible width)
local MINW    = 170
local MAXW    = 520
local ROW_H   = 18
local TOPPAD  = 22    -- title-bar height
local BOTPAD  = 14    -- leaves room for the resize grip + scroll hint under the last row
local MAXROWS = 40    -- hard ceiling on rendered rows (full raid)
local NAME_X  = 6     -- left padding of the player name inside a bar
local BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"
local MINH    = TOPPAD + ROW_H + BOTPAD
local MAXH    = TOPPAD + MAXROWS * ROW_H + BOTPAD

local frame, header, rows, sizer
local dirty, elapsed = false, 0
local offset = 0          -- scroll position (index into the sorted list)
local autoHeight = true   -- true until the user resizes; then their height is kept

-- Miss outcomes, in a stable display order with friendly labels.
local MISS_ORDER = { "DODGE", "PARRY", "MISS", "BLOCK", "DEFLECT", "RESIST", "IMMUNE", "ABSORB", "REFLECT", "EVADE" }
local MISS_LABEL = {
	DODGE = "Dodged", PARRY = "Parried", MISS = "Missed", BLOCK = "Blocked",
	DEFLECT = "Deflected", RESIST = "Resisted", IMMUNE = "Immune",
	ABSORB = "Absorbed", REFLECT = "Reflected", EVADE = "Evaded",
}

-- Canonical outcome rows shown for each debuff, ALWAYS (zeros included) so the tooltip layout
-- is identical whether someone has 500 sunders or none -- people learn to expect it. Exception:
-- the "refok" row is only drawn when it's non-zero (see showRowTooltip), so a clean 5-stack rota
-- doesn't carry a permanent "Refreshed in time 0" line.
-- Tokens: "eff" = added a stack / freshly applied; "refok" = a NEEDED refresh (<=16s left,
-- counts as effective); "early" = a redundant refresh (more time left, no credit); the rest are
-- miss types. Melee debuffs can be dodged/parried/missed; spells resisted (not dodged/parried).
local OUTCOME_ROWS = {
	sunder = { { "eff", "Effective stack added" }, { "refok", "Refreshed in time" }, { "early", "Redundant" }, { "DODGE", "Dodged" }, { "PARRY", "Parried" }, { "MISS", "Missed" } },
	expose = { { "eff", "Applied" },               { "refok", "Refreshed in time" }, { "early", "Redundant" }, { "DODGE", "Dodged" }, { "PARRY", "Parried" }, { "MISS", "Missed" } },
	faerie = { { "eff", "Applied" },               { "refok", "Refreshed in time" }, { "early", "Redundant" }, { "RESIST", "Resisted" } },
	reck   = { { "eff", "Applied" },               { "refok", "Refreshed in time" }, { "early", "Redundant" }, { "RESIST", "Resisted" } },
}

-- Display only: abbreviate the raw points (~ extra physical damage enabled) with K / M so big
-- raid totals stay readable. Sorting + bar length use the raw p.total, never this string.
local function fmt(n)
	n = n or 0
	if n >= 1e3 then
		local v, suffix = n / 1e3, "K"
		if v >= 999.5 then v, suffix = v / 1e3, "M" end -- would round to "1000K" -> show as M
		return string.format(v >= 10 and "%.0f%s" or "%.1f%s", v, suffix)
	end
	return string.format("%d", n + 0.5)
end

local function pctStr(n, d)
	if not d or d <= 0 then return "" end
	return string.format("%d%%", math.floor(100 * n / d + 0.5))
end

-- Show every player who has scored, PLUS every warrior currently in the raid (even at
-- 0 -- Core's roster scan seeds them). Zero-score non-warriors stay hidden until they score.
local function sortedPlayers()
	local list = {}
	local warriors = M.session.rosterWarriors
	for guid, p in pairs(M.session.points) do
		if (p.total and p.total > 0) or (warriors and warriors[guid]) then
			list[#list + 1] = p
		end
	end
	table.sort(list, function(a, b)
		local at, bt = a.total or 0, b.total or 0
		if at == bt then return (a.name or "") < (b.name or "") end
		return at > bt
	end)
	return list
end

-- ------------------------------------------------------------- row tooltip --

-- Whether to render a section for `key`: any activity on it, OR -- so a fresh warrior
-- still gets the familiar Sunder template full of zeros -- the sunder line for warriors.
local function shouldShow(p, key)
	local casts = p.casts and p.casts[key] or 0
	local eff = p.effective and p.effective[key] or 0
	local refok = p.refreshok and p.refreshok[key] or 0
	local m = p.misses and p.misses[key]
	if casts > 0 or eff > 0 or refok > 0 or (m and next(m)) then return true end
	return key == "sunder" and p.class == "WARRIOR"
end

-- Count for one canonical outcome token (eff / refok / early / a miss type).
local function outcomeCount(p, key, token, early)
	if token == "eff" then return (p.effective and p.effective[key]) or 0 end
	if token == "refok" then return (p.refreshok and p.refreshok[key]) or 0 end
	if token == "early" then return early end
	local m = p.misses and p.misses[key]
	return (m and m[token]) or 0
end

-- Per-player breakdown, one section per relevant armor debuff: total casts, how many were
-- EFFECTIVE (added a stack / applied -- refreshes and misses don't count), then the CANONICAL
-- outcome rows -- always the same rows with zeros filled in, plus any exotic miss type that
-- actually happened. "Refresh" = landed but added no stack / re-applied an existing debuff
-- (no scoring gain); it's the remainder of casts that neither missed nor did work.
local function showRowTooltip(anchor, p)
	if not p then return end
	GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
	local c = (p.class and RAID_CLASS_COLORS[p.class]) or { r = 1, g = 1, b = 1 }
	GameTooltip:AddDoubleLine(p.name or "?", fmt(p.total), c.r, c.g, c.b, 1, 0.82, 0)

	for _, key in ipairs(D.KEYS) do
		if shouldShow(p, key) then
			local casts = (p.casts and p.casts[key]) or 0
			local eff = (p.effective and p.effective[key]) or 0
			local refOk = (p.refreshok and p.refreshok[key]) or 0
			local m = p.misses and p.misses[key]
			local missTotal = 0
			if m then for _, mn in pairs(m) do missTotal = missTotal + mn end end
			-- effective = casts that did real work: added a stack / applied, PLUS needed refreshes
			-- (kept the debuff alive). Early refreshes and misses don't count.
			local successful = eff + refOk
			local early = casts - successful - missTotal
			if early < 0 then early = 0 end

			GameTooltip:AddLine(" ")
			GameTooltip:AddDoubleLine(D.LABEL[key],
				string.format("%d cast%s, %d effective", casts, casts == 1 and "" or "s", successful),
				1, 0.82, 0, 0.85, 0.85, 0.85)

			local shown = {}
			for _, row in ipairs(OUTCOME_ROWS[key]) do
				local token, label = row[1], row[2]
				if token ~= "eff" and token ~= "refok" and token ~= "early" then shown[token] = true end
				local n = outcomeCount(p, key, token, early)
				-- "Refreshed in time" is not part of the permanent zeros template: only show it
				-- when it actually happened, so a clean rotation doesn't carry a 0 line for it.
				if not (token == "refok" and n == 0) then
					local cr, cg, cb
					if n == 0 then
						cr, cg, cb = 0.5, 0.5, 0.5           -- dim the zeros so real numbers pop
					elseif token == "eff" or token == "refok" then
						cr, cg, cb = 0.6, 1, 0.6             -- credited (green)
					elseif token == "early" then
						cr, cg, cb = 0.85, 0.8, 0.5          -- redundant refresh (muted yellow)
					else
						cr, cg, cb = 1, 0.6, 0.6             -- avoided (red)
					end
					GameTooltip:AddDoubleLine("  " .. label,
						string.format("%d  %s", n, pctStr(n, casts)), cr, cg, cb, 0.7, 0.7, 0.7)
				end
			end

			-- any miss type outside the canonical set that actually occurred
			if m then
				for _, mt in ipairs(MISS_ORDER) do
					local mn = m[mt]
					if mn and mn > 0 and not shown[mt] then
						GameTooltip:AddDoubleLine("  " .. (MISS_LABEL[mt] or mt),
							string.format("%d  %s", mn, pctStr(mn, casts)), 1, 0.6, 0.6, 0.7, 0.7, 0.7)
					end
				end
			end
		end
	end
	GameTooltip:Show()
end

-- ------------------------------------------------------------------ build --

function UI:SavePos()
	if not (frame and M.db) then return end
	local point, _, relPoint, x, y = frame:GetPoint()
	M.db.framePos = { point = point, relPoint = relPoint, x = x, y = y }
end

function UI:SaveSize()
	if not (frame and M.db) then return end
	M.db.frameSize = { w = frame:GetWidth(), h = frame:GetHeight() }
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

-- A saved size means the user has taken manual control (fixed height + scrolling);
-- otherwise we start at the default width and let Refresh auto-grow to fit the rows.
local function restoreSize()
	local fs = M.db and M.db.frameSize
	if fs and fs.w and fs.h then
		autoHeight = false
		frame:SetSize(math.max(MINW, math.min(MAXW, fs.w)), math.max(MINH, math.min(MAXH, fs.h)))
	else
		autoHeight = true
		frame:SetSize(WIDTH, MINH)
	end
end

-- Rows that fit in the current (manual) height (floored so the bottom pad -- the
-- resize grip + scroll hint -- always stays clear of the last row).
local function fitRows()
	local n = math.floor((frame:GetHeight() - TOPPAD - BOTPAD) / ROW_H)
	if n < 1 then n = 1 elseif n > MAXROWS then n = MAXROWS end
	return n
end

-- The "?" help tooltip: a terse note on what the points mean.
local function showHelpTooltip(anchor)
	GameTooltip:SetOwner(anchor, "ANCHOR_BOTTOMRIGHT")
	GameTooltip:AddLine("Sunderboard")
	GameTooltip:AddLine("Points ~ the extra physical damage each armor debuff let through (mob armor is estimated from level). Bleeds don't count.", 1, 1, 1, true)
	GameTooltip:AddLine("Bar length = score; Sunder split among warriors by effective sunders.", 0.8, 0.8, 0.8, true)
	GameTooltip:AddLine("Hover a row for a per-debuff cast / landed / outcome breakdown.", 0.8, 0.8, 0.8, true)
	GameTooltip:AddLine("Drag the bottom-right grip to resize; shrink it and scroll with the mouse wheel.", 0.8, 0.8, 0.8, true)
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

	bar.left = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.left:SetPoint("LEFT", bar, "LEFT", NAME_X, 0)
	bar.left:SetPoint("RIGHT", bar, "RIGHT", -44, 0)
	bar.left:SetJustifyH("LEFT")
	bar.left:SetWordWrap(false)

	bar.right = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.right:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
	bar.right:SetJustifyH("RIGHT")

	-- Rows keep their own mouse ALWAYS (even when the board is locked) so you can hover
	-- for the breakdown mid-raid, just like Mobber's icon tooltips. The frame's own mouse
	-- (drag/resize) is what the lock gates, not the rows'.
	bar:EnableMouse(true)
	bar:SetScript("OnEnter", function(self) showRowTooltip(self, self.player) end)
	bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

	rows[i] = bar
	return bar
end

function UI:Build()
	if frame then return end

	frame = CreateFrame("Frame", "SunderboardFrame", UIParent, "BackdropTemplate")
	frame:SetBackdrop(core.WINDOW_BACKDROP) -- shared dark-parchment window (like FF Tracker / Mobber)
	frame:SetBackdropColor(0, 0, 0, 0.85)
	frame:SetMovable(true)
	frame:SetResizable(true)
	frame:EnableMouse(true)
	frame:EnableMouseWheel(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", function(s) if not M.db.locked then s:StartMoving() end end)
	frame:SetScript("OnDragStop", function(s) s:StopMovingOrSizing(); UI:SavePos() end)
	frame:SetScript("OnMouseWheel", function(_, delta) UI:Scroll(-delta) end)

	-- resize bounds: feature-detect the modern SetResizeBounds vs the legacy Min/Max pair.
	if frame.SetResizeBounds then
		frame:SetResizeBounds(MINW, MINH, MAXW, MAXH)
	elseif frame.SetMinResize then
		frame:SetMinResize(MINW, MINH)
		frame:SetMaxResize(MAXW, MAXH)
	end

	restorePos()
	restoreSize()

	-- header: title + buttons sit on the backdrop, no coloured title strip
	header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	header:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -7)
	header:SetText("Sunderboard")

	-- bottom-left scroll hint, shown only when the list is taller than the window
	UI.moreText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	UI.moreText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 3)
	UI.moreText:Hide()

	-- Textured header buttons (matching FF Tracker's icon-button style), not letters.
	-- X: standard textured close button; turns the module off.
	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetSize(20, 20)
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
	close:SetScript("OnClick", function() core.SetModuleState("sb", "hidden") end)
	UI.closeBtn = close -- hidden while locked (see ApplyLock)

	-- R: reset the leaderboard (refresh icon).
	local reset = W.iconButton(frame, 16, "Interface\\Icons\\Ability_Hunter_Readiness",
		"Reset", function() M.Core:Reset() end)
	core.CropIcon(reset:GetNormalTexture())
	reset:SetPoint("RIGHT", close, "LEFT", 0, 0)

	-- ?: how scoring works (question-mark icon).
	local help = W.iconButton(frame, 16, "Interface\\Icons\\INV_Misc_QuestionMark", nil, nil)
	core.CropIcon(help:GetNormalTexture())
	help:SetPoint("RIGHT", reset, "LEFT", -2, 0)
	help:SetScript("OnEnter", function(self) showHelpTooltip(self) end)
	help:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Gear: the shared Options button; jumps to Sunderboard's page in the Settings window.
	local gear = W.gearButton(frame, 16, "Options", function() core.OpenModuleSettings("sb") end)
	gear:SetPoint("RIGHT", help, "LEFT", -2, 0)
	UI.optionsBtn = gear -- hidden while locked (see ApplyLock)

	-- resize grip (bottom-right); only usable while unlocked (see ApplyLock).
	sizer = CreateFrame("Button", nil, frame)
	sizer:SetSize(16, 16)
	sizer:SetPoint("BOTTOMRIGHT", -1, 1)
	sizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	sizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	sizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	sizer:SetScript("OnMouseDown", function()
		if not M.db.locked then autoHeight = false; frame:StartSizing("BOTTOMRIGHT") end
	end)
	sizer:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		UI:SaveSize(); UI:SavePos(); UI:Refresh()
	end)
	UI.sizer = sizer

	rows = {}
	createRow(1)

	-- Registered only now that `rows` exists: setting widget textures above can nudge the
	-- frame size and fire this handler, and with a saved (manual) size it would Refresh into
	-- a nil `rows`. Refresh also guards defensively.
	frame:SetScript("OnSizeChanged", function() if not autoHeight then UI:Refresh() end end)

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

-- Scroll the (manual-height) list by `step` rows, clamped to the overflow.
function UI:Scroll(step)
	if autoHeight or not frame then return end
	local list = UI.list or {}
	local maxOffset = math.max(0, #list - fitRows())
	offset = offset + step
	if offset < 0 then offset = 0 elseif offset > maxOffset then offset = maxOffset end
	UI:Refresh()
end

function UI:Refresh()
	if not frame or not rows then return end
	local list = sortedPlayers()
	UI.list = list
	local maxv = (list[1] and list[1].total) or 1
	if maxv <= 0 then maxv = 1 end

	local barW = frame:GetWidth() - 12
	local visible
	if autoHeight then
		-- grow the window to fit its rows (bounded); no scrolling needed
		visible = math.max(1, math.min(#list, MAXROWS))
		offset = 0
		frame:SetHeight(TOPPAD + visible * ROW_H + BOTPAD)
	else
		visible = fitRows()
		local maxOffset = math.max(0, #list - visible)
		if offset > maxOffset then offset = maxOffset end
		if offset < 0 then offset = 0 end
	end

	local rendered = 0
	for i = 1, visible do
		local p = list[offset + i]
		local bar = rows[i] or createRow(i)
		bar:SetWidth(barW)
		if p then
			local zero = (p.total or 0) <= 0
			local c = (p.class and RAID_CLASS_COLORS[p.class]) or { r = 0.7, g = 0.7, b = 0.7 }
			bar:SetStatusBarColor(c.r, c.g, c.b)
			bar:SetMinMaxValues(0, maxv)
			bar:SetValue(p.total or 0)
			bar.left:SetText(p.name or "?")
			bar.right:SetText(fmt(p.total))
			-- dim warriors who haven't scored yet, so they read as "on notice"
			local nc = zero and 0.55 or 1
			bar.left:SetTextColor(nc, nc, nc)
			bar.right:SetTextColor(nc, nc, nc)
			bar.player = p
			bar:Show()
			rendered = rendered + 1
		else
			bar.player = nil
			bar:Hide()
		end
	end
	for i = visible + 1, #rows do rows[i]:Hide() end

	-- bottom-left hint shows the scroll range when the list is clipped
	if UI.moreText then
		if (not autoHeight) and #list > visible then
			UI.moreText:SetText(string.format("%d-%d / %d  \226\150\188", offset + 1, offset + rendered, #list))
			UI.moreText:Show()
		else
			UI.moreText:Hide()
		end
	end
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

-- Synthesized lock, matching FF Tracker / Mobber: locked = not draggable / not resizable
-- AND no window backdrop (clean borderless HUD; the per-row bars keep their own background
-- so it stays readable), and the header buttons + resize grip hide.
function UI:ApplyLock()
	if not frame then return end
	local locked = M.db.locked
	frame:EnableMouse(not locked)
	frame:EnableMouseWheel(not locked)
	if locked then
		frame:SetBackdrop(nil)
	else
		frame:SetBackdrop(core.WINDOW_BACKDROP)
		frame:SetBackdropColor(0, 0, 0, 0.85)
	end
	if UI.closeBtn then UI.closeBtn:SetShown(not locked) end
	if UI.optionsBtn then UI.optionsBtn:SetShown(not locked) end
	if UI.sizer then UI.sizer:SetShown(not locked) end
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

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(160, 22)
	reset:SetPoint("TOPLEFT", 14, -110)
	reset:SetText("Reset")
	reset:SetScript("OnClick", function()
		M.Core:Reset()
		print("|cffff8000Sunderboard|r: leaderboard reset.")
	end)

	local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 14, -142)
	note:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
	note:SetJustifyH("LEFT")
	note:SetWordWrap(true)
	note:SetText("Scores physical damage dealt through armor debuffs (Sunder / Expose / Faerie Fire / Curse of Recklessness). All raid warriors appear even at 0. Hover a row for a cast/outcome breakdown; drag the bottom-right grip to resize (shrink + scroll, or widen the bars). Use Show to choose where it runs: while grouped, only in an instance, or always.")

	local function refresh() for _, s in ipairs(syncs) do s() end end
	panel.refresh = refresh
	panel:SetScript("OnShow", refresh)
	refresh()
end
