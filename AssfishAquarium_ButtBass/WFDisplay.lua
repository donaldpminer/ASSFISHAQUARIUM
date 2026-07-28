--[[--------------------------------------------------------------------------
	ButtBass - Party frame (Shaman-facing).

	One secure, clickable/mouseover row per party member (2-5), sorted by class.
	Row: [ health bar (name right-aligned inside) / resource bar ] then icon columns
	  [ WF ] [ air ] [ earth ] [ water ] [ fire ].
	Above the columns sits a header row of totem-DURATION timers (from the Shaman's own
	GetTotemInfo), counting down; they flash red + pulse under 10s.

	Integration lifecycle: SECURE unit buttons cannot be created / re-parented / have
	their unit reassigned in combat, so:
	  * WFDisplay_Init BUILDS the frames ONCE, lazily, out of combat (Core defers the
	    whole build to PLAYER_REGEN_ENABLED if enabled mid-combat).
	  * WFDisplay_Enable starts the 0.1s refresh ticker (via core.NewTicker so the core
	    cancels it on Disable) + does the first assignUnits.
	  * WFDisplay_Disable hides the frame (never deletes it) and cancels its ticker.
	  * roster/combat-end hooks are called by Core's module event frame (no own frame).
	  * assignUnits + the lock preview guard every secure change with InCombatLockdown.
----------------------------------------------------------------------------]]

local ns = AssfishAquarium
local core = ns.core
local M = ns.modules.bb

local MAX       = 5
local ICON      = 31       -- 20% larger than the old 26
local ROW_H     = 31       -- sized to the icon
local ROW_GAP   = 6        -- 2x the old 3
local BAR_W     = 96       -- 80% of the old 120
local HP_H      = 22       -- bar heights unchanged
local PW_H      = 7
local COL_GAP   = 3
local HEADER_H  = ICON + 3 -- full-size totem icon (countdown overlaid inside it)
local NAME_FONT = 11
local TIMER_FONT= 13
local HEAD_FONT = 18       -- big countdown, really visible on the icon
local YELLOW_AT = 4.7
local POP_JUMP  = 0.5
local SETTLE    = 1.5
local TICK      = 0.1
local CLUSTER   = 1.5      -- WF timers within this of the freshest snap together
local ROW_W     = BAR_W + COL_GAP + 5 * ICON + 5 * COL_GAP

local WF_TOTEM_SPELL = 8512
local WF_FALLBACK    = "Interface\\Icons\\Spell_Nature_Windfury"
local BAR_TEX        = "Interface\\TargetingFrame\\UI-StatusBar"
-- WF weapon-imbue enchid -> rank lives on M.WF_ENCHANTS (Windfury.lua); read at
-- runtime (in getWF) so this file doesn't depend on TOC load order.

local CLASS_ORDER = {
	WARRIOR = 1, ROGUE = 2, SHAMAN = 3, HUNTER = 4,
	MAGE = 5, WARLOCK = 6, PRIEST = 7, DRUID = 8,
}

-- per-row totem columns, matched by (English) BUFF name; icon taken from the buff.
-- (Cleansing totems apply no persistent aura, so they only show in the header timer;
-- Healing Stream / Mana Spring / etc. DO buff party members.)
local AIR   = { ["Grace of Air"] = true, ["Tranquil Air"] = true, ["Grounding Totem"] = true }
local EARTH = { ["Strength of Earth"] = true, ["Stoneskin"] = true }
local WATER = { ["Mana Spring"] = true, ["Fire Resistance"] = true,
                ["Poison Cleansing"] = true, ["Disease Cleansing"] = true,
                ["Healing Stream"] = true, ["Healing Stream Totem"] = true }
local FIRE  = { ["Frost Resistance"] = true }

-- header timers: map a totem's ELEMENT SLOT to a column, so ANY totem the Shaman casts
-- (Tremor, Searing, Windwall, ...) shows its icon + duration at the top of its column.
-- (The per-row cells above still track ONLY the explicit buffs listed above.) Windfury
-- (air slot) routes to the WF column instead of the air column.
-- GetTotemInfo slot order is Fire=1, Earth=2, Water=3, Air=4 (hardcoded: Classic Era
-- does NOT define the named *_TOTEM_SLOT globals -- they arrived with the Wrath totem bar).
local SLOT_COLUMN = {
	[1] = 5,   -- fire  -> fire column
	[2] = 3,   -- earth -> earth column
	[3] = 4,   -- water -> water column
	[4] = 2,   -- air   -> air column (Windfury re-routed to the WF column below)
}

local YELLOW = { 1.00, 0.82, 0.20 }
local RED    = { 1.00, 0.25, 0.25 }

local frame, buttons, ticker, dragOverlay
local wfIcon, airIcon, earthIcon, waterIcon, fireIcon
local sorted = {}
local lastExpires = {}
local settleAt = 0
local pendingAssign = false
local wfWasPresent = false   -- for the "WF dropped from the party" sound
local remByCol, iconByCol = {}, {}   -- header scratch tables, wiped+reused each tick

-- selectable alert sounds for the WF-drop cue
local function K(name, fallback) return (SOUNDKIT and SOUNDKIT[name]) or fallback end
local SOUNDS = {
	{ name = "Raid Warning", kit = K("RAID_WARNING", 8959) },
	{ name = "Ready Check",  kit = K("READY_CHECK", 8960) },
	{ name = "Alarm Clock",  kit = K("ALARM_CLOCK_WARNING_3", 12867) },
	{ name = "Auction Bell", kit = K("AUCTION_WINDOW_OPEN", 5274) },
	{ name = "Quest Failed", kit = K("IG_QUEST_FAILED", 847) },
}
M.WF_SOUNDS = SOUNDS

function M.WF_PlaySound(idx)   -- preview / play one sound
	local s = SOUNDS[idx]
	if s and s.kit then PlaySound(s.kit, "Master") end
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function spellTexture(id)
	return M.SpellTexture(id, WF_FALLBACK)
end

local function powerColor(ptoken)
	local c = PowerBarColor and ptoken and PowerBarColor[ptoken]
	if c then return c.r, c.g, c.b end
	return 0.15, 0.35, 1.0
end

local function colCenterX(c)   -- c: 1=WF .. 5=fire
	return BAR_W + COL_GAP + (c - 1) * (ICON + COL_GAP) + ICON / 2
end

local function scanTotems(unit)
	local air, earth, water, fire
	for i = 1, 40 do
		local name, icon = UnitBuff(unit, i)
		if not name then break end
		if AIR[name] then air = icon
		elseif EARTH[name] then earth = icon
		elseif WATER[name] then water = icon
		elseif FIRE[name] then fire = icon end
	end
	return air, earth, water, fire
end

local function setCol(tex, border, icon)
	if icon then tex:SetTexture(icon); tex:SetAlpha(1); tex:Show(); border:Show()
	else tex:Hide(); border:Hide() end
end

local function triggerPop(b)
	b.glowAG:Stop();  b.glowAG:Play()
	b.flashAG:Stop(); b.flashAG:Play()
end

-- WF status for a button: hasWF, absolute expiry. Self reads its own imbue.
local function getWF(b, now)
	local WF = ns.windfury                      -- nil if the Windfury addon isn't enabled
	if UnitIsUnit(b.unit, "player") then
		local mh, expMs, _, enchid = GetWeaponEnchantInfo()
		if mh and enchid and WF and WF.WF_ENCHANTS[enchid] then return true, now + (expMs or 0) / 1000 end
	else
		local rec = WF and WF.wf[b.guid]
		if rec and rec.hasWF and rec.expiresAt and rec.expiresAt > now then return true, rec.expiresAt end
	end
	return false, nil
end

--------------------------------------------------------------------------------
-- WF column
--------------------------------------------------------------------------------
local function updateWF(b, now, canPop, hasWF, expiry)
	local isMelee = (b.class == "WARRIOR" or b.class == "ROGUE")
	local icon = b.colWF
	icon:SetTexture(wfIcon)

	local a   -- final icon + border opacity
	if hasWF then
		local remaining = (expiry or now) - now
		if isMelee and b.guid then
			local prev = lastExpires[b.guid]
			if prev and canPop and expiry > prev + POP_JUMP then triggerPop(b) end
		end
		if b.guid then lastExpires[b.guid] = expiry end

		icon:SetDesaturated(false)
		if remaining > YELLOW_AT then icon:SetVertexColor(1, 1, 1)
		else icon:SetVertexColor(YELLOW[1], YELLOW[2], YELLOW[3]) end
		a = isMelee and 1 or 0.4                 -- non-melee WF is de-emphasized
		b.wfTimer:SetAlpha(a)
		b.wfTimer:SetText(tostring(math.ceil(remaining))); b.wfTimer:Show()
	else
		b.wfTimer:Hide()
		if isMelee then
			icon:SetDesaturated(true); icon:SetVertexColor(RED[1], RED[2], RED[3]); a = 1
		else
			a = 0                                -- non-melee, no WF -> fully transparent
		end
	end
	icon:SetAlpha(a)
	b.colWFBd:SetAlpha(a)   -- the border tracks the icon so nothing shows when transparent
end

--------------------------------------------------------------------------------
-- per-row visuals
--------------------------------------------------------------------------------
local function updateButton(b, now, canPop, hasWF, wfExpiry)
	local u = b.unit
	if not u or not UnitExists(u) then return end
	local class = b.class or select(2, UnitClass(u))

	local hp, hpMax = UnitHealth(u), UnitHealthMax(u)
	b.health:SetMinMaxValues(0, hpMax > 0 and hpMax or 1)
	b.health:SetValue(UnitIsDeadOrGhost(u) and 0 or hp)
	local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if cc then b.health:SetStatusBarColor(cc.r, cc.g, cc.b) else b.health:SetStatusBarColor(0.4, 0.4, 0.4) end
	b.name:SetText(UnitName(u) or "")

	local ptoken = select(2, UnitPowerType(u))
	local pwMax = UnitPowerMax(u)
	b.power:SetMinMaxValues(0, pwMax > 0 and pwMax or 1)
	b.power:SetValue(UnitPower(u))
	b.power:SetStatusBarColor(powerColor(ptoken))

	local air, earth, water, fire = scanTotems(u)
	setCol(b.colAir,   b.colAirBd,   air)
	setCol(b.colEarth, b.colEarthBd, earth)
	setCol(b.colWater, b.colWaterBd, water)
	setCol(b.colFire,  b.colFireBd,  fire)

	updateWF(b, now, canPop, hasWF, wfExpiry)
end

-- header totem-duration timers (the Shaman's own totems), flashing red under 10s.
-- minWF = lowest remaining WF among party members; used as the WF-column fallback
-- when no Windfury Totem is down but players still have the imbue (twist window).
local function updateHeaderTimers(now, minWF)
	wipe(remByCol); wipe(iconByCol)
	local wfTotemDown = false
	for slot = 1, 4 do
		local have, name, startTime, duration, icon = GetTotemInfo(slot)
		if have and name and duration and duration > 0 then
			local col = SLOT_COLUMN[slot]
			if col == 2 and name:find("Windfury") then col = 1 end   -- Windfury -> WF column
			if col then
				remByCol[col] = (startTime + duration) - now
				-- col 1 is the WF column -- always show the WF icon there, so a stale
				-- GetTotemInfo name mid-swap (Windfury -> Grace of Air share the air slot)
				-- can't flash a non-WF totem's icon in the WF slot before it lands in col 2.
				iconByCol[col] = (col == 1) and wfIcon or icon
				if col == 1 then wfTotemDown = true end
			end
		end
	end
	-- WF-column fallback: no Windfury Totem down but players still have the imbue
	local wfFallback = false
	if not remByCol[1] and minWF and minWF > 0 then
		remByCol[1] = minWF; iconByCol[1] = wfIcon; wfFallback = true
	end
	for col = 1, 5 do
		local h = frame.headers[col]
		local rem = remByCol[col]
		if not (rem and rem > 0) then
			h.icon:Hide(); h.text:Hide(); h.inner:SetScale(1)
		else
			h.icon:SetTexture(iconByCol[col] or h.defaultIcon); h.icon:Show()
			local pulse = 1 + 0.30 * math.abs(math.sin(now * 6))
			if col == 1 and wfFallback then
				-- the "decaying WF" twist-window imbue counter: yellow 10-5s, red bouncy <5s
				h.text:SetText(tostring(math.ceil(rem)))
				if rem > 10 then h.text:SetTextColor(1, 1, 1); h.inner:SetScale(1)
				elseif rem >= 5 then h.text:SetTextColor(YELLOW[1], YELLOW[2], YELLOW[3]); h.inner:SetScale(1)
				else h.text:SetTextColor(RED[1], RED[2], RED[3]); h.inner:SetScale(pulse) end
				h.text:Show()
			elseif rem < 30 then
				-- totem duration, last 30s: big WHITE pulsing countdown inside the icon
				h.text:SetText(tostring(math.ceil(rem)))
				h.text:SetTextColor(1, 1, 1); h.text:Show()
				h.inner:SetScale(pulse)
			else
				h.text:Hide(); h.inner:SetScale(1)   -- plenty of time -> icon only
			end
		end
	end
	return wfTotemDown
end

--------------------------------------------------------------------------------
-- roster
--------------------------------------------------------------------------------
local function computeSorted()
	local list = {}
	local function add(unit)
		if UnitExists(unit) then
			local _, class = UnitClass(unit)
			list[#list + 1] = { unit = unit, guid = UnitGUID(unit), name = UnitName(unit), class = class }
		end
	end
	if IsInRaid() then
		local n, mySub = GetNumGroupMembers(), nil
		for i = 1, n do
			if UnitIsUnit("raid" .. i, "player") then mySub = select(3, GetRaidRosterInfo(i)); break end
		end
		for i = 1, n do
			if select(3, GetRaidRosterInfo(i)) == mySub then add("raid" .. i) end
		end
	elseif IsInGroup() then
		add("player")
		for i = 1, 4 do add("party" .. i) end
	end
	-- Optional: only show the players Windfury helps (melee). The dimmed non-melee rows
	-- (hunters, casters, the shaman itself) drop out entirely instead of just fading.
	if M.db and M.db.wfMeleeOnly then
		local keep = {}
		for _, e in ipairs(list) do
			if e.class == "WARRIOR" or e.class == "ROGUE" then keep[#keep + 1] = e end
		end
		list = keep
	end
	table.sort(list, function(a, b)
		local pa, pb = CLASS_ORDER[a.class] or 99, CLASS_ORDER[b.class] or 99
		if pa ~= pb then return pa < pb end
		return (a.name or a.guid or "") < (b.name or b.guid or "")
	end)
	return list
end

local function assignUnits()
	if InCombatLockdown() then pendingAssign = true; return end
	sorted = computeSorted()
	wipe(lastExpires)   -- drop departed members' WF history (pop is settle-suppressed anyway)
	for i = 1, MAX do
		local b, m = buttons[i], sorted[i]
		if m then
			b.unit, b.guid, b.class = m.unit, m.guid, m.class
			b:SetAttribute("unit", m.unit)
			b:Show()
		else
			b.unit, b.guid, b.class = nil, nil, nil
			b:SetAttribute("unit", nil)
			b:Hide()
		end
	end
	settleAt = GetTime() + SETTLE
end

--------------------------------------------------------------------------------
-- preview
--------------------------------------------------------------------------------
local PREVIEW
local function renderPreview()
	PREVIEW = PREVIEW or {
		{ name = "Grognak",   class = "WARRIOR", hp = 0.9, pt = "RAGE",   pw = 0.4, wf = "melee",  secs = 9,
		  air = airIcon, earth = earthIcon, water = waterIcon },
		{ name = "Sneakyboi", class = "ROGUE",   hp = 0.7, pt = "ENERGY", pw = 0.8, wf = "red",
		  air = airIcon, earth = earthIcon },
		{ name = "Bexxa",     class = "MAGE",    hp = 1.0, pt = "MANA",   pw = 0.6, wf = "faded", secs = 9,
		  earth = earthIcon, fire = fireIcon },
	}
	for c = 1, 5 do frame.headers[c].inner:SetScale(1) end
	frame.headers[1].icon:SetTexture(wfIcon); frame.headers[1].icon:Show()
	frame.headers[1].text:SetText("22"); frame.headers[1].text:SetTextColor(1, 1, 1); frame.headers[1].text:Show()
	frame.headers[2].icon:SetTexture(airIcon); frame.headers[2].icon:Show(); frame.headers[2].text:Hide()  -- >30s: icon only
	frame.headers[3].icon:SetTexture(earthIcon); frame.headers[3].icon:Show()
	frame.headers[3].text:SetText("8"); frame.headers[3].text:SetTextColor(1, 1, 1); frame.headers[3].text:Show()
	for c = 4, 5 do frame.headers[c].icon:Hide(); frame.headers[c].text:Hide() end

	local safe = not InCombatLockdown()
	for i = 1, MAX do
		local b, d = buttons[i], PREVIEW[i]
		if d then
			b.health:SetMinMaxValues(0, 1); b.health:SetValue(d.hp)
			local cc = RAID_CLASS_COLORS[d.class]; b.health:SetStatusBarColor(cc.r, cc.g, cc.b)
			b.name:SetText(d.name)
			b.power:SetMinMaxValues(0, 1); b.power:SetValue(d.pw)
			b.power:SetStatusBarColor(powerColor(d.pt))
			b.colWF:SetTexture(wfIcon); b.colWF:SetDesaturated(d.wf ~= "melee")
			if d.wf == "melee" then
				b.colWF:SetVertexColor(1, 1, 1); b.colWF:SetAlpha(1)
				b.wfTimer:SetAlpha(1); b.wfTimer:SetText(tostring(d.secs)); b.wfTimer:Show()
			elseif d.wf == "red" then
				b.colWF:SetVertexColor(RED[1], RED[2], RED[3]); b.colWF:SetAlpha(1); b.wfTimer:Hide()
			else -- faded (non-melee with WF)
				b.colWF:SetDesaturated(false); b.colWF:SetVertexColor(1, 1, 1); b.colWF:SetAlpha(0.4)
				b.wfTimer:SetAlpha(0.4); b.wfTimer:SetText(tostring(d.secs)); b.wfTimer:Show()
			end
			b.colWFBd:SetAlpha(b.colWF:GetAlpha())
			setCol(b.colAir, b.colAirBd, d.air)
			setCol(b.colEarth, b.colEarthBd, d.earth)
			setCol(b.colWater, b.colWaterBd, d.water)
			setCol(b.colFire, b.colFireBd, d.fire)
			if safe then b:Show() end
		elseif safe then
			b:Hide()
		end
	end
end

--------------------------------------------------------------------------------
-- ticker
--------------------------------------------------------------------------------
local active = false -- module enabled? gates refresh so a settings toggle can't show the frame while disabled

local function refresh()
	if not frame then return end
	if not active then frame:Hide(); wfWasPresent = false; return end
	if M.db.wfEnabled == false then frame:Hide(); wfWasPresent = false; return end
	frame:Show()
	if not M.db.locked then renderPreview(); wfWasPresent = false; return end

	local now = GetTime()
	local canPop = now > settleAt

	-- pass 1: raw WF per member + the freshest expiry
	local freshest
	for i = 1, MAX do
		local b = buttons[i]
		if b.unit then
			local has, exp = getWF(b, now)
			b._wfHas, b._wfExp = has, exp
			if has and exp and (not freshest or exp > freshest) then freshest = exp end
		end
	end

	-- cluster-align each WF-haver (within CLUSTER of the freshest snaps to it -- same
	-- totem pulse => same number; anyone genuinely behind keeps their own ticking
	-- value), and track the LOWEST remaining WF (soonest to lose it).
	local minWF
	for i = 1, MAX do
		local b = buttons[i]
		if b.unit and b._wfHas then
			local exp = b._wfExp
			if freshest and (freshest - exp) <= CLUSTER then exp = freshest end
			b._wfAligned = exp
			local rem = exp - now
			if not minWF or rem < minWF then minWF = rem end
		elseif b.unit then
			b._wfAligned = nil
		end
	end

	local wfTotemDown = updateHeaderTimers(now, minWF)

	-- WF fully dropped from the party (nobody reporting it AND no totem down) -> sound
	local wfPresent = wfTotemDown or (minWF ~= nil)
	if wfWasPresent and not wfPresent and now > settleAt and IsInGroup()
		and M.db.wfDropSound ~= false then
		M.WF_PlaySound(M.db.wfSoundIdx or 1)
	end
	wfWasPresent = wfPresent

	-- pass 2: render with the aligned expiry
	for i = 1, MAX do
		local b = buttons[i]
		if b.unit then updateButton(b, now, canPop, b._wfHas, b._wfAligned) end
	end
end

--------------------------------------------------------------------------------
-- build
--------------------------------------------------------------------------------
local function makeBorder(parent, target)
	local b = parent:CreateTexture(nil, "BORDER")
	b:SetColorTexture(0, 0, 0, 1)
	b:SetPoint("TOPLEFT", target, "TOPLEFT", -1, 1)
	b:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 1, -1)
	return b
end

local function fadeAnim(tex, from, dur)
	tex:SetAlpha(0)
	local ag = tex:CreateAnimationGroup()
	local a = ag:CreateAnimation("Alpha")
	a:SetFromAlpha(from); a:SetToAlpha(0); a:SetDuration(dur); a:SetSmoothing("OUT")
	return ag
end

local function buildButton(i)
	local b = CreateFrame("Button", "AssfishButtBassPartyBtn" .. i, frame, "SecureUnitButtonTemplate")
	b:SetSize(ROW_W, ROW_H)
	if i == 1 then b:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -HEADER_H)
	else b:SetPoint("TOPLEFT", buttons[i - 1], "BOTTOMLEFT", 0, -ROW_GAP) end

	b:EnableMouse(true)
	b:RegisterForClicks("AnyUp")
	b:SetAttribute("*type1", "target")
	b:SetAttribute("*type2", "togglemenu")
	b:SetScript("OnEnter", function(self)
		if self.unit and UnitExists(self.unit) then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetUnit(self.unit); GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	b.health = CreateFrame("StatusBar", nil, b)
	b.health:SetPoint("TOPLEFT", 0, 0)
	b.health:SetSize(BAR_W, HP_H)
	b.health:SetStatusBarTexture(BAR_TEX)
	b.health:SetMinMaxValues(0, 1); b.health:SetValue(1)
	local hbg = b.health:CreateTexture(nil, "BACKGROUND"); hbg:SetAllPoints(); hbg:SetColorTexture(0, 0, 0, 0.7)
	b.name = b.health:CreateFontString(nil, "OVERLAY")
	b.name:SetFont(STANDARD_TEXT_FONT, NAME_FONT, "OUTLINE")
	b.name:SetPoint("LEFT", b.health, "LEFT", 3, 0)
	b.name:SetPoint("RIGHT", b.health, "RIGHT", -3, 0)
	b.name:SetJustifyH("RIGHT")   -- right-aligned, snug to the WF icon, grows left
	b.name:SetTextColor(1, 1, 1)

	b.power = CreateFrame("StatusBar", nil, b)
	b.power:SetPoint("TOPLEFT", b.health, "BOTTOMLEFT", 0, -1)
	b.power:SetSize(BAR_W, PW_H)
	b.power:SetStatusBarTexture(BAR_TEX)
	b.power:SetMinMaxValues(0, 1); b.power:SetValue(1)
	local pbg = b.power:CreateTexture(nil, "BACKGROUND"); pbg:SetAllPoints(); pbg:SetColorTexture(0, 0, 0, 0.7)

	local function col(anchorLeftTo, dx)
		local t = b:CreateTexture(nil, "ARTWORK")
		t:SetSize(ICON, ICON)
		t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		if anchorLeftTo == b then t:SetPoint("LEFT", b, "LEFT", dx, 0)
		else t:SetPoint("LEFT", anchorLeftTo, "RIGHT", dx, 0) end
		return t, makeBorder(b, t)
	end
	b.colWF,    b.colWFBd    = col(b, BAR_W + COL_GAP)
	b.colAir,   b.colAirBd   = col(b.colWF, COL_GAP)
	b.colEarth, b.colEarthBd = col(b.colAir, COL_GAP)
	b.colWater, b.colWaterBd = col(b.colEarth, COL_GAP)
	b.colFire,  b.colFireBd  = col(b.colWater, COL_GAP)

	b.wfTimer = b:CreateFontString(nil, "OVERLAY", nil, 3)
	b.wfTimer:SetFont(STANDARD_TEXT_FONT, TIMER_FONT, "OUTLINE")
	b.wfTimer:SetPoint("CENTER", b.colWF, "CENTER", 0, 0)
	b.wfTimer:SetTextColor(1, 1, 1)

	b.glow = b:CreateTexture(nil, "BACKGROUND")
	b.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	b.glow:SetBlendMode("ADD"); b.glow:SetVertexColor(1, 0.95, 0.4)
	b.glow:SetPoint("CENTER", b.colWF, "CENTER"); b.glow:SetSize(ICON * 2.1, ICON * 2.1)
	b.glowAG = fadeAnim(b.glow, 1, 0.8)

	b.flash = b:CreateTexture(nil, "OVERLAY", nil, 1)
	b.flash:SetTexture("Interface\\Buttons\\WHITE8X8"); b.flash:SetBlendMode("ADD")
	b.flash:SetAllPoints(b.colWF)
	b.flashAG = fadeAnim(b.flash, 0.9, 0.5)

	b.colWF:SetTexture(wfIcon); b.wfTimer:Hide()
	b.colAir:Hide();   b.colAirBd:Hide()
	b.colEarth:Hide(); b.colEarthBd:Hide()
	b.colWater:Hide(); b.colWaterBd:Hide()
	b.colFire:Hide();  b.colFireBd:Hide()

	b:Hide()
	return b
end

--------------------------------------------------------------------------------
-- public
--------------------------------------------------------------------------------
function M.WFDisplay_ApplyPosition()
	if not frame then return end
	local p = M.db.wfPos or {}
	frame:ClearAllPoints()
	frame:SetPoint(p.point or "CENTER", UIParent, p.relPoint or p.point or "CENTER", p.x or 0, p.y or 0)
end

function M.WFDisplay_ApplyScale()
	if frame then frame:SetScale(M.db.wfScale or 1) end
end

function M.WFDisplay_SetLocked(locked)
	if not frame then return end
	if locked then
		frame.bg:Hide(); frame.label:Hide(); dragOverlay:Hide()
		assignUnits()
	else
		frame.bg:Show(); frame.label:Show(); dragOverlay:Show()
	end
	refresh()
end

function M.WFDisplay_ApplyEnabled()
	refresh()
end

-- Roster / combat-end hooks, called by Core's module event frame (this file owns no
-- event frame of its own so Disable has nothing to unregister).
function M.WFDisplay_OnRosterChange()
	if frame then assignUnits() end
end

function M.WFDisplay_OnCombatEnd()
	if frame and pendingAssign then pendingAssign = false; assignUnits() end
end

-- Build the (secure) frames ONCE. Core guards this against combat before calling.
function M.WFDisplay_Init()
	if frame then return end
	wfIcon    = spellTexture(WF_TOTEM_SPELL)
	airIcon   = spellTexture(8835)   -- preview icons only; live rows use the buff's icon
	earthIcon = spellTexture(8075)
	waterIcon = spellTexture(5675)
	fireIcon  = spellTexture(8181)

	frame = CreateFrame("Frame", "AssfishButtBassPartyFrame", UIParent)
	frame:SetSize(ROW_W, HEADER_H + ROW_H * 3 + ROW_GAP * 2)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)

	frame.bg = frame:CreateTexture(nil, "BACKGROUND")
	frame.bg:SetPoint("TOPLEFT", -3, 3); frame.bg:SetPoint("BOTTOMRIGHT", 3, -3)
	frame.bg:SetColorTexture(0, 0, 0, 0.5); frame.bg:Hide()

	frame.label = frame:CreateFontString(nil, "OVERLAY")
	frame.label:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
	frame.label:SetPoint("BOTTOM", frame, "TOP", 0, 4)
	frame.label:SetText("Shaman Stuff party - drag to move")
	frame.label:Hide()

	-- header totem-duration timers, one per column
	frame.headers = {}
	for c = 1, 5 do
		local h = CreateFrame("Frame", nil, frame)   -- positioned (NEVER scaled)
		h:SetSize(ICON, HEADER_H)
		h:SetPoint("CENTER", frame, "TOPLEFT", colCenterX(c), -HEADER_H / 2)
		-- inner frame carries the pulse; anchored at zero offset so scaling it grows
		-- in place instead of dragging the (large) position offset sideways
		-- icon is a direct child of h and is NEVER scaled -- only the text bounces
		h.icon = h:CreateTexture(nil, "ARTWORK")
		h.icon:SetSize(ICON, ICON)                 -- as large as the per-row column icons
		h.icon:SetPoint("CENTER", h, "CENTER", 0, 0)
		h.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		h.icon:Hide()
		-- per-column fallback texture, so a column never briefly flashes the WF icon
		-- while GetTotemInfo resolves a freshly-cast totem's real icon.
		h.defaultIcon = ({ wfIcon, airIcon, earthIcon, waterIcon, fireIcon })[c]
		-- the countdown lives in a zero-offset inner frame that gets pulse-scaled, so
		-- only the number grows/shrinks in place (the icon stays put)
		h.inner = CreateFrame("Frame", nil, h)
		h.inner:SetSize(ICON, HEADER_H)
		h.inner:SetPoint("CENTER", h, "CENTER", 0, 0)
		h.text = h.inner:CreateFontString(nil, "OVERLAY")
		h.text:SetFont(STANDARD_TEXT_FONT, HEAD_FONT, "THICKOUTLINE")
		h.text:SetPoint("CENTER", h.inner, "CENTER", 0, 0)
		h.text:Hide()
		frame.headers[c] = h
	end

	buttons = {}
	for i = 1, MAX do buttons[i] = buildButton(i) end

	dragOverlay = CreateFrame("Frame", nil, frame)
	dragOverlay:SetAllPoints()
	dragOverlay:SetFrameLevel(buttons[1]:GetFrameLevel() + 10)
	dragOverlay:EnableMouse(true)
	dragOverlay:RegisterForDrag("LeftButton")
	dragOverlay:SetScript("OnDragStart", function() frame:StartMoving() end)
	dragOverlay:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, relPoint, x, y = frame:GetPoint()
		M.db.wfPos = { point = point, relPoint = relPoint, x = x, y = y }
	end)
	dragOverlay:Hide()
end

-- Start the refresh ticker + first roster assignment (module enabled). The ticker is
-- created via core.NewTicker so the core cancels it on Disable.
function M.WFDisplay_Enable()
	active = true
	if not frame then return end
	M.WFDisplay_ApplyScale()
	M.WFDisplay_ApplyPosition()
	assignUnits()
	ticker = core.NewTicker("bb", TICK, refresh)
	refresh()
end

-- Hide the frame (never delete it) + stop the ticker so a stray tick can't re-show it.
function M.WFDisplay_Disable()
	active = false
	if ticker then ticker:Cancel(); ticker = nil end
	if frame then frame:Hide() end
	wfWasPresent = false
	pendingAssign = false
end
