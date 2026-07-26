-- Sunderboard :: Core.lua
-- Combat-log engine: tracks armor-reduction debuffs per target, attributes them
-- to the players who applied them, and converts physical damage taken by those
-- targets into points.
--
-- SCORING MODEL (marginal damage enabled)
--   Each target has an ESTIMATED base armor from its level + tier (see Data.lua). For each
--   physical, non-bleed hit of `amount` on a target with one or more tracked armor debuffs, we
--   use the real armor->damage formula to find how much EXTRA damage the stripped armor let
--   through -- the hit landing at the softened armor (base - removed) minus what it would have
--   been at full base armor -- then split that extra among the active debuffs in proportion to
--   the armor each removes, awarding each debuff's share to whoever applied it. So the per-hit
--   pot grows with how much armor was stripped (and with how much damage flows through), and
--   every point of armor removed is valued equally (each Sunder stack the same -- no last-stack
--   bias). This rewards debuffing EARLY, on HIGHER-HP / MORE targets, and DEEP-softening a target
--   -- fixing the old relative-weight split where monopolizing a lightly-sundered target could
--   beat sharing a deeply-stacked one. Board totals ~= the extra physical damage the raid enabled
--   through armor debuffs.
--
-- Why physical, non-bleed only: armor mitigates physical damage, so only that
-- damage benefits from these debuffs. Bleeds (Rend, Rip, Deep Wounds, ...) are
-- physical school but IGNORE armor, so they must not count -- we drop all
-- SPELL_PERIODIC_DAMAGE to exclude them.
--
-- MODULE LIFECYCLE (Assfish Aquarium): the umbrella's tri-state IS the master
-- switch. Enable() = start scoring + build/show the board; Disable() = stop
-- scoring + hide it. The one COMBAT_LOG_EVENT_UNFILTERED registration lives in
-- core and is fanned out to us only while we're subscribed (i.e. enabled), so a
-- disabled module scores nothing. The board's DATA persists in the account SV
-- (M.db) across enable/disable and /reload.

local ADDON, ns = ...
local core = ns.core
local M = ns.modules.sb
local D = M.Data

local Core = {}
M.Core = Core

local bband = bit.band
local FLAG_PLAYER = 0x00000400  -- COMBATLOG_OBJECT_TYPE_PLAYER
local SCHOOL_PHYSICAL = 1       -- SCHOOL_MASK_PHYSICAL

-- session.points: [guid] = { name, class, total, byKey = {sunder,expose,faerie,reck} }
-- session lives partly in SavedVariables so a /reload mid-raid keeps the board.
--   active  = SCORING gate: only true inside a dungeon/raid instance.
--   visible = WINDOW gate: true whenever grouped (party/raid) or in an instance.
local session = { active = false, visible = false, instanceID = nil, label = nil, points = {} }
M.session = session

-- tracked[destGUID][key] = auraState
--   auraState = { key, def, applied, stacks,
--                 sourceGUID, sourceName, class,   -- single-caster debuffs
--                 owners = { [guid] = {name,class,stacks} } }  -- sunder only
local tracked = {}
-- Estimated base armor per target, kept SEPARATE from `tracked` (which onDamage iterates with
-- pairs()) so a cached scalar never lands among the auraState tables. [destGUID] = armor number.
local baseArmorCache = {}

-- ---------------------------------------------------------------- helpers --

local function classOf(guid)
	if not guid then return nil end
	local _, class = GetPlayerInfoByGUID(guid)
	return class
end

local function playerGUID()
	return UnitGUID("player")
end

-- ---------------------------------------------------------------- scoring --

local function ensurePlayer(guid, name, class)
	local p = session.points[guid]
	if not p then
		p = {
			name = name or UNKNOWN,
			class = class or classOf(guid),
			total = 0,
			byKey = { sunder = 0, expose = 0, faerie = 0, reck = 0 },
			casts = {},      -- [key] = total casts of that armor debuff
			effective = {},  -- [key] = casts that actually did work
		}
		session.points[guid] = p
	else
		if name then p.name = name end
		if not p.class then p.class = class or classOf(guid) end
		p.casts = p.casts or {}          -- back-fill records persisted before this
		p.effective = p.effective or {}
	end
	return p
end

local function award(guid, name, class, key, pts)
	if not guid or pts <= 0 then return end
	local p = ensurePlayer(guid, name, class)
	p.total = p.total + pts
	p.byKey[key] = (p.byKey[key] or 0) + pts
end

-- ------------------------------------------------------------ fall-off msg --

local function notifyFalloff(a, destName)
	local mode = M.db and M.db.settings.notifyFalloff or "mine"
	if mode == "off" then return end

	local me = playerGUID()
	local isMine = (a.sourceGUID == me) or (a.owners and a.owners[me] ~= nil)
	if mode == "mine" and not isMine then return end

	local minUp = (M.db and M.db.settings.falloffMinUptime) or 3
	if (GetTime() - (a.applied or 0)) < minUp then return end  -- skip instant swaps

	local who = a.sourceName or (a.owners and next(a.owners) and a.owners[next(a.owners)].name) or "?"
	print(string.format("|cffff8000Sunderboard|r: %s on %s fell off (%s).",
		D.LABEL[a.key] or a.key, destName or "target", who or "?"))
end

-- ------------------------------------------------------ debuff state machine --

local function evictExclusive(td, def, destName)
	-- Sunder <-> Expose overwrite each other; evict the loser.
	if not def.exclusiveGroup then return end
	for k, a in pairs(td) do
		if a.key ~= def.key and a.def.exclusiveGroup == def.exclusiveGroup then
			notifyFalloff(a, destName)
			td[k] = nil
		end
	end
end

-- Sunder Armor is ONE shared debuff (max 5 stacks) that every warrior keeps
-- alive together. In Classic Era its stack/refresh AURA events are NOT reliably
-- tagged with the warrior who cast them -- they stick to whoever "owns" the
-- debuff object -- so we attribute PARTICIPATION from SPELL_CAST_SUCCESS (always
-- tagged with the true caster) and use the aura APPLIED/REMOVED events only for
-- presence + stack count.
--
-- A cast is credited only when it does real work: it must be about to ADD a
-- stack (target under 5 at cast time) AND it must land (no SPELL_MISSED). Casts
-- into an already-maxed 5-stack debuff, and missed/resisted casts, earn nothing.

-- Best-known current stack count: what we've observed, or -- if sunder is up but
-- we never saw it build (e.g. joined mid-fight) -- assume it's maxed.
local function sunderStacks(a)
	if a.stacks and a.stacks > 0 then return a.stacks end
	if a.active then return D.SUNDER_MAX_STACKS end
	return 0
end

local function ensureSunder(destGUID, def)
	local td = tracked[destGUID]
	if not td then td = {}; tracked[destGUID] = td end
	local a = td[def.key]
	if not a then
		a = { key = def.key, def = def, active = false,
		      stacks = 0, applied = GetTime(), owners = {} }
		td[def.key] = a
	end
	return a
end

-- Credit a warrior's Sunder weight, but only if this cast is adding a stack
-- (target under 5). Returns true when credited (an "effective" cast). Optimistic
-- vs. landing; undone in sunderMiss() if the attack was avoided.
local function sunderCast(destGUID, def, srcGUID, srcName)
	local td = tracked[destGUID]
	local existing = td and td[def.key]
	if existing and sunderStacks(existing) >= D.SUNDER_MAX_STACKS then
		return false  -- already at 5 stacks; this cast only refreshes -> doesn't count
	end
	local a = ensureSunder(destGUID, def)
	local o = a.owners[srcGUID]
	if not o then
		o = { name = srcName, class = classOf(srcGUID), weight = 0 }
		a.owners[srcGUID] = o
	end
	o.name = srcName or o.name
	o.weight = o.weight + 1
	return true
end

-- SPELL_CAST_SUCCESS of any tracked armor debuff -> tally the cast (and, for
-- sunder, the weight + "effective" count when it adds a stack). Effective for
-- single debuffs is tallied on APPLIED instead (see applySingle).
local function countCast(destGUID, def, srcGUID, srcName)
	local p = ensurePlayer(srcGUID, srcName)
	p.casts[def.key] = (p.casts[def.key] or 0) + 1
	if def.kind == "sunder" then
		if sunderCast(destGUID, def, srcGUID, srcName) then
			p.effective[def.key] = (p.effective[def.key] or 0) + 1
		end
	end
end

-- SPELL_MISSED of Sunder (miss / dodge / parry / resist / immune) -> the cast
-- didn't land. Undo the weight + effective credit, but only for a build attempt
-- (stacks < 5), symmetric with sunderCast (a missed refresh was never credited).
local function sunderMiss(destGUID, def, srcGUID)
	local td = tracked[destGUID]
	if not td then return end
	local a = td[def.key]
	if not a then return end
	if sunderStacks(a) >= D.SUNDER_MAX_STACKS then return end
	local o = a.owners[srcGUID]
	if o then
		o.weight = o.weight - 1
		if o.weight < 0 then o.weight = 0 end
	end
	local p = session.points[srcGUID]
	if p and p.effective[def.key] and p.effective[def.key] > 0 then
		p.effective[def.key] = p.effective[def.key] - 1
	end
end

-- Aura APPLIED/DOSE/REFRESH of Sunder -> it's present; note stack count.
local function sunderPresence(destGUID, destName, def, stacks)
	local td = tracked[destGUID]
	if not td then td = {}; tracked[destGUID] = td end
	evictExclusive(td, def, destName)
	local a = ensureSunder(destGUID, def)
	if not a.active then a.applied = GetTime() end
	a.active = true
	if stacks then a.stacks = stacks end
end

local function applySingle(destGUID, destName, def, srcGUID, srcName)
	local td = tracked[destGUID]
	if not td then td = {}; tracked[destGUID] = td end
	evictExclusive(td, def, destName)
	-- a fresh APPLIED of a single debuff is an effective cast (refreshes come
	-- through as SPELL_AURA_REFRESH and are ignored; misses never reach here).
	local p = ensurePlayer(srcGUID, srcName)
	p.effective[def.key] = (p.effective[def.key] or 0) + 1
	td[def.key] = {
		key = def.key, def = def, applied = GetTime(), stacks = 1,
		sourceGUID = srcGUID, sourceName = srcName, class = classOf(srcGUID),
	}
end

local function removeAura(destGUID, destName, def)
	local td = tracked[destGUID]
	if not td then return end
	local a = td[def.key]
	if a then
		notifyFalloff(a, destName)
		td[def.key] = nil
		if not next(td) then tracked[destGUID] = nil; baseArmorCache[destGUID] = nil end
	end
end

local function doseDown(destGUID, def, newStacks)
	local td = tracked[destGUID]
	if not td then return end
	local a = td[def.key]
	if not a then return end
	a.stacks = newStacks or 0
	if a.stacks <= 0 then
		td[def.key] = nil
		if not next(td) then tracked[destGUID] = nil; baseArmorCache[destGUID] = nil end
	end
end

-- A debuff contributes to scoring only if we can attribute it. Single debuffs
-- always can; sunder needs to be applied AND have at least one known caster
-- (otherwise it would steal share from Faerie Fire / CoR and award it to nobody).
local function ownerWeight(a)
	local sum = 0
	for _, o in pairs(a.owners) do sum = sum + o.weight end
	return sum
end

local function contributes(a)
	if a.owners then return a.active and ownerWeight(a) > 0 end
	return true
end

-- Armor this debuff is currently removing (sunder scales with its live stacks).
local function armorOf(a)
	local stacks = a.owners and sunderStacks(a) or a.stacks
	return D.ArmorValue(a.def, stacks)
end

-- Estimated base armor (no debuffs) for a target, cached on its tracked entry. Prefer an NPC-id
-- override; else read the mob's level if it happens to be your target/mouseover (cache only a
-- real level -- an unknown one defaults to 63 but stays refreshable as you target the mob).
local function resolveBaseArmor(destGUID)
	local cached = baseArmorCache[destGUID]
	if cached then return cached end
	local override = D.ARMOR_OVERRIDE[D.NpcId(destGUID) or 0]
	if override then baseArmorCache[destGUID] = override; return override end
	local lvl
	if UnitExists("target") and UnitGUID("target") == destGUID then
		lvl = UnitLevel("target")
	elseif UnitExists("mouseover") and UnitGUID("mouseover") == destGUID then
		lvl = UnitLevel("mouseover")
	end
	if lvl and lvl > 0 then
		baseArmorCache[destGUID] = D.BaseArmorForLevel(lvl)
		return baseArmorCache[destGUID]
	end
	return D.BaseArmorForLevel(nil) -- unknown level -> assume a level-63 raid mob (3731); don't cache
end

local function onDamage(destGUID, amount)
	if not session.active or not amount or amount <= 0 then return end
	local td = tracked[destGUID]
	if not td then return end

	-- total armor the active tracked debuffs are stripping from this target
	local removed = 0
	for _, a in pairs(td) do
		if contributes(a) then removed = removed + armorOf(a) end
	end
	if removed <= 0 then return end

	-- Marginal model: `amount` landed at the SOFTENED armor (base - removed). Compare to the same
	-- hit at full base armor to get the EXTRA damage the debuffs enabled. With m(A) = K/(A+K),
	-- extra = amount * (1 - m(base)/m(softened)) = amount * (1 - (softened+K)/(base+K)).
	local base = resolveBaseArmor(destGUID)
	local softened = base - removed
	if softened < 0 then softened = 0 end
	local K = D.ATTACKER_K
	local extra = amount * (1 - (softened + K) / (base + K))
	if extra <= 0 then return end

	for _, a in pairs(td) do
		if contributes(a) then
			local pts = extra * (armorOf(a) / removed)
			if a.owners then
				local sum = ownerWeight(a)
				for g, o in pairs(a.owners) do
					award(g, o.name, o.class, a.key, pts * (o.weight / sum))
				end
			else
				award(a.sourceGUID, a.sourceName, a.class, a.key, pts)
			end
		end
	end

	if M.UI then M.UI:MarkDirty() end
end

-- ---------------------------------------------------------- combat log tap --

local function handleCLEU()
	local _, sub, _, srcGUID, srcName, srcFlags, _, destGUID, destName = CombatLogGetCurrentEventInfo()

	-- physical direct damage -> scoring
	if sub == "SWING_DAMAGE" then
		local amount, _, school = select(12, CombatLogGetCurrentEventInfo())
		if school == SCHOOL_PHYSICAL then onDamage(destGUID, amount) end
		return
	elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" then
		-- suffix after spellId/spellName/spellSchool: amount, overkill, school, ...
		local amount, _, school = select(15, CombatLogGetCurrentEventInfo())
		if school == SCHOOL_PHYSICAL then onDamage(destGUID, amount) end
		return
	end
	-- SPELL_PERIODIC_DAMAGE intentionally ignored (bleeds bypass armor).

	-- Cast success = one attempt at an armor debuff. Tally it (per-caster, reliable);
	-- for sunder this also does the weight + effective credit.
	if sub == "SPELL_CAST_SUCCESS" then
		if not session.active or not destGUID then return end
		if bband(srcFlags or 0, FLAG_PLAYER) == 0 then return end
		local _, spellName = select(12, CombatLogGetCurrentEventInfo())
		local def = D.DEBUFFS[spellName]
		if def then
			countCast(destGUID, def, srcGUID, srcName)
		end
		return
	end

	-- A missed / dodged / parried sunder never landed -> undo its cast credit.
	if sub == "SPELL_MISSED" then
		if not session.active or not destGUID then return end
		if bband(srcFlags or 0, FLAG_PLAYER) == 0 then return end
		local _, spellName = select(12, CombatLogGetCurrentEventInfo())
		local def = D.DEBUFFS[spellName]
		if def and def.kind == "sunder" then
			sunderMiss(destGUID, def, srcGUID)
		end
		return
	end

	-- aura tracking (presence / stacks / fall-off — NOT sunder attribution)
	if sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_APPLIED_DOSE"
		or sub == "SPELL_AURA_REFRESH" or sub == "SPELL_AURA_REMOVED"
		or sub == "SPELL_AURA_REMOVED_DOSE" then

		local _, spellName, _, auraType, amount = select(12, CombatLogGetCurrentEventInfo())
		local def = D.DEBUFFS[spellName]
		if not def then return end
		if auraType and auraType ~= "DEBUFF" then return end

		if sub == "SPELL_AURA_REMOVED" then
			if session.active then removeAura(destGUID, destName, def) end
		elseif sub == "SPELL_AURA_REMOVED_DOSE" then
			if session.active and def.kind == "sunder" then
				doseDown(destGUID, def, amount or 0)
			end
		else  -- APPLIED, APPLIED_DOSE, or REFRESH
			if not session.active then return end
			if def.kind == "sunder" then
				-- mark present + note stacks; who gets credit comes from cast success.
				-- APPLIED -> 1 stack; DOSE -> new count; REFRESH -> keep current.
				local stacks = (sub == "SPELL_AURA_APPLIED") and 1 or amount
				sunderPresence(destGUID, destName, def, stacks)
			elseif sub ~= "SPELL_AURA_REFRESH" then
				-- single debuffs: attribute on APPLIED; ignore their refreshes
				if bband(srcFlags or 0, FLAG_PLAYER) == 0 then return end
				applySingle(destGUID, destName, def, srcGUID, srcName)
			end
		end
	end
end

-- --------------------------------------------------------------- sessions --

function Core:Reset()
	wipe(session.points)
	wipe(tracked)
	wipe(baseArmorCache)
	if M.db and M.db.session then M.db.session.label = session.label end
	if M.UI then M.UI:Refresh() end
end

local function persist()
	if not M.db then return end
	M.db.session.instanceID = session.instanceID
	M.db.session.label = session.label
end

StaticPopupDialogs["SUNDERBOARD_RESET"] = {
	text = "Sunderboard: joined a new raid group. Reset the leaderboard?",
	button1 = YES,
	button2 = NO,
	OnAccept = function() Core:Reset(); persist() end,
	-- No = keep the board (do nothing).
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function updateSession(quiet)
	local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
	local inInstance = (instanceType ~= "none")

	-- Scope (M.db.settings.scope) decides where the board scores AND shows:
	--   "group" (default) = whenever you're in a party/raid (or any instance)
	--   "instance"        = only inside a dungeon/raid instance
	--   "always"          = everywhere, even solo in the open world
	local scope = (M.db.settings and M.db.settings.scope) or "group"
	local on
	if scope == "always" then
		on = true
	elseif scope == "instance" then
		on = (instanceType == "party" or instanceType == "raid")
	else -- "group"
		on = IsInGroup() or inInstance
	end
	session.active = on   -- SCORING gate
	session.visible = on  -- WINDOW gate (when locked; unlocked always shows for positioning)

	-- Ask to reset when you JOIN a raid group (a fresh raid night). The transition guard fires
	-- once on the not-raid -> raid edge; roster churn and login/reload (quiet) don't prompt.
	local nowRaid = IsInRaid()
	if nowRaid and not session.inRaidGroup and not quiet and next(session.points) ~= nil then
		StaticPopup_Show("SUNDERBOARD_RESET")
	end
	session.inRaidGroup = nowRaid

	-- Track the current raid instance name for the header label (display only).
	if instanceType == "raid" then
		session.instanceID = instanceID
		session.label = name
		persist()
	end

	if M.UI then M.UI:UpdateVisibility() end
end
M.UpdateSession = updateSession

-- --------------------------------------------------------------- database --

-- Ensure M.db's shape + defaults, and wire the live session to the persisted
-- points table so the board survives enable/disable and /reload. M.db is the
-- module's slice of the ACCOUNT-wide SV (assigned by core before Enable runs).
-- Idempotent: safe to call on every Enable.
local function initDB()
	local db = M.db
	db.settings = db.settings or {}
	if db.settings.notifyFalloff == nil then db.settings.notifyFalloff = "mine" end  -- mine|all|off
	if db.settings.falloffMinUptime == nil then db.settings.falloffMinUptime = 3 end
	if db.settings.scope == nil then db.settings.scope = "group" end  -- group|instance|always
	db.session = db.session or { points = {}, instanceID = nil, label = nil }
	db.session.points = db.session.points or {}

	-- share the persisted points table so the board survives /reload
	session.points = db.session.points
	session.instanceID = db.session.instanceID
	session.label = db.session.label
end
-- Exposed so the settings page can seed the DB even while the module is disabled (BuildSettings
-- runs at login before Enable). Idempotent.
M.InitDB = initDB

-- --------------------------------------------------------------- lifecycle --
-- Sunderboard's non-combat-log events live on a module-owned frame so Disable can
-- drop them wholesale; the ONE COMBAT_LOG_EVENT_UNFILTERED registration lives in
-- core and reaches us only while subscribed (i.e. enabled).
local liveEvents

local function onLiveEvent(_, event, ...)
	if event == "PLAYER_ENTERING_WORLD" then
		local isInitialLogin, isReload = ...
		updateSession(isInitialLogin or isReload)  -- don't prompt on login/reload
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		updateSession(false)
	elseif event == "GROUP_ROSTER_UPDATE" then
		updateSession(false)  -- join/leave raid -> visibility + the "joined a raid" reset prompt
	end
end

-- Enable: init the DB, build the board, start scoring. M.db was assigned by core
-- before this runs. Called when the module leaves "hidden".
function M.Enable()
	initDB()
	if M.UI then M.UI:Build() end
	if not liveEvents then
		liveEvents = CreateFrame("Frame")
		liveEvents:SetScript("OnEvent", onLiveEvent)
	end
	liveEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
	liveEvents:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	liveEvents:RegisterEvent("GROUP_ROSTER_UPDATE")
	core.SubscribeCLEU("sb", handleCLEU)
	updateSession(true)  -- initial visibility + score gate, no prompt
end

-- Disable: stop scoring + hide the board (core already dropped our CLEU sub). The
-- leaderboard DATA stays in M.db; only the live per-target tracking is dropped.
function M.Disable()
	if liveEvents then liveEvents:UnregisterAllEvents() end
	if M.UI then M.UI:Hide() end
	wipe(tracked)
	wipe(baseArmorCache)
end

-- Tri-state display: "hidden" is handled by core via Disable; here we only apply
-- the (synthesized) lock while shown. Locked = the board can't be dragged.
function M.SetDisplayState(_, state)
	M.db.locked = (state == "locked")
	if M.UI then
		M.UI:ApplyLock()
		M.UI:UpdateVisibility()
	end
end

-- ----------------------------------------------------------------- slash ---
-- Forwarded by the shared router (/sb, /sunderboard, /aq sb ...).
function M.OnSlash(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "reset" then
		Core:Reset()
		print("|cffff8000Sunderboard|r: leaderboard reset.")
	elseif msg == "mine" or msg == "all" or msg == "off" then
		M.db.settings.notifyFalloff = msg
		print("|cffff8000Sunderboard|r: fall-off alerts = " .. msg)
	elseif msg == "options" or msg == "opt" or msg == "config" then
		core.OpenSettings()
	elseif msg == "show" then
		if core.GetModuleState("sb") == "hidden" then core.SetModuleState("sb", "unlocked") end
	elseif msg == "hide" then
		core.SetModuleState("sb", "hidden")
	elseif msg == "" or msg == "toggle" then
		local s = core.GetModuleState("sb")
		core.SetModuleState("sb", (s == "hidden") and "unlocked" or "hidden")
	else
		print("|cffff8000Sunderboard|r commands:")
		print("  /sb            toggle the board on/off")
		print("  /sb show|hide  show / hide the board")
		print("  /sb reset      clear the leaderboard")
		print("  /sb mine|all|off   fall-off alerts (default: mine)")
		print("  /sb options    open settings")
	end
end
