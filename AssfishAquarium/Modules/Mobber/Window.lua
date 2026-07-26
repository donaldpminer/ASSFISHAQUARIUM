--[[--------------------------------------------------------------------------
	Mobber - Window (mob grid display)

	Renders M.mobs (owned by Core.lua). One window; each tracked mob is a "block":
	  * header = a raid marker + a health bar with the mob's name on it.
	  * slots  = a grid of NUM_SLOTS (16) cells. PRIORITIZED (watch-listed) debuffs pack
	             the front (anchor corner); the rest pack the back (highest-duration at the
	             far end); empty cells end up in the middle.
	  * ghosts = prioritized debuffs that just fell off linger as fading "0" cells in a
	             lane past the anchor edge. Dead mob = dimmed row + a skull.

	Two entry points Core drives on its 0.1s tick:
	  * M.Rebuild()    - structural: re-sort mobs, re-lay every block (runs on M.dirty).
	  * M.UpdateLive() - per-tick: HP bar value + our own countdown numbers + ghost fade.

	Geometry: the window is pinned by the corner the content grows AWAY from
	(anchorCorner), so changing icon size or flipping a grow direction keeps it put. See
	the coordinate-convention note atop M.Rebuild. Cooldown numbers are drawn here;
	OmniCC / tullaCTC are disabled on the swipe. Saved settings: M.db (schema in Core.lua).
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local M = ns.modules.mob

local NUM = M.NUM_SLOTS               -- debuff slots per mob (16)
local GAP, HDR_H, BLOCK_GAP, PAD = 2, 15, 8, 6 -- slot gap / header height / gap between mobs / window padding
local DEFAULT_SLOT, MIN_SLOT, MAX_SLOT, SLOT_STEP = 24, 20, 60, 4 -- icon-size slider bounds
local MAX_GHOSTS = 16                   -- cap on lingering fallen-off "0" cells shown per mob

local MARKER_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local BACKDROP = {
	bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
local SLOT_BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
}

local function cropIcon(t) t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end

-- The dialog parchment texture is semi-transparent on its own, so panels let the world
-- (and each other) bleed through. Lay a solid, fully-opaque backing inside the border.
local function opaqueBacking(p)
	local bg = p:CreateTexture(nil, "BACKGROUND", nil, 1) -- sublevel 1: above the parchment
	bg:SetPoint("TOPLEFT", 3, -3)
	bg:SetPoint("BOTTOMRIGHT", -3, 3)
	bg:SetColorTexture(0.03, 0.03, 0.04, 1)
end

local COUNT_FONT = select(1, GameFontHighlight:GetFont()) or "Fonts\\FRIZQT__.TTF"
local COUNT_GREEN = { 0.55, 1, 0.55 }
local COUNT_RED   = { 1, 0.4, 0.4 }
local COUNT_DIM   = { 0.7, 0.7, 0.7 }
local DEFAULT_HL_MINE  = { 1, 0.85, 0.25 } -- glow colour for "my debuffs" (gold)
local DEFAULT_HL_CLASS = { 0.3, 0.7, 1 }   -- glow colour for "my class, not me" (blue)
local function fmtTime(rem)
	if rem >= 60 then return math.floor(rem / 60) .. "m" end
	return tostring(math.floor(rem))
end

local function setMarker(tex, index)
	tex:SetTexture(MARKER_TEX)
	local c, r = (index - 1) % 4, math.floor((index - 1) / 4)
	tex:SetTexCoord(c * 0.25, c * 0.25 + 0.25, r * 0.25, r * 0.25 + 0.25)
end

-- Mob row order: marked first (Skull 8 -> Star 1), then higher level, then first-seen.
local function lvlVal(l) if l == -1 then return 999 end return l or 0 end
local function mobLess(a, b)
	-- ?? level (bosses / much-higher mobs) always to the very top, above even markers.
	local abz, bbz = (a.level == -1), (b.level == -1)
	if abz ~= bbz then return abz end
	-- then raid-marked (Skull 8 -> Star 1), then higher level, then first-seen.
	local am, bm = a.marker, b.marker
	if (am ~= nil) ~= (bm ~= nil) then return am ~= nil end
	if am and bm and am ~= bm then return am > bm end
	local al, bl = lvlVal(a.level), lvlVal(b.level)
	if al ~= bl then return al > bl end
	return a.order < b.order
end

local win, configPanel, blPanel, watchPanel
-- Options live in the shared Assfish Aquarium Settings page (core registers this module's
-- subcategory and calls M.BuildSettings); the two list managers are pop-out windows.
local blocks = {}
local sortBuf = {}
local priBuf, nonBuf, slotAssign = {}, {}, {} -- scratch for the prioritized/rest slot split

-- --- geometry --------------------------------------------------------------
local function slotSize() return M.db.slotSize or DEFAULT_SLOT end
local function rowW() local s = slotSize(); return NUM * s + (NUM - 1) * GAP end
local function winW() return rowW() + 2 * PAD end

-- The corner the content grows AWAY from is the one we pin, so resizing/growing keeps
-- the window put: top(down)/bottom(up) x right(left)/left(right).
local function anchorCorner()
	return (M.db.growUp and "BOTTOM" or "TOP") .. (M.db.growRight and "LEFT" or "RIGHT")
end

local function applyPos()
	win:ClearAllPoints()
	local p = M.db.point
	if p and p.corner and p.x and p.y then
		win:SetPoint(p.corner, UIParent, "BOTTOMLEFT", p.x, p.y)
	else
		win:SetPoint(anchorCorner(), UIParent, "CENTER", 0, 100)
	end
end

local function savePos()
	local corner = anchorCorner()
	local l, b, w, h = win:GetLeft(), win:GetBottom(), win:GetWidth(), win:GetHeight()
	if not l then return end
	local x = corner:find("RIGHT") and (l + w) or l
	local y = corner:find("TOP") and (b + h) or b
	M.db.point = { corner = corner, x = x, y = y }
end

-- Re-pin at the current fixed corner keeping the same screen rectangle (used when a
-- grow direction flips so the window doesn't jump).
local function reanchor()
	local l, b, w, h = win:GetLeft(), win:GetBottom(), win:GetWidth(), win:GetHeight()
	if not l then applyPos(); return end
	local corner = anchorCorner()
	local x = corner:find("RIGHT") and (l + w) or l
	local y = corner:find("TOP") and (b + h) or b
	win:ClearAllPoints()
	win:SetPoint(corner, UIParent, "BOTTOMLEFT", x, y)
	M.db.point = { corner = corner, x = x, y = y }
end

-- --- block (one mob) widget pool -------------------------------------------
-- Debuff-slot tooltip: the spell + who applied it.
local function slotOnEnter(self)
	if not self.filled then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(self.spellName or "Debuff", 1, 1, 1)
	local who = self.mine and "You" or (self.srcName or "Unknown")
	GameTooltip:AddLine("Applied by: " .. who, 0.6, 0.85, 1)
	GameTooltip:Show()
end
local function slotOnLeave() GameTooltip:Hide() end

-- Ghost cell: a debuff that fell off, lingering as a fading "0" to the right of the row.
local function ghostOnEnter(self)
	if not self.spellName then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(self.spellName, 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Fell off", 1, 0.5, 0.5)
	GameTooltip:Show()
end

local function makeGhostSlot()
	local g = CreateFrame("Frame", nil, win, "BackdropTemplate")
	g:SetBackdrop(SLOT_BACKDROP)
	g:SetBackdropColor(0.09, 0.09, 0.09, 0.9)
	g:SetBackdropBorderColor(0.32, 0.32, 0.32, 1)
	g.icon = g:CreateTexture(nil, "ARTWORK")
	g.icon:SetPoint("TOPLEFT", 1, -1)
	g.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	cropIcon(g.icon)
	g.icon:SetDesaturated(true) -- greyed: it is expired
	g.icon:SetVertexColor(0.85, 0.85, 0.85)
	g.count = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight") -- needs a font before SetText
	g.count:SetPoint("CENTER", 0, 0)
	g.count:SetText("0")
	g.count:SetTextColor(1, 0.5, 0.5)
	g:EnableMouse(true)
	g:SetScript("OnEnter", ghostOnEnter)
	g:SetScript("OnLeave", slotOnLeave)
	return g
end

local function getGhostSlot(b, i)
	b.gslots = b.gslots or {}
	local g = b.gslots[i]
	if not g then g = makeGhostSlot(); b.gslots[i] = g end
	return g
end

local function getBlock(i)
	local b = blocks[i]
	if b then return b end
	b = {}
	b.marker = win:CreateTexture(nil, "OVERLAY")
	b.hpbar = CreateFrame("StatusBar", nil, win)
	b.hpbar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	b.hpbar:SetMinMaxValues(0, 1)
	local hpbg = b.hpbar:CreateTexture(nil, "BACKGROUND")
	hpbg:SetAllPoints()
	hpbg:SetColorTexture(0.12, 0.12, 0.12, 0.75)
	b.name = b.hpbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.name:SetWordWrap(false)
	b.slots = {}
	for s = 1, NUM do
		local slot = CreateFrame("Frame", nil, win, "BackdropTemplate")
		slot:SetBackdrop(SLOT_BACKDROP)
		slot:SetBackdropColor(0.09, 0.09, 0.09, 0.9)
		slot:SetBackdropBorderColor(0.32, 0.32, 0.32, 1)
		slot.icon = slot:CreateTexture(nil, "ARTWORK")
		slot.icon:SetPoint("TOPLEFT", 1, -1)
		slot.icon:SetPoint("BOTTOMRIGHT", -1, 1)
		cropIcon(slot.icon)
		slot.icon:Hide()
		slot.cd = CreateFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
		slot.cd:SetAllPoints(slot.icon)
		slot.cd:SetDrawEdge(false)
		slot.cd:SetHideCountdownNumbers(true)
		slot.cd.noCooldownCount = true -- we draw our own number; keep OmniCC/tullaCTC off it
		slot.cd:Hide()
		slot.textLayer = CreateFrame("Frame", nil, slot)
		slot.textLayer:SetAllPoints(slot)
		slot.textLayer:SetFrameLevel(slot.cd:GetFrameLevel() + 6)
		-- "highlight" = a coloured 2px BORDER around the box (see db.hlMine / db.hlClass).
		-- A frame on the text layer so its edge draws above the cooldown swipe; colour +
		-- visibility set per-slot in Rebuild. Anchored 1px outside so it frames the slot.
		slot.hl = CreateFrame("Frame", nil, slot.textLayer, "BackdropTemplate")
		slot.hl:SetPoint("TOPLEFT", slot, "TOPLEFT", -1, 1)
		slot.hl:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", 1, -1)
		slot.hl:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
		slot.hl:Hide()
		slot.count = slot.textLayer:CreateFontString(nil, "OVERLAY")
		slot.count:SetDrawLayer("OVERLAY", 2) -- cooldown number on top of the stack count
		slot.count:SetPoint("CENTER", slot, "CENTER", 0, 0)
		slot.stack = slot.textLayer:CreateFontString(nil, "OVERLAY")
		slot.stack:SetDrawLayer("OVERLAY", 1)
		slot.stack:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -1, 1)
		slot:EnableMouse(true)
		slot:SetScript("OnEnter", slotOnEnter)
		slot:SetScript("OnLeave", slotOnLeave)
		b.slots[s] = slot
	end
	-- Skull lives on its own frame ABOVE the slot frames: a parent's textures always draw
	-- below its child frames, so a win-level skull would hide behind the (dimmed) slot grid.
	local skf = CreateFrame("Frame", nil, win)
	skf:SetAllPoints(win)
	skf:SetFrameLevel(win:GetFrameLevel() + 5)
	b.skull = skf:CreateTexture(nil, "OVERLAY")
	setMarker(b.skull, 8)
	b.skull:Hide()
	b.gslots = {}
	b.numGhosts = 0
	blocks[i] = b
	return b
end

local function hideBlock(b)
	b.marker:Hide()
	b.hpbar:Hide() -- name / level / hp are children of the bar and hide with it
	b.skull:Hide()
	for s = 1, NUM do b.slots[s]:Hide() end
	if b.gslots then for _, g in ipairs(b.gslots) do g:Hide() end end
	b.numGhosts = 0
	b.guid = nil
end

-- Gather a mob's ghosts newest-first (most-recent fall-off ends up nearest the live row).
local ghostBuf = {}
local function collectGhosts(m)
	wipe(ghostBuf)
	if m.ghosts then
		for _, g in pairs(m.ghosts) do ghostBuf[#ghostBuf + 1] = g end
		table.sort(ghostBuf, function(x, y) return (x.fellOff or 0) > (y.fellOff or 0) end)
	end
	return ghostBuf
end

-- Measure a name's pixel width in the header font (to size the prio'd-only window).
local measureFS
local function nameWidth(name)
	if not measureFS then
		measureFS = UIParent:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
	end
	measureFS:SetText(name or "?")
	return measureFS:GetStringWidth() or 0
end

-- --- structural rebuild ----------------------------------------------------
-- Coordinate convention used throughout this function:
--   * The window is pinned at its ANCHOR corner = vpart..hpart, where
--       vpart = "BOTTOM" when growing up else "TOP"   (the fixed vertical edge)
--       hpart = "LEFT"   when growing right else "RIGHT" (the fixed horizontal edge)
--     All offsets below are measured as POSITIVE distances from that fixed edge, then
--     negated for the top/right cases when handed to SetPoint (WoW y grows upward).
--   * blockOff     = vertical distance of mob `bi`'s block from the fixed vertical edge.
--   * slotAreaNear = vertical offset of the slot grid's near edge (header sits outside it).
--   * Slot index `a` (0..NUM-1): col = a/rows, row = a%rows -> column-major fill so the
--     anchor-side column fills top-to-bottom before stepping one column away.
-- Called on M.dirty (mob added/removed, aura change, marker, grow/size/layout change).
function M.Rebuild()
	if not win then return end
	local growUp, growRight = M.db.growUp, M.db.growRight
	-- highlight: two independent glows (my debuffs / my-class-but-not-me), each a colour.
	local hlMine = M.db.hlMine ~= false             -- default on
	local hlClass = M.db.hlClass and true or false  -- default off
	local hlMineColor = M.db.hlMineColor or DEFAULT_HL_MINE
	local hlClassColor = M.db.hlClassColor or DEFAULT_HL_CLASS
	local myClass = select(2, UnitClass("player"))
	local SLOT = slotSize()
	local countSize = math.max(8, math.floor(SLOT * 0.5))
	local stackSize = math.max(8, math.floor(SLOT * 0.42))
	local slotStep = SLOT + GAP

	-- Sort mobs first: the prioritized-only layout sizes the window from the visible set.
	wipe(sortBuf)
	for _, m in pairs(M.mobs) do sortBuf[#sortBuf + 1] = m end
	table.sort(sortBuf, mobLess)
	local nMobs = math.min(#sortBuf, M.MAX_MOBS)

	-- grid shape: 1x16 / 2x8 / prioritized-only. "prio" = single row, ONLY the prioritized
	-- debuffs present (no empties, no non-prioritized) -> the window shrinks to fit.
	local prioOnly = (M.db.gridRows == "prio")
	local rows, cols, gridW
	if prioOnly then
		rows = 1
		local maxPri, maxNameW = 1, 0
		for bi = 1, nMobs do
			local m = sortBuf[bi]
			local np = 0
			for _, d in ipairs(m.debuffs) do if M.IsWatched(d.name) then np = np + 1 end end
			if np > maxPri then maxPri = np end
			local nw = nameWidth(m.name)
			if nw > maxNameW then maxNameW = nw end
		end
		cols = math.min(maxPri, NUM)
		gridW = cols * SLOT + (cols - 1) * GAP
		-- widen so the header (marker + FULL name) fits; never a sliver, never wider than 1x16.
		gridW = math.max(gridW, maxNameW + HDR_H + 16, HDR_H + 60)
		gridW = math.min(gridW, rowW())
	else
		rows = (M.db.gridRows == 2) and 2 or 1
		cols = NUM / rows
		gridW = cols * SLOT + (cols - 1) * GAP
	end
	local slotAreaH = rows * SLOT + (rows - 1) * GAP
	win:SetWidth(gridW + 2 * PAD)

	local blockH = HDR_H + slotAreaH
	local vpart = growUp and "BOTTOM" or "TOP"    -- fixed vertical edge
	local hpart = growRight and "LEFT" or "RIGHT" -- fixed horizontal edge

	for bi = 1, nMobs do
		local m = sortBuf[bi]
		local b = getBlock(bi)
		b.guid = m.guid
		local blockOff = (bi - 1) * (blockH + BLOCK_GAP) -- from the fixed vertical edge

		-- header sits above the slot grid either way.
		local hdrOff = growUp and (blockOff + slotAreaH) or blockOff
		local hdy = growUp and (PAD + hdrOff) or -(PAD + hdrOff)
		local slotAreaNear = growUp and blockOff or (blockOff + HDR_H) -- near edge of the grid

		-- header: marker at the anchor edge, then a health bar carrying fixed-width
		-- name / level / hp fields (fixed so the live values don't jiggle the layout).
		b.marker:ClearAllPoints()
		b.marker:SetSize(HDR_H - 1, HDR_H - 1)
		if growRight then
			b.marker:SetPoint(vpart .. "LEFT", win, vpart .. "LEFT", PAD, hdy)
		else
			b.marker:SetPoint(vpart .. "RIGHT", win, vpart .. "RIGHT", -PAD, hdy)
		end
		if m.marker then setMarker(b.marker, m.marker); b.marker:Show() else b.marker:Hide() end

		local markerInset = PAD + HDR_H + 2
		b.hpbar:ClearAllPoints()
		b.hpbar:SetHeight(HDR_H - 2)
		if growRight then
			b.hpbar:SetPoint(vpart .. "LEFT", win, vpart .. "LEFT", markerInset, hdy)
			b.hpbar:SetPoint(vpart .. "RIGHT", win, vpart .. "RIGHT", -PAD, hdy)
		else
			b.hpbar:SetPoint(vpart .. "RIGHT", win, vpart .. "RIGHT", -markerInset, hdy)
			b.hpbar:SetPoint(vpart .. "LEFT", win, vpart .. "LEFT", PAD, hdy)
		end
		b.hpbar:Show()

		-- Name hugs the marker (anchor) side and FLIPS to the other side with Grow Left/Right.
		-- A SINGLE anchor on the marker-side edge (auto width) makes the name physically sit
		-- against that side and move when grow flips -- unlike spanning both edges + justify,
		-- which fills the bar so a longer name looks the same on either setting.
		-- name fills the bar (both edges) and justifies toward the marker side: it flips with
		-- grow direction and truncates instead of spilling out of a narrow bar.
		b.name:ClearAllPoints()
		b.name:SetPoint("LEFT", b.hpbar, "LEFT", 4, 0)
		b.name:SetPoint("RIGHT", b.hpbar, "RIGHT", -4, 0)
		b.name:SetJustifyH(growRight and "LEFT" or "RIGHT")
		b.name:SetText(m.name or "?")
		b.name:SetTextColor(m.dead and 0.6 or 1, m.dead and 0.6 or 0.82, m.dead and 0.6 or 0)
		b.name:Show()

		-- Slot fill (a = distance from the anchor edge, 0 = at the edge):
		--   * PRIORITIZED (watch-listed) debuffs pack the FRONT, a=0.. , soonest first.
		--   * everything else packs the BACK, with the highest-duration at the far end
		--     (a=NUM-1) filling inward, so any empty slots end up in the MIDDLE.
		-- db is already sorted soonest-first (debuffLess).
		local db = m.debuffs
		wipe(priBuf); wipe(nonBuf)
		for i = 1, #db do
			local d = db[i]
			if M.IsWatched(d.name) then priBuf[#priBuf + 1] = d else nonBuf[#nonBuf + 1] = d end
		end
		wipe(slotAssign)
		if prioOnly then
			-- prioritized-only: pack them from the anchor edge; no empties, no others.
			for i = 1, math.min(#priBuf, cols) do slotAssign[i] = priBuf[i] end
		else
			local P = math.min(#priBuf, NUM)
			local Q = math.min(#nonBuf, NUM - P)
			for i = 1, P do slotAssign[i] = priBuf[i] end          -- front: a = 0 .. P-1
			for k = 1, Q do slotAssign[NUM - Q + k] = nonBuf[k] end -- back: latest-expiry far end
		end
		local deadAlpha = m.dead and 0.35 or 1
		for a = 0, NUM - 1 do
			local slot = b.slots[a + 1]
			slot:SetSize(SLOT, SLOT)
			slot:SetAlpha(deadAlpha)
			if slot.fontSize ~= countSize then -- only re-apply fonts when the size changed
				slot.fontSize = countSize
				slot.count:SetFont(COUNT_FONT, countSize, "OUTLINE")
				slot.stack:SetFont(COUNT_FONT, stackSize, "OUTLINE")
			end
			-- Fill down the anchor-side column first, then step one column away: the
			-- rightmost column fills top-to-bottom before we move left (mirrored to the
			-- left column first when growing right). 1x16 is unaffected (rows == 1).
			local row = a % rows
			local col = math.floor(a / rows)
			local xoff = PAD + col * slotStep
			local rowNear = growUp and (slotAreaNear + (rows - 1 - row) * slotStep)
			                        or (slotAreaNear + row * slotStep)
			local sdy = growUp and (PAD + rowNear) or -(PAD + rowNear)
			slot:ClearAllPoints()
			if growRight then
				slot:SetPoint(vpart .. "LEFT", win, vpart .. "LEFT", xoff, sdy)
			else
				slot:SetPoint(vpart .. "RIGHT", win, vpart .. "RIGHT", -xoff, sdy)
			end

			local d = slotAssign[a + 1]
			if d then
				slot.icon:SetTexture(d.icon)
				slot.icon:Show()
				slot.filled = true
				slot.spellName = d.name
				slot.srcName = d.srcName
				slot.mine = d.mine
				slot.spellId = d.spellId
				slot.expiration = d.expiration
				slot.hasTimer = (d.expiration and d.duration) and true or false
				slot.lastCount = nil
				if slot.hasTimer then
					local st = d.expiration - d.duration
					-- Only (re)set when it actually changed: re-calling SetCooldown every
					-- rebuild restarts the swipe animation -> the jitter.
					if slot.cdStart ~= st or slot.cdDur ~= d.duration then
						slot.cdStart = st; slot.cdDur = d.duration
						slot.cd:SetCooldown(st, d.duration)
					end
					slot.cd:Show()
				else
					if slot.cdStart then slot.cd:Clear(); slot.cdStart = nil; slot.cdDur = nil end
					slot.cd:Hide()
				end
				if d.count and d.count > 1 then
					slot.stack:SetText(tostring(d.count))
					slot.stack:SetTextColor(1, 0.9, 0.4)
					slot.stack:Show()
				else
					slot.stack:Hide()
				end
				-- highlight glow: my debuffs (hlMineColor), or by my class but not me (hlClassColor)
				local gc
				if not m.dead then
					if d.mine then
						if hlMine then gc = hlMineColor end
					elseif hlClass and d.srcClass and d.srcClass == myClass then
						gc = hlClassColor
					end
				end
				if gc then
					slot.hl:SetBackdropBorderColor(gc[1], gc[2], gc[3], 1)
					slot.hl:Show()
				else
					slot.hl:Hide()
				end
			else
				slot.icon:Hide()
				if slot.cdStart then slot.cd:Clear(); slot.cdStart = nil; slot.cdDur = nil end
				slot.cd:Hide()
				slot.filled = false
				slot.expiration = nil
				slot.hasTimer = false
				slot.count:SetText("")
				slot.lastCount = ""
				slot.stack:Hide()
				slot.hl:Hide()
			end
			slot:Show()
			if prioOnly and not slot.filled then slot:Hide() end -- prio-only: no empty slots
		end

		-- fallen-off debuffs linger as fading "0"s in a lane just to the RIGHT of the
		-- window: newest nearest the live row, growing right; oldest at the far right.
		local ghosts = m.dead and nil or collectGhosts(m)
		local ng = ghosts and math.min(#ghosts, MAX_GHOSTS) or 0
		b.numGhosts = ng
		for gi = 1, ng do
			local gd = ghosts[gi]
			local gs = getGhostSlot(b, gi)
			gs:SetSize(SLOT, SLOT)
			if gs.fontSize ~= countSize then
				gs.fontSize = countSize
				gs.count:SetFont(COUNT_FONT, countSize, "OUTLINE")
			end
			gs.icon:SetTexture(gd.icon)
			gs.spellName = gd.name
			local gcol = math.floor((gi - 1) / rows)
			local grow = (gi - 1) % rows
			local gx = (GAP - PAD) + gcol * slotStep -- flush (one GAP) past the live row's edge
			local rowNear = growUp and (slotAreaNear + (rows - 1 - grow) * slotStep)
			                        or (slotAreaNear + grow * slotStep)
			local sdy = growUp and (PAD + rowNear) or -(PAD + rowNear)
			gs:ClearAllPoints()
			-- lane sits just past the ANCHOR (hpart) edge, next to the prioritized front,
			-- extending away from the window (right for grow-left, left for grow-right).
			if growRight then
				gs:SetPoint(vpart .. "RIGHT", win, vpart .. "LEFT", -gx, sdy)
			else
				gs:SetPoint(vpart .. "LEFT", win, vpart .. "RIGHT", gx, sdy)
			end
			gs:Show()
		end
		if b.gslots then for gi = ng + 1, #b.gslots do b.gslots[gi]:Hide() end end

		-- dead: a skull centred over the (dimmed) row
		b.skull:ClearAllPoints()
		b.skull:SetSize(SLOT * 1.4, SLOT * 1.4)
		-- centre over the row; in prio'd-only the padded window is wider than the icons, so
		-- keep the skull near the anchor edge (the growth axis) instead of the window centre.
		local skHalf = prioOnly and (SLOT / 2) or (gridW / 2)
		local skx = growRight and (PAD + skHalf) or -(PAD + skHalf)
		local skc = slotAreaNear + slotAreaH / 2
		local sky = growUp and (PAD + skc) or -(PAD + skc)
		b.skull:SetPoint("CENTER", win, vpart .. hpart, skx, sky)
		b.skull:SetShown(m.dead and true or false)
	end

	for bi = nMobs + 1, #blocks do hideBlock(blocks[bi]) end

	local contentH = (nMobs > 0) and (nMobs * blockH + (nMobs - 1) * BLOCK_GAP) or HDR_H
	win:SetHeight(contentH + 2 * PAD)
	-- "Only show in raids" (default on): in normal locked play the window only appears
	-- inside a raid instance (test mode counts as active). Unlocked always shows so the
	-- window can be positioned/configured anywhere.
	local raidActive = (M.db.raidOnly == false) or M.inRaid or M.testMode
	win:SetShown((not M.db.locked) or (nMobs > 0 and raidActive))
end

-- --- live update (HP% + our countdown numbers) -----------------------------
function M.UpdateLive()
	if not win or not win:IsShown() then return end
	local now = GetTime()
	-- shared fade for the lingering "0"s (fade in and out)
	local ghostAlpha = 0.2 + 0.8 * (0.5 + 0.5 * math.sin(now * 3))
	for bi = 1, #blocks do
		local b = blocks[bi]
		if b.guid then
			local m = M.mobs[b.guid]
			local dead = m and m.dead
			if dead then
				b.hpbar:SetValue(0); b.hpbar:SetStatusBarColor(0.4, 0.4, 0.4)
			else
				local frac
				if m and m.test then
					frac = m.hpfrac
				else
					local u = M.unitByGuid[b.guid]
					if u and UnitExists(u) and UnitGUID(u) == b.guid then
						local mx = UnitHealthMax(u)
						if mx and mx > 0 then frac = UnitHealth(u) / mx end
					end
				end
				if frac then
					b.hpbar:SetValue(frac)
					local r = (frac > 0.5) and (2 - 2 * frac) or 1
					local g = (frac < 0.5) and (2 * frac) or 1
					b.hpbar:SetStatusBarColor(r, g, 0.15)
				else
					b.hpbar:SetValue(0); b.hpbar:SetStatusBarColor(0.3, 0.3, 0.3)
				end
			end
			for s = 1, NUM do
				local slot = b.slots[s]
				if slot.filled and not dead then
					if slot.hasTimer and slot.expiration then
						local rem = slot.expiration - now
						if rem < 0 then rem = 0 end
						local str = fmtTime(rem)
						if slot.lastCount ~= str then slot.lastCount = str; slot.count:SetText(str) end
						local c = (rem <= 5) and COUNT_RED or COUNT_GREEN
						slot.count:SetTextColor(c[1], c[2], c[3])
					elseif slot.lastCount ~= "?" then
						slot.lastCount = "?"
						slot.count:SetText("?")
						slot.count:SetTextColor(COUNT_DIM[1], COUNT_DIM[2], COUNT_DIM[3])
					end
				elseif slot.lastCount ~= "" then
					slot.lastCount = ""
					slot.count:SetText("")
				end
			end
			for gi = 1, (b.numGhosts or 0) do
				if b.gslots and b.gslots[gi] then b.gslots[gi]:SetAlpha(ghostAlpha) end
			end
		end
	end
end

-- --- lock -------------------------------------------------------------------
local function applyLock()
	-- Locked = click-through: don't let the (backgroundless) HUD eat clicks meant for the
	-- world behind it. Slots are mouse-enabled children, so their tooltips still work.
	win:EnableMouse(not M.db.locked)
	if M.db.locked then
		win:SetBackdrop(nil)
	else
		win:SetBackdrop(BACKDROP)
		win:SetBackdropColor(0, 0, 0, 0.85)
	end
end
M.ApplyLock = applyLock -- core's SetDisplayState drives lock/unlock through this

-- Wipe every saved setting back to defaults (window pos/size/grow/layout, and the blacklist +
-- watch-list overrides), then re-apply the UI. Same db table, just emptied.
function M.ResetDefaults()
	wipe(M.db)
	applyPos() -- default corner + position
	M.SetDisplayState(M, core.GetModuleState("mob")) -- reapply lock + rebuild from the live state
	if configPanel and configPanel.refresh then configPanel.refresh() end
	if M.RefreshBlacklistUI then M.RefreshBlacklistUI() end
	if M.RefreshWatchUI then M.RefreshWatchUI() end
	print("|cff66ccffMobber:|r all settings reset to defaults.")
end

StaticPopupDialogs["MOBBER_RESET_DEFAULTS"] = {
	text = "Reset all Mobber settings to defaults?\n(window, layout, ignored mobs, watched debuffs)",
	button1 = YES, button2 = NO,
	OnAccept = function() M.ResetDefaults() end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- A labelled checkbox reflecting get() and calling set(bool) on click. Has :sync().
local function makeCheck(parent, x, y, label, get, set)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	cb:SetSize(24, 24)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	cb.sync = function() cb:SetChecked(get() and true or false) end
	cb.sync()
	return cb
end

-- A radio-style row: mutually-exclusive check buttons. options = {{text,value},...};
-- get() returns the current value; clicking one calls set(value). Returns { sync = fn }.
local function makeRadioRow(parent, x, y, labelText, options, get, set)
	local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	lbl:SetPoint("TOPLEFT", x, y - 4)
	lbl:SetText(labelText)
	local btns = {}
	local function refresh()
		local v = get()
		for _, o in ipairs(btns) do o:SetChecked(o.value == v) end
	end
	for i, opt in ipairs(options) do
		local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
		cb:SetPoint("TOPLEFT", x + 66 + (i - 1) * 52, y)
		cb:SetSize(22, 22)
		local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", cb, "RIGHT", 1, 0)
		fs:SetText(opt.text)
		cb.value = opt.value
		cb:SetScript("OnClick", function(self) set(self.value); refresh() end)
		btns[#btns + 1] = cb
	end
	refresh()
	return { sync = refresh }
end

-- Open the standard colour picker seeded with (r,g,b); onChange(r,g,b) fires live. Feature-
-- detects the modern SetupColorPickerAndShow vs the legacy func/cancelFunc API.
local function showColorPicker(r, g, b, onChange)
	local function applyNow()
		local nr, ng, nb = ColorPickerFrame:GetColorRGB()
		onChange(nr, ng, nb)
	end
	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({
			r = r, g = g, b = b, hasOpacity = false,
			swatchFunc = applyNow,
			cancelFunc = function() onChange(r, g, b) end,
		})
	else
		ColorPickerFrame:Hide() -- reset its OnShow
		ColorPickerFrame.func = applyNow
		ColorPickerFrame.cancelFunc = function() onChange(r, g, b) end
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.previousValues = { r = r, g = g, b = b }
		ColorPickerFrame:SetColorRGB(r, g, b)
		ColorPickerFrame:Show()
	end
end

-- A small clickable colour swatch showing get()'s {r,g,b}; clicking opens the picker and
-- calls set({r,g,b}). Has :sync() to refresh its shown colour.
local function makeColorSwatch(parent, x, y, get, set)
	local sw = CreateFrame("Button", nil, parent)
	sw:SetSize(18, 18)
	sw:SetPoint("TOPLEFT", x, y)
	local border = sw:CreateTexture(nil, "BACKGROUND")
	border:SetAllPoints()
	border:SetColorTexture(0, 0, 0, 1)
	local tex = sw:CreateTexture(nil, "ARTWORK")
	tex:SetPoint("TOPLEFT", 1, -1)
	tex:SetPoint("BOTTOMRIGHT", -1, 1)
	sw.sync = function() local c = get(); tex:SetColorTexture(c[1], c[2], c[3], 1) end
	sw:SetScript("OnClick", function()
		local c = get()
		showColorPicker(c[1], c[2], c[3], function(r, g, b) set({ r, g, b }); sw.sync() end)
	end)
	sw.sync()
	return sw
end

-- Populate the main option controls onto frame `p` (no window chrome). Returns refresh().
-- Native-style checkboxes / radios so all options are visible at once. Shared by the
-- native Settings canvas and the fallback window.
local function addOptionControls(p)
	local syncs = {}
	local function check(x, y, label, get, set)
		syncs[#syncs + 1] = makeCheck(p, x, y, label, get, set).sync
	end

	local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 14, -14)
	title:SetText("Mobber")
	title:SetTextColor(1, 0.82, 0)

	core.DisplayControl(p, 14, -40, M) -- shared Hidden / Unlocked / Locked tri-state
	check(14, -66, "Only show in raids", function() return M.db.raidOnly ~= false end,
		function(v) M.db.raidOnly = v; M.Rebuild() end)

	syncs[#syncs + 1] = makeRadioRow(p, 14, -96, "Grow:",
		{ { text = "Left", value = false }, { text = "Right", value = true } },
		function() return M.db.growRight and true or false end,
		function(v) M.db.growRight = v; reanchor(); M.Rebuild() end).sync
	syncs[#syncs + 1] = makeRadioRow(p, 14, -122, "Stack:",
		{ { text = "Down", value = false }, { text = "Up", value = true } },
		function() return M.db.growUp and true or false end,
		function(v) M.db.growUp = v; reanchor(); M.Rebuild() end).sync
	syncs[#syncs + 1] = makeRadioRow(p, 14, -150, "Layout:",
		{ { text = "1x16", value = 1 }, { text = "2x8", value = 2 }, { text = "Prio'd only", value = "prio" } },
		function() return M.db.gridRows or 1 end,
		function(v) M.db.gridRows = v; M.Rebuild() end).sync

	check(14, -182, "Glow debuffs I applied", function() return M.db.hlMine ~= false end,
		function(v) M.db.hlMine = v; M.Rebuild() end)
	syncs[#syncs + 1] = makeColorSwatch(p, 210, -182,
		function() return M.db.hlMineColor or DEFAULT_HL_MINE end,
		function(c) M.db.hlMineColor = c; M.Rebuild() end).sync
	check(14, -208, "Glow my class (not me)", function() return M.db.hlClass and true or false end,
		function(v) M.db.hlClass = v; M.Rebuild() end)
	syncs[#syncs + 1] = makeColorSwatch(p, 210, -208,
		function() return M.db.hlClassColor or DEFAULT_HL_CLASS end,
		function(c) M.db.hlClassColor = c; M.Rebuild() end).sync

	local sLbl = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sLbl:SetPoint("TOPLEFT", 14, -240)
	sLbl:SetText("Icon size")
	local slider = CreateFrame("Slider", "MobberSizeSlider", p, "OptionsSliderTemplate")
	slider:SetPoint("TOPLEFT", 16, -258)
	slider:SetWidth(160)
	slider:SetMinMaxValues(MIN_SLOT, MAX_SLOT)
	slider:SetValueStep(SLOT_STEP)
	if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
	local sn = slider:GetName()
	if _G[sn .. "Low"] then _G[sn .. "Low"]:SetText("small") end
	if _G[sn .. "High"] then _G[sn .. "High"]:SetText("big") end
	slider:SetScript("OnValueChanged", function(_, v)
		v = math.floor(v / SLOT_STEP + 0.5) * SLOT_STEP
		M.db.slotSize = v
		if _G[sn .. "Text"] then _G[sn .. "Text"]:SetText(tostring(v)) end
		M.Rebuild()
	end)

	check(14, -290, "Test bars (preview)", function() return M.testMode end,
		function(v) if M.SetTestMode then M.SetTestMode(v) end end)

	local blBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	blBtn:SetSize(150, 20)
	blBtn:SetPoint("TOPLEFT", 14, -320)
	blBtn:SetText("Ignored mobs")
	blBtn:SetScript("OnClick", function() if M.ToggleBlacklistPanel then M.ToggleBlacklistPanel() end end)

	local watchBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	watchBtn:SetSize(150, 20)
	watchBtn:SetPoint("TOPLEFT", 14, -344)
	watchBtn:SetText("Prioritized debuffs")
	watchBtn:SetScript("OnClick", function() if M.ToggleWatchPanel then M.ToggleWatchPanel() end end)

	local resetBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	resetBtn:SetSize(150, 20)
	resetBtn:SetPoint("TOPLEFT", 14, -372)
	resetBtn:SetText("Reset to defaults")
	resetBtn:SetScript("OnClick", function() StaticPopup_Show("MOBBER_RESET_DEFAULTS") end)

	-- refresh(): sync every control from the current db (state can change via /mobber etc.).
	return function()
		for _, s in ipairs(syncs) do s() end
		slider:SetValue(slotSize())
		if _G[sn .. "Text"] then _G[sn .. "Text"]:SetText(tostring(slotSize())) end
	end
end

-- Called by the shared core (core.AddSubcategory) with a fresh canvas frame; fills it with
-- Mobber's controls. Core registers the subcategory itself, titled "Mobber".
function M.BuildSettings(panel)
	configPanel = panel
	panel.refresh = addOptionControls(panel)
	panel:SetScript("OnShow", panel.refresh)
	panel:SetScript("OnHide", function() -- leaving the page stops the test preview
		if M.testMode and M.SetTestMode then M.SetTestMode(false) end
	end)
end

-- --- blacklist manager ----------------------------------------------------
local blRows = {}
local BL_ROW_H = 18

local function getBLRow(i)
	local r = blRows[i]
	if r then return r end
	r = CreateFrame("Frame", nil, blPanel)
	r:SetHeight(BL_ROW_H)
	r.del = CreateFrame("Button", nil, r, "UIPanelCloseButton")
	r.del:SetSize(20, 20)
	r.del:SetPoint("RIGHT", 2, 0)
	r.del:SetScript("OnClick", function() if r.blid then M.BlacklistRemoveId(r.blid) end end)
	r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.name:SetPoint("LEFT", 2, 0)
	r.name:SetPoint("RIGHT", r.del, "LEFT", -2, 0)
	r.name:SetJustifyH("LEFT")
	r.name:SetWordWrap(false)
	blRows[i] = r
	return r
end

function M.RefreshBlacklistUI()
	if not blPanel then return end
	local list = M.GetBlacklist()
	local top = 56 -- below the title + "Add current target" button
	for i, e in ipairs(list) do
		local r = getBLRow(i)
		local y = -(top + (i - 1) * BL_ROW_H)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", blPanel, "TOPLEFT", 10, y)
		r:SetPoint("TOPRIGHT", blPanel, "TOPRIGHT", -8, y)
		r.blid = e.id
		r.name:SetText(e.name .. "  |cff707070(" .. e.id .. ")|r")
		r:Show()
	end
	for i = #list + 1, #blRows do blRows[i]:Hide() end
	blPanel:SetHeight(top + math.max(1, #list) * BL_ROW_H + 12)
end

local function addBlacklistControls(p)
	local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("Ignored mobs")
	title:SetTextColor(1, 0.82, 0)

	local add = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	add:SetSize(170, 22)
	add:SetPoint("TOPLEFT", 12, -28)
	add:SetText("Add current target")
	add:SetScript("OnClick", function() M.BlacklistAddTarget() end)
end

local function buildBlacklistPanel()
	if blPanel then return end
	local p = CreateFrame("Frame", "MobberBlacklist", UIParent, "BackdropTemplate")
	blPanel = p
	p:SetSize(250, 200)
	p:SetPoint("CENTER")
	p:SetBackdrop(BACKDROP)
	p:SetBackdropColor(0, 0, 0, 0.94)
	opaqueBacking(p)
	p:SetFrameStrata("FULLSCREEN_DIALOG") -- above the Settings window so they never interleave
	p:SetClampedToScreen(true)
	p:SetMovable(true)
	p:EnableMouse(true)
	p:RegisterForDrag("LeftButton")
	p:SetScript("OnDragStart", p.StartMoving)
	p:SetScript("OnDragStop", p.StopMovingOrSizing)
	p:Hide()
	addBlacklistControls(p)
	local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
end

-- Center a manager pop-out and raise it above the Settings window.
local function showPanel(panel)
	panel:ClearAllPoints()
	panel:SetPoint("CENTER")
	panel:Show()
	panel:Raise()
end

function M.ToggleBlacklistPanel()
	buildBlacklistPanel()
	if blPanel:IsShown() then blPanel:Hide() else
		if watchPanel then watchPanel:Hide() end -- only one manager pop-out at a time
		showPanel(blPanel); M.RefreshBlacklistUI()
	end
end

-- --- watched-debuffs manager (which fall-offs linger) ----------------------
local watchRows = {}
local WATCH_ROW_H = 18

local function getWatchRow(i)
	local r = watchRows[i]
	if r then return r end
	r = CreateFrame("Frame", nil, watchPanel)
	r:SetHeight(WATCH_ROW_H)
	r.del = CreateFrame("Button", nil, r, "UIPanelCloseButton")
	r.del:SetSize(20, 20)
	r.del:SetPoint("RIGHT", 2, 0)
	r.del:SetScript("OnClick", function() if r.key then M.WatchRemoveKey(r.key) end end)
	r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.name:SetPoint("LEFT", 2, 0)
	r.name:SetPoint("RIGHT", r.del, "LEFT", -2, 0)
	r.name:SetJustifyH("LEFT")
	r.name:SetWordWrap(false)
	watchRows[i] = r
	return r
end

function M.RefreshWatchUI()
	if not watchPanel then return end
	local list = M.GetWatchList()
	local top = 60 -- below the title + the add box
	for i, e in ipairs(list) do
		local r = getWatchRow(i)
		local y = -(top + (i - 1) * WATCH_ROW_H)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", watchPanel, "TOPLEFT", 10, y)
		r:SetPoint("TOPRIGHT", watchPanel, "TOPRIGHT", -8, y)
		r.key = e.key
		r.name:SetText(e.name)
		r:Show()
	end
	for i = #list + 1, #watchRows do watchRows[i]:Hide() end
	watchPanel:SetHeight(top + math.max(1, #list) * WATCH_ROW_H + 12)
end

local function addWatchControls(p)
	local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("Prioritized debuffs")
	title:SetTextColor(1, 0.82, 0)
	local sub = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sub:SetPoint("TOPLEFT", 12, -26)
	sub:SetText("shown first; linger when they drop")

	local box = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
	box:SetSize(150, 20)
	box:SetPoint("TOPLEFT", 16, -40)
	box:SetAutoFocus(false)
	local function commit()
		M.WatchAddName(box:GetText()); box:SetText(""); box:ClearFocus()
	end
	box:SetScript("OnEnterPressed", commit)
	box:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

	local add = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	add:SetSize(52, 22)
	add:SetPoint("LEFT", box, "RIGHT", 8, 0)
	add:SetText("Add")
	add:SetScript("OnClick", commit)
end

local function buildWatchPanel()
	if watchPanel then return end
	local p = CreateFrame("Frame", "MobberWatch", UIParent, "BackdropTemplate")
	watchPanel = p
	p:SetSize(250, 200)
	p:SetPoint("CENTER")
	p:SetBackdrop(BACKDROP)
	p:SetBackdropColor(0, 0, 0, 0.94)
	opaqueBacking(p)
	p:SetFrameStrata("FULLSCREEN_DIALOG") -- above the Settings window so they never interleave
	p:SetClampedToScreen(true)
	p:SetMovable(true)
	p:EnableMouse(true)
	p:RegisterForDrag("LeftButton")
	p:SetScript("OnDragStart", p.StartMoving)
	p:SetScript("OnDragStop", p.StopMovingOrSizing)
	p:Hide()
	addWatchControls(p)
	local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
end

function M.ToggleWatchPanel()
	buildWatchPanel()
	if watchPanel:IsShown() then watchPanel:Hide() else
		if blPanel then blPanel:Hide() end -- only one manager pop-out at a time
		showPanel(watchPanel); M.RefreshWatchUI()
	end
end

function M.BuildWindow()
	if win then return end
	win = CreateFrame("Frame", "MobberFrame", UIParent, "BackdropTemplate")
	win:SetSize(winW(), 60)
	win:SetFrameStrata("MEDIUM")
	win:SetClampedToScreen(true)
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", function() if not M.db.locked then win:StartMoving() end end)
	win:SetScript("OnDragStop", function() win:StopMovingOrSizing(); savePos() end)
	M.win = win

	applyPos()
	applyLock()
	M.Rebuild()
end
