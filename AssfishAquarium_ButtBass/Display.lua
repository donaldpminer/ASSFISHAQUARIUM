--[[--------------------------------------------------------------------------
	ButtBass - Display: the Chain Heal icon column.

	Each cast renders up to 3 stacked rows. The icon column is the fixed anchor;
	the heal amount and the name/health-bar hang off the left/right of the icons
	(side depends on the layout option), so toggling layout never moves the icons.
	Rows fade IN staggered (STAGGER apart) but fade OUT together. A row is:
	  [ effective heal ]  [ icon w/ rank + crit glow ]  [ target name / health bar ]

	Lifecycle: frames build once (Display_Init). Display_Show / Display_Hide toggle
	the `active` gate + frame visibility on module enable/disable so a deferred
	Display_NewCast (scheduled by Core one frame after a heal) can't fire onto a
	disabled module.
----------------------------------------------------------------------------]]

local ns = AssfishAquarium
local core = ns.core
local M = ns.modules.bb

local NUM_SLOTS   = M.MAX_BOUNCES or 3
local ICON_SIZE   = 40
local SLOT_GAP    = 6
local SIDE_GAP    = 5
local NAME_W      = 96
local BAR_W       = 72            -- 75% of the old 96px bar
local BAR_H       = 9
local STAGGER     = 0.12          -- seconds between each bounce reveal (fade-in); 40% less than 0.2
local LINGER      = 1.45          -- total on-screen time before it fades (< LHW cast time)
local FADE_OUT    = 0.5
local FADE_IN     = 0.15          -- fade-in duration

local AMOUNT_FONT      = 15
local AMOUNT_FONT_CRIT = 19
local RANK_FONT        = 22
local NAME_FONT        = 12

local HEAL_COLOR = { 0.75, 1.00, 0.75 }
local CRIT_COLOR = { 1.00, 0.92, 0.40 }
local FAIL_TINT  = { 1.00, 0.30, 0.30 }   -- bounce that didn't land (Chain Heal)
local WASTE_TINT = { 1.00, 0.82, 0.20 }   -- ~all overheal, but still a real heal
local SEG_BEFORE = { 0.15, 0.55, 0.15 }   -- health they had before the heal
local SEG_HEALED = { 0.45, 1.00, 0.45 }   -- the effective heal
local SEG_MISS   = { 0.45, 0.10, 0.10 }   -- health still missing

local frame, slots
local gen = 0                     -- cast generation; bumped each cast so stale timers no-op
local active = false              -- module enabled? gates the deferred Display_NewCast

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function spellTexture(id)
	return M.SpellTexture(id, M.CHAIN_HEAL_ICON)
end

local function commaNum(n)
	n = math.floor((n or 0) + 0.5)
	return tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

-- Lay out the 3-part health bar inside a row. Segments are absolutely positioned
-- from the bar's left edge so a zero-width (hidden) segment never shifts the next.
local function setBar(s, bar)
	if not bar or not bar.max or bar.max <= 0 then
		s.barBG:Hide(); s.seg1:Hide(); s.seg2:Hide(); s.seg3:Hide()
		return
	end
	s.barBG:Show()
	local innerW = BAR_W - 2
	local x = 1
	local function place(seg, val)
		local w = innerW * (math.max(0, val) / bar.max)
		if w < 0.5 then seg:Hide(); return end
		seg:ClearAllPoints()
		seg:SetPoint("LEFT", s.barBG, "LEFT", x, 0)
		seg:SetSize(w, BAR_H - 2)
		seg:Show()
		x = x + w
	end
	place(s.seg1, bar.before)
	place(s.seg2, bar.healed)
	place(s.seg3, bar.missing)
end

-- Anchor the heal amount (one side) and the name/bar (other side) per the layout
-- option. Left-of-icon content is right-aligned; right-of-icon content is
-- left-aligned. The icon itself never moves.
local function applyLayoutToSlot(s)
	s.amount:ClearAllPoints()
	s.name:ClearAllPoints()
	s.barBG:ClearAllPoints()
	if M.db.chLayout == "name_heal" then
		-- name/bar on the LEFT (right-aligned), heal on the RIGHT (left-aligned)
		s.name:SetPoint("TOPRIGHT", s.icon, "TOPLEFT", -SIDE_GAP, -1)
		s.name:SetJustifyH("RIGHT")
		s.barBG:SetPoint("TOPRIGHT", s.name, "BOTTOMRIGHT", 0, -2)
		s.amount:SetPoint("LEFT", s.icon, "RIGHT", SIDE_GAP, 0)
		s.amount:SetJustifyH("LEFT")
	else
		-- default heal_name: heal on the LEFT (right-aligned), name/bar on the RIGHT
		s.amount:SetPoint("RIGHT", s.icon, "LEFT", -SIDE_GAP, 0)
		s.amount:SetJustifyH("RIGHT")
		s.name:SetPoint("TOPLEFT", s.icon, "TOPRIGHT", SIDE_GAP, -1)
		s.name:SetJustifyH("LEFT")
		s.barBG:SetPoint("TOPLEFT", s.name, "BOTTOMLEFT", 0, -2)
	end
end

function M.Display_ApplyLayout()
	if not slots then return end
	for i = 1, NUM_SLOTS do applyLayoutToSlot(slots[i]) end
end

function M.Display_ApplyScale()
	if frame then frame:SetScale(M.db.chScale or 1) end
end

--------------------------------------------------------------------------------
-- row styling
--------------------------------------------------------------------------------
local function styleReal(s, heal)
	s.icon:SetTexture(spellTexture(heal.spellId))
	if heal.wasted then
		-- overhealed ~entirely: yellow-tint the icon (like the red failed tint)
		-- but keep the name / amount / bar so you still see what happened.
		s.icon:SetDesaturated(true)
		s.icon:SetVertexColor(WASTE_TINT[1], WASTE_TINT[2], WASTE_TINT[3])
		s.glow:Hide()
	else
		s.icon:SetDesaturated(false)
		s.icon:SetVertexColor(1, 1, 1)
		if heal.crit then s.glow:Show() else s.glow:Hide() end
	end

	s.rank:SetText(heal.rank and tostring(heal.rank) or "")
	s.rank:Show()

	s.amount:SetFont(STANDARD_TEXT_FONT, heal.crit and AMOUNT_FONT_CRIT or AMOUNT_FONT, "OUTLINE")
	s.amount:SetText(commaNum(heal.effective))
	local c = heal.crit and CRIT_COLOR or HEAL_COLOR
	s.amount:SetTextColor(c[1], c[2], c[3])
	s.amount:Show()

	s.name:SetText(heal.unitName or "")
	local cc = heal.classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[heal.classToken]
	if cc then s.name:SetTextColor(cc.r, cc.g, cc.b) else s.name:SetTextColor(1, 1, 1) end
	s.name:Show()

	setBar(s, heal.bar)
end

local function styleFailed(s, spellId)
	s.icon:SetTexture(spellTexture(spellId))
	s.icon:SetDesaturated(true)
	s.icon:SetVertexColor(FAIL_TINT[1], FAIL_TINT[2], FAIL_TINT[3])
	s.rank:SetText(""); s.rank:Hide()
	s.amount:Hide()
	s.glow:Hide()
	s.name:Hide()
	setBar(s, nil)
end

local function styleSlot(s, heal, spellId)
	if heal then styleReal(s, heal) else styleFailed(s, spellId) end
end

--------------------------------------------------------------------------------
-- fade-in (staggered) / fade-out (all together)
--------------------------------------------------------------------------------
local function revealSlot(i, c, myGen)
	if gen ~= myGen then return end
	local s = slots[i]
	local heal = c.heals[i]
	if heal then
		styleReal(s, heal)
	elseif c.pad then
		styleFailed(s, c.spellId)   -- Chain Heal: red icon for a bounce that missed
	else
		s:Hide()                    -- non-padded spell: no heal here -> no row
		return
	end
	UIFrameFadeRemoveFrame(s)
	s:SetAlpha(0)
	s:Show()
	UIFrameFadeIn(s, FADE_IN, 0, 1)
end

local function fadeOutAll(myGen)
	if gen ~= myGen then return end
	for i = 1, NUM_SLOTS do
		local s = slots[i]
		if s:IsShown() then
			UIFrameFadeRemoveFrame(s)
			UIFrameFadeOut(s, FADE_OUT, s:GetAlpha(), 0)
		end
	end
	C_Timer.After(FADE_OUT, function()
		if gen ~= myGen then return end
		for i = 1, NUM_SLOTS do slots[i]:Hide() end
	end)
end

local function playCast(c)
	if not frame then M.Display_Init() end
	-- Order by raw heal amount, descending, so it's always first target -> 2nd -> 3rd
	-- top to bottom (regardless of the sometimes out-of-order combat-log arrival). A
	-- crit is halved for the sort so it doesn't inflate a bounce above the primary.
	table.sort(c.heals, function(a, b)
		local av = a.crit and (a.amount or 0) / 2 or (a.amount or 0)
		local bv = b.crit and (b.amount or 0) / 2 or (b.amount or 0)
		return av > bv
	end)
	gen = gen + 1
	local myGen = gen

	-- Schedule reveals up to the spell's cap (maxTargets), not #heals: Chain Heal
	-- always pads to its cap so misses show as red bounces. Core defers this cast one
	-- frame so same-frame bounces are already collected; revealSlot still reads
	-- c.heals[i] lazily at each reveal, so a straggler within the group window is caught
	-- too. It decides per row: real heal, red pad (Chain Heal miss), or nothing
	-- (single-target / un-bounced Healing Wave).
	local count = c.maxTargets or #c.heals
	count = math.max(1, math.min(NUM_SLOTS, count))

	for i = 1, NUM_SLOTS do
		UIFrameFadeRemoveFrame(slots[i])
		slots[i]:Hide()
	end
	for i = 1, count do
		local delay = STAGGER * (i - 1)
		if delay <= 0 then
			revealSlot(i, c, myGen)
		else
			C_Timer.After(delay, function() revealSlot(i, c, myGen) end)
		end
	end
	-- one shared fade-out; measured from the cast so total on-screen time ~= LINGER
	C_Timer.After(LINGER, function() fadeOutAll(myGen) end)
end

function M.Display_HideNow()
	if not slots then return end
	gen = gen + 1
	for i = 1, NUM_SLOTS do
		UIFrameFadeRemoveFrame(slots[i])
		slots[i]:Hide()
	end
end

--------------------------------------------------------------------------------
-- frame construction
--------------------------------------------------------------------------------
function M.Display_ApplyPosition()
	if not frame then return end
	local p = M.db.pos or {}
	frame:ClearAllPoints()
	frame:SetPoint(p.point or "CENTER", UIParent, p.relPoint or p.point or "CENTER",
		p.x or 0, p.y or 0)
end

local function buildSlot(i)
	local s = CreateFrame("Frame", nil, frame)
	s:SetSize(ICON_SIZE, ICON_SIZE)      -- the slot IS the icon; content overhangs
	if i == 1 then
		s:SetPoint("TOP", frame, "TOP", 0, 0)
	else
		s:SetPoint("TOP", slots[i - 1], "BOTTOM", 0, -SLOT_GAP)
	end

	s.glow = s:CreateTexture(nil, "BACKGROUND")
	s.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	s.glow:SetBlendMode("ADD")
	s.glow:SetVertexColor(1, 0.85, 0.25)
	s.glow:SetPoint("CENTER", s, "CENTER", 0, 0)
	s.glow:SetSize(ICON_SIZE * 1.6, ICON_SIZE * 1.6)
	s.glow:Hide()

	s.border = s:CreateTexture(nil, "BORDER")
	s.border:SetColorTexture(0, 0, 0, 1)
	s.border:SetPoint("TOPLEFT", s, "TOPLEFT", -1, 1)
	s.border:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", 1, -1)

	s.icon = s:CreateTexture(nil, "ARTWORK")
	s.icon:SetAllPoints(s)
	s.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	s.rank = s:CreateFontString(nil, "OVERLAY")
	s.rank:SetFont(STANDARD_TEXT_FONT, RANK_FONT, "OUTLINE")
	s.rank:SetPoint("CENTER", s, "CENTER", 0, 0)
	s.rank:SetTextColor(1, 1, 1)

	s.amount = s:CreateFontString(nil, "OVERLAY")
	s.amount:SetFont(STANDARD_TEXT_FONT, AMOUNT_FONT, "OUTLINE")

	s.name = s:CreateFontString(nil, "OVERLAY")
	s.name:SetFont(STANDARD_TEXT_FONT, NAME_FONT, "OUTLINE")
	-- no fixed width: the name shrink-wraps its text, so whichever corner is
	-- anchored to the icon (see applyLayoutToSlot) keeps it snug to the icon in
	-- both layouts. The health bar hangs off that same icon-side corner.
	s.name:SetHeight(NAME_FONT + 4)

	s.barBG = s:CreateTexture(nil, "ARTWORK")
	s.barBG:SetColorTexture(0, 0, 0, 0.85)
	s.barBG:SetSize(BAR_W, BAR_H)

	s.seg1 = s:CreateTexture(nil, "OVERLAY"); s.seg1:SetColorTexture(unpack(SEG_BEFORE))
	s.seg2 = s:CreateTexture(nil, "OVERLAY"); s.seg2:SetColorTexture(unpack(SEG_HEALED))
	s.seg3 = s:CreateTexture(nil, "OVERLAY"); s.seg3:SetColorTexture(unpack(SEG_MISS))

	s:Hide()
	return s
end

function M.Display_Init()
	if frame then return end

	frame = CreateFrame("Frame", "AssfishButtBassHealFrame", UIParent)
	frame:SetSize(ICON_SIZE, NUM_SLOTS * ICON_SIZE + (NUM_SLOTS - 1) * SLOT_GAP)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if not M.db.locked then self:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		M.db.pos = { point = point, relPoint = relPoint, x = x, y = y }
	end)

	frame.bg = frame:CreateTexture(nil, "BACKGROUND")
	frame.bg:SetAllPoints()
	frame.bg:SetColorTexture(0, 0, 0, 0.5)
	frame.bg:Hide()

	frame.label = frame:CreateFontString(nil, "OVERLAY")
	frame.label:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
	frame.label:SetPoint("BOTTOM", frame, "TOP", 0, 3)
	frame.label:SetText("Shaman Stuff heals - drag to move")
	frame.label:Hide()

	slots = {}
	for i = 1, NUM_SLOTS do slots[i] = buildSlot(i) end

	M.Display_ApplyLayout()
	M.Display_ApplyScale()
	M.Display_ApplyPosition()
	M.Display_SetLocked(M.db.locked)
end

-- Module enable/disable: gate the deferred NewCast + toggle whole-frame visibility.
function M.Display_Show()
	if not frame then M.Display_Init() end
	active = true
	frame:Show()
end

function M.Display_Hide()
	active = false
	gen = gen + 1   -- void any pending reveals/fades
	if slots then
		for i = 1, NUM_SLOTS do
			UIFrameFadeRemoveFrame(slots[i])
			slots[i]:Hide()
		end
	end
	if frame then frame:Hide() end
end

--------------------------------------------------------------------------------
-- lock / move mode
--------------------------------------------------------------------------------
function M.Display_SetLocked(locked)
	if not frame then M.Display_Init(); return end
	gen = gen + 1   -- cancel pending reveals/fades
	for i = 1, NUM_SLOTS do
		UIFrameFadeRemoveFrame(slots[i])
		slots[i]:SetAlpha(1)
		slots[i]:Hide()
	end
	if locked then
		frame:EnableMouse(false)
		frame.bg:Hide()
		frame.label:Hide()
	else
		frame:EnableMouse(true)
		frame.bg:Show()
		frame.label:Show()
		M.Display_Preview()   -- static sample so there's something to grab + aim
	end
end

-- Static sample (full alpha, no timers) shown while unlocked.
function M.Display_Preview()
	local sample = {
		spellId = 1064,
		heals = {
			{ effective = 1687, spellId = 1064, rank = 3, crit = false,
			  unitName = "Buttbass", classToken = "SHAMAN",
			  bar = { max = 100, before = 40, healed = 35, missing = 25 } },
			{ effective = 902,  spellId = 1064, rank = 3, crit = true,
			  unitName = "Rosbif",  classToken = "DRUID",
			  bar = { max = 100, before = 68, healed = 22, missing = 10 } },
			-- slot 3 omitted -> previews the red "failed bounce" icon
		},
	}
	for i = 1, NUM_SLOTS do
		local s = slots[i]
		UIFrameFadeRemoveFrame(s)
		s:SetAlpha(1)
		styleSlot(s, sample.heals[i], sample.spellId)
		s:Show()
	end
end

--------------------------------------------------------------------------------
-- entry points
--------------------------------------------------------------------------------
function M.Display_NewCast(c)
	if not active then return end          -- module disabled: ignore a late deferred cast
	if not M.db.chEnabled then return end
	if not M.db.locked then return end     -- while positioning, keep the preview
	playCast(c)
end

-- /bb test - fabricate a cast (with fake names + health) to preview the animation.
function M.Display_Test(n)
	if not active then return end -- ignore /bb test while the module is disabled
	if not frame then M.Display_Init() end
	if n == nil then n = math.random(1, NUM_SLOTS) end
	n = math.max(1, math.min(NUM_SLOTS, math.floor(n)))

	local names = {
		{ "Buttbass", "SHAMAN" }, { "Rosbif", "DRUID" }, { "Grognak", "WARRIOR" },
		{ "Sneakyboi", "ROGUE" }, { "Lightburger", "PALADIN" }, { "Dotdotlol", "WARLOCK" },
	}
	-- simulate a Chain Heal (padded) so failed bounces + the animation preview
	local c = { spellId = 1064, pad = true, maxTargets = NUM_SLOTS, heals = {} }
	local base = math.random(1400, 1900)   -- primary; each bounce ~40% weaker
	for i = 1, n do
		local nm     = names[math.random(#names)]
		local maxHP  = 100
		local raw    = math.floor(base * (1 - (i - 1) * 0.4))
		local wasted = (math.random() < 0.25)
		local eff    = wasted and math.random(10, 70) or raw
		local before = wasted and math.random(80, 95) or math.random(15, 55)
		local healed = math.min(math.random(15, 40), maxHP - before)
		c.heals[i] = {
			amount = raw, effective = eff, spellId = 1064, rank = 3,
			crit = (not wasted) and (math.random() < 0.25) or false, wasted = wasted,
			unitName = nm[1], classToken = nm[2],
			bar = { max = maxHP, before = before, healed = healed, missing = maxHP - before - healed },
		}
	end
	playCast(c)
end
