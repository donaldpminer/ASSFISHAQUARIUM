--[[--------------------------------------------------------------------------
	ButtBass - Core (Restoration Shaman helper)

	Combat-log parsing, Chain Heal cast grouping, saved-var defaults, slash commands
	and the module lifecycle. Display/animation lives in Display.lua; the party frame
	in WFDisplay.lua; the always-on Windfury announcer is a shared SERVICE in
	Windfury.lua (it runs regardless of this module's enable state).

	Integration notes (vs the standalone addon):
	  * The old Shaman-only PLAYER_LOGIN gate is gone -- the per-character module
	    enable (perChar = true) IS the gate now. A Shaman leaves ButtBass enabled; a
	    non-Shaman can hide it. The heal tracker self-gates anyway (it never matches a
	    non-Shaman's heals) and the party frame only appears in a group.
	  * Windfury comms became a service (core.RegisterService) so they broadcast for
	    every class even while the ButtBass panels are hidden.
	  * SavedVariables handling / minimap button / own Settings category were dropped;
	    the umbrella core provides M.db, the one minimap button and the Settings page.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
-- Display name is "Shaman Stuff"; the internal key stays "bb". Enabled by default only on
-- Shamans (the class check runs at first-run seed time, i.e. login, when the class is known).
local M = core.RegisterModule({
	key = "bb", title = "Shaman Stuff", perChar = true,
	default = function() return select(2, UnitClass("player")) == "SHAMAN" end,
})

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
M.CHAIN_HEAL_ICON = "Interface\\Icons\\Spell_Nature_HealingWaveGreater"  -- fallback only
M.MAX_BOUNCES     = 3                  -- most icons a cast can ever show
M.GROUP_WINDOW    = 0.35               -- SPELL_HEAL events within this window = one cast
M.OVERHEAL_WASTE  = 0.97               -- overheal fraction that flags a heal as "wasted"

-- Tracked Shaman heals, keyed by a base rank-1 spellId. Names are localized at
-- login via GetSpellInfo, so detection is language-independent.
--   maxTargets = most heals one cast can produce (grouped as bounces)
--   pad        = always show maxTargets rows, red-tinting the ones that didn't
--                land (Chain Heal only; the single-target heals just show what
--                actually happened -- Healing Wave "bounces" only with the T1 set)
M.HEAL_CONFIG = {
	[1064] = { key = "chain_heal",   maxTargets = 3, pad = true  },  -- Chain Heal
	[331]  = { key = "healing_wave", maxTargets = 3, pad = false },  -- Healing Wave (T1 = bounces)
	[8004] = { key = "lesser_hw",    maxTargets = 1, pad = false },  -- Lesser Healing Wave
}
M.healByName = {}   -- localized spell name -> config (built in Enable)

-- Fallback rank lookup for the vanilla/Era Chain Heal ranks; GetSpellSubtext is
-- tried first (covers every heal/rank) and this backs it up.
local RANK_BY_ID = { [1064] = 1, [10622] = 2, [10623] = 3 }

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
M.playerGUID = nil
M.unitByGUID = {}   -- GUID -> unit token, for reading target health at heal time

-- The cast currently being accumulated. All bounces of one Chain Heal arrive in
-- the same frame, so we group SPELL_HEAL events that land within GROUP_WINDOW of
-- the first one (up to MAX_BOUNCES). The Display reads this table live as it
-- staggers the reveal, so late-arriving bounces are already present by then.
local cast = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function printMsg(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffShaman Stuff|r: " .. msg)
end

-- Resolve a spell's icon across the retail/Classic API split; `fallback` when the
-- id is nil or unknown. Shared by the heal tracker (Display) and party frame (WFDisplay).
function M.SpellTexture(id, fallback)
	if id then
		if C_Spell and C_Spell.GetSpellTexture then
			local t = C_Spell.GetSpellTexture(id); if t then return t end
		elseif GetSpellTexture then
			local t = GetSpellTexture(id); if t then return t end
		end
	end
	return fallback
end

-- "Name-Realm" -> "Name" (drop the cross-realm suffix).
local function shortName(name)
	if not name then return "?" end
	return name:match("^([^-]+)") or name
end

-- Rank number for a Chain Heal spellId. GetSpellSubtext gives "Rank 3" for the
-- exact rank the combat log reports (reliable at cast time); fall back to the map.
local function spellRank(spellId)
	local sub = GetSpellSubtext and GetSpellSubtext(spellId)
	local n = sub and sub:match("(%d+)")
	if n then return tonumber(n) end
	return RANK_BY_ID[spellId]
end

-- Rebuild the GUID -> unit-token map from the current group so we can read a
-- heal target's health. Refreshed on roster/zone changes (cheap, event-driven).
local function refreshRoster()
	wipe(M.unitByGUID)
	local function add(u)
		if UnitExists(u) then
			local g = UnitGUID(u)
			if g then M.unitByGUID[g] = u end
		end
	end
	add("player"); add("pet")
	if IsInRaid() then
		for i = 1, 40 do add("raid" .. i); add("raidpet" .. i) end
	else
		for i = 1, 4 do add("party" .. i); add("partypet" .. i) end
	end
end
M.refreshRoster = refreshRoster

-- Reading a unit's health needs a unit token. The roster map covers your
-- party/raid + yourself; for anyone else (e.g. healing a non-group player in
-- town) we also probe transient tokens live at heal time. UnitGUID returns nil
-- for a missing token, so the `== guid` check doubles as an existence test.
local TRANSIENT_UNITS = { "target", "mouseover", "focus", "targettarget" }

local function resolveUnit(guid)
	local u = M.unitByGUID[guid]
	if u and UnitGUID(u) == guid then return u end          -- group member (cached)
	for _, t in ipairs(TRANSIENT_UNITS) do
		if UnitGUID(t) == guid then return t end
	end
	for i = 1, 40 do                                        -- visible nameplates
		local np = "nameplate" .. i
		if UnitGUID(np) == guid then return np end
	end
	return nil
end

-- The 3-part health bar: [health before the heal][effective heal][still missing].
-- Read at heal time so UnitHealth reflects the post-heal value; we subtract the
-- known effective heal to recover the pre-heal health. Returns nil if the target
-- can't be resolved to any unit token (then the Display just omits the bar).
local function healBar(destGUID, effective)
	local unit = resolveUnit(destGUID)
	if not unit then return nil end
	local maxHP = UnitHealthMax(unit)
	if not maxHP or maxHP <= 0 then return nil end
	local after = UnitHealth(unit)
	if after > maxHP then after = maxHP end
	local healed  = math.min(effective, after)  -- can't have healed more than they now have
	local before  = after - healed
	local missing = maxHP - after
	return { max = maxHP, before = before, healed = healed, missing = missing }
end

--------------------------------------------------------------------------------
-- Combat log (routed here by core.SubscribeCLEU while the module is enabled)
--------------------------------------------------------------------------------
local function onHeal(cfg, spellId, destGUID, destName, amount, overheal, critical)
	local now = GetTime()
	local amt = amount or 0
	local oh  = overheal or 0
	local effective = math.max(0, amt - oh)
	local _, classToken = GetPlayerInfoByGUID(destGUID)  -- englishClass or nil

	local heal = {
		amount     = amt,
		overheal   = oh,
		effective  = effective,
		wasted     = amt > 0 and (oh / amt) >= M.OVERHEAL_WASTE,  -- ~all overheal
		destGUID   = destGUID,
		unitName   = shortName(destName),
		classToken = classToken,
		crit       = critical and true or false,
		spellId    = spellId,
		rank       = spellRank(spellId),
		bar        = healBar(destGUID, effective),
	}

	-- A new cast if there's no live group, the window lapsed, it's a different
	-- spell, or the current group already hit that spell's target cap.
	if (not cast)
		or (now - cast.start > M.GROUP_WINDOW)
		or (cast.key ~= cfg.key)
		or (#cast.heals >= cast.maxTargets)
	then
		cast = {
			start = now, key = cfg.key, spellId = spellId,
			maxTargets = cfg.maxTargets, pad = cfg.pad, heals = { heal },
		}
		-- Defer one frame so all of this cast's bounces (same frame, sometimes out of
		-- order) are collected before Display sorts + renders them.
		local thisCast = cast
		C_Timer.After(0, function() if M.Display_NewCast then M.Display_NewCast(thisCast) end end)
	else
		cast.heals[#cast.heals + 1] = heal
	end
end

-- CLEU handler. May call CombatLogGetCurrentEventInfo() itself (core does not pass args).
local function onCombatLog()
	-- SPELL_HEAL layout: ...(11 base fields)..., spellId, spellName, spellSchool,
	-- amount, overhealing, absorbed, critical.
	local _, sub, _, srcGUID, _, _, _, destGUID, destName, _, _,
		spellId, spellName, _, amount, overheal, _, critical =
		CombatLogGetCurrentEventInfo()

	if sub ~= "SPELL_HEAL" then return end
	if srcGUID ~= M.playerGUID then return end
	local cfg = M.healByName[spellName]
	if not cfg then return end

	onHeal(cfg, spellId, destGUID, destName, amount, overheal, critical)
end

--------------------------------------------------------------------------------
-- Saved-var defaults (M.db is our per-character slice, assigned by core at login).
-- Idempotent: only fills a field when it is still nil, so it is safe to call from
-- Enable AND BuildSettings (the settings page must read correct defaults even while
-- the module is disabled). `locked` is intentionally NOT seeded here -- the shared
-- tri-state (SetDisplayState) owns it.
--------------------------------------------------------------------------------
function M.SeedDB()
	local db = M.db
	db.pos = db.pos or { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
	if db.chEnabled == nil then db.chEnabled = true end
	db.chLayout = db.chLayout or "heal_name"   -- "heal_name" | "name_heal"
	db.chScale  = db.chScale or 1              -- 0.5 .. 2.5 in 0.25 steps
	if db.wfEnabled == nil then db.wfEnabled = true end
	db.wfScale = db.wfScale or 1
	db.wfPos = db.wfPos or { point = "CENTER", relPoint = "CENTER", x = 240, y = 0 }
	if db.wfDropSound == nil then db.wfDropSound = true end   -- play a cue when WF drops
	db.wfSoundIdx = db.wfSoundIdx or 1
	if db.windfury == nil then db.windfury = true end         -- the always-on announcer service
end

--------------------------------------------------------------------------------
-- Module lifecycle (driven by the shared core)
--   The heal tracker (Display) + party frame (WFDisplay) ARE the module. The heal
--   tracker's non-CLEU needs (roster) and the party frame's roster/combat hooks live
--   on a module-owned event frame so Disable can drop them wholesale. The ONE
--   COMBAT_LOG_EVENT_UNFILTERED registration lives in core and reaches us only while
--   we're subscribed (i.e. enabled).
--------------------------------------------------------------------------------
local liveEvents

-- Build + start the (secure) party frame. Secure unit buttons cannot be created or
-- have their unit reassigned in combat, so if we're locked down we defer the whole
-- thing to PLAYER_REGEN_ENABLED (the heal tracker, which is insecure, builds anyway).
local function ensureWFDisplay()
	if InCombatLockdown() then M._wfPending = true; return end
	M._wfPending = false
	if M.WFDisplay_Init then M.WFDisplay_Init() end
	if M.WFDisplay_Enable then M.WFDisplay_Enable() end
	if M.WFDisplay_SetLocked then M.WFDisplay_SetLocked(M.db.locked) end
end

local function onLiveEvent(_, event)
	if event == "PLAYER_REGEN_ENABLED" then
		if M._wfPending then ensureWFDisplay() end      -- deferred secure build now allowed
		if M.WFDisplay_OnCombatEnd then M.WFDisplay_OnCombatEnd() end
	else -- GROUP_ROSTER_UPDATE / PLAYER_ENTERING_WORLD
		refreshRoster()
		if M.WFDisplay_OnRosterChange then M.WFDisplay_OnRosterChange() end
	end
end

-- Enable: build frames + start tracking. M.db was assigned by core before this runs.
function M.Enable()
	M.SeedDB()
	M.playerGUID = UnitGUID("player")
	-- localize tracked heal names (works even for spells not yet learned)
	for baseId, cfg in pairs(M.HEAL_CONFIG) do
		local name = GetSpellInfo(baseId)
		if name then M.healByName[name] = cfg end
	end
	refreshRoster()

	if M.Display_Init then M.Display_Init() end
	if M.Display_Show then M.Display_Show() end
	ensureWFDisplay()

	if not liveEvents then
		liveEvents = CreateFrame("Frame")
		liveEvents:SetScript("OnEvent", onLiveEvent)
	end
	liveEvents:RegisterEvent("GROUP_ROSTER_UPDATE")
	liveEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
	liveEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
	core.SubscribeCLEU("bb", onCombatLog)
end

-- Disable: tear everything down (core has already cancelled our CLEU sub; it cancels
-- tickers AFTER this, so WFDisplay_Disable cancels its own ticker first to stop a
-- stray refresh from re-showing the frame).
function M.Disable()
	if liveEvents then liveEvents:UnregisterAllEvents() end
	if M.Display_Hide then M.Display_Hide() end
	if M.WFDisplay_Disable then M.WFDisplay_Disable() end
	M._wfPending = false
end

-- Tri-state display: "hidden" is handled by core via Disable; here we only apply the
-- lock (locked = pinned / no drag background) to both panels while shown.
function M.SetDisplayState(_, state)
	M.db.locked = (state == "locked")
	if M.Display_SetLocked then M.Display_SetLocked(M.db.locked) end
	if M.WFDisplay_SetLocked then M.WFDisplay_SetLocked(M.db.locked) end
end

--------------------------------------------------------------------------------
-- Slash (forwarded by the router: /bb, /buttbass, /aq bb ...)
--------------------------------------------------------------------------------
function M.OnSlash(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = msg:match("^(%S*)%s*(.*)$")

	if cmd == "" or cmd == "lock" or cmd == "unlock" then
		local s = core.GetModuleState("bb")
		local target
		if cmd == "lock" then target = "locked"
		elseif cmd == "unlock" then target = "unlocked"
		else target = (s == "locked") and "unlocked" or "locked" end
		core.SetModuleState("bb", target)
	elseif cmd == "test" then
		if M.Display_Test then M.Display_Test(tonumber(rest)) end   -- nil = random 1..3 bounces
	elseif cmd == "reset" then
		M.db.pos = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
		if M.Display_ApplyPosition then M.Display_ApplyPosition() end
		printMsg("heal display position reset to center.")
	elseif cmd == "wf" then
		local all = M.WF_GetAll and M.WF_GetAll() or {}
		if #all == 0 then
			printMsg("no Windfury heard yet (need a group with WF Now / Shaman Stuff users).")
		else
			printMsg("Windfury status heard (" .. #all .. "):")
			for _, e in ipairs(all) do
				local who = e.name or e.guid
				if e.hasWF then
					printMsg(string.format("  %s - WF r%s, %.1fs left [%s]",
						who, tostring(e.rank or "?"), e.remaining or 0, e.source or "?"))
				else
					printMsg(string.format("  %s - no WF [%s]", who, e.source or "?"))
				end
			end
		end
	elseif cmd == "options" or cmd == "opt" or cmd == "config" then
		core.OpenSettings()
	else
		printMsg("commands: |cffffff00/bb|r move mode, "
			.. "|cffffff00/bb test [1-3]|r preview, "
			.. "|cffffff00/bb reset|r recenter, "
			.. "|cffffff00/bb wf|r Windfury debug, "
			.. "|cffffff00/bb options|r settings.")
	end
end
