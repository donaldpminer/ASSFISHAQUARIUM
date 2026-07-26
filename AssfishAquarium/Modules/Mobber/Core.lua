--[[--------------------------------------------------------------------------
	Mobber - Core (mob-centric enemy-debuff tracking)

	A mob-first tracker: one row per *nearby enemy* that has a debuff, each row a
	fixed grid of 16 slots. Two sources, like FFTracker:

	  * Combat log - SPELL_AURA_APPLIED/REFRESH/REMOVED for every enemy in range
	    (not just your target), so multiple mobs are tracked at once. Gives presence
	    + who cast it, but no duration.
	  * UnitAura scans - target / mouseover / enemy nameplates. These are authoritative
	    for a mob you can see: real durations for the swipe, plus HP / marker / level.

	Rows persist while a mob has a debuff or is visible; a dead mob keeps its row
	(skull, dimmed) for a few seconds (DEAD_TTL) or until you leave combat. No curated spell list -- every harmful
	aura shows. Timers need the mob to be scannable (targeted / moused / nameplated);
	turn enemy nameplates on for timers on everything you can see.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local M = core.RegisterModule({ key = "mob", title = "Mobber", perChar = true, default = true })

M.MAX_MOBS = 10   -- most mob rows shown at once
M.NUM_SLOTS = 16  -- debuff slots per mob (the Classic debuff cap)

M.mobs = {}                -- guid -> mob
local mobs = M.mobs
M.unitByGuid = {}          -- guid -> best-known live unit token (for HP / marker reads)
local unitByGuid = M.unitByGuid
M.dirty = false
local mobSeq = 0            -- monotonic "first seen" counter for row ordering
local playerGUID
local inRaid = false        -- in a raid instance: only elite+ (or marked) mobs are tracked
M.inRaid = false           -- mirror on ns for the window's "raids only" visibility gate
local scanOld = {}          -- scratch: previous scan's auras (preserve caster + detect fall-offs)

local F_FRIENDLY = COMBATLOG_OBJECT_REACTION_FRIENDLY or 0x00000010
local F_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400 -- excludes mind-controlled allies / enemy players
local AURA_TTL = 30         -- drop a debuffed off-screen mob with no activity for this long
local COMBAT_TTL = 6        -- drop a no-debuff mob this long after its last combat-log activity
local DEAD_TTL = 5          -- keep a dead mob's row (skull) this long, then drop it
local GHOST_TTL = 5         -- linger a fallen-off debuff (fading "0") this long, then clear

-- Blacklist: elite raid "swarm" adds we never track (non-elite swarms are already
-- excluded by the raid non-elite rule, so only elites need listing). Keyed by NPC id
-- (from the GUID) so name changes / localization don't matter. `db.blAdd` / `db.blRemove`
-- hold the player's overrides, so shipped defaults still reach them.
local DEFAULT_BLACKLIST = {
	[15718] = "Ouro Scarab",                    -- AQ40 (Ouro)
	[13996] = "Blackwing Technician",           -- BWL
	[11669] = "Flame Imp",                      -- Molten Core
	[15977] = "Infectious/Poisonous Skitterer", -- Naxxramas
	[12143] = "Son of Flame",                   -- Molten Core (Ragnaros)
	[16360] = "Zombie Chow",                    -- Naxxramas (Gluth)
	[14261] = "Blue Drakonid",                  -- BWL (Nefarian P1)
	[14262] = "Green Drakonid",                 -- BWL (Nefarian P1)
	[14263] = "Bronze Drakonid",                -- BWL (Nefarian P1)
	[14264] = "Red Drakonid",                   -- BWL (Nefarian P1)
	[14265] = "Black Drakonid",                 -- BWL (Nefarian P1)
}
M.DEFAULT_BLACKLIST = DEFAULT_BLACKLIST

-- NPC id from a creature GUID: Creature-0-<srv>-<inst>-<zone>-<npcID>-<spawn>.
local function npcIdFromGuid(guid)
	if not guid then return nil end
	local kind, _, _, _, _, npcID = strsplit("-", guid)
	if kind == "Creature" or kind == "Vehicle" then return tonumber(npcID) end
	return nil
end
M.npcIdFromGuid = npcIdFromGuid

-- Effective blacklist = defaults, minus user removals, plus user additions.
local function isBlacklistedId(id)
	if not id then return false end
	local db = M.db
	if db then
		if db.blAdd and db.blAdd[id] then return true end
		if db.blRemove and db.blRemove[id] then return false end
	end
	return DEFAULT_BLACKLIST[id] ~= nil
end
M.IsBlacklistedId = isBlacklistedId

local function isBlacklistedGuid(guid)
	return isBlacklistedId(npcIdFromGuid(guid))
end

-- Watch list == the user-facing "PRIORITIZED" debuffs. Two effects: (1) they sort to the
-- FRONT of a mob's slot row (non-prioritized fill from the back; empties end up in the
-- middle); (2) only these linger as a fading "0" ghost when they fall off. Everything is
-- still tracked live. Matched by name, case-insensitive PREFIX (so "Faerie Fire (Feral)"
-- matches "Faerie Fire"). db.watchAdd / db.watchRemove hold the player's overrides (lower key).
local DEFAULT_WATCH = {
	["sunder armor"]          = "Sunder Armor",
	["expose armor"]          = "Expose Armor",
	["faerie fire"]           = "Faerie Fire",
	["curse of recklessness"] = "Curse of Recklessness",
	["demoralizing shout"]    = "Demoralizing Shout",
	["thunder clap"]          = "Thunder Clap",
	["thunderfury"]           = "Thunderfury",        -- both proc debuffs share this name
	["fire vulnerability"]    = "Fire Vulnerability",  -- Scorch stacks (Improved Scorch)
	-- Taunts DO apply a short taunt DEBUFF aura on the target in Classic Era (verified on
	-- Wowhead Classic): Taunt / Growl 3s, Mocking Blow / Challenging Shout / Challenging
	-- Roar 6s -- so Mobber tracks them like any debuff (good for spotting a taunt about to
	-- drop). (Mocking Blow's aura may read as "Taunted"; if it doesn't show, add that name.)
	["taunt"]                 = "Taunt",
	["mocking blow"]          = "Mocking Blow",
	["growl"]                 = "Growl",
	["challenging shout"]     = "Challenging Shout",
	["challenging roar"]      = "Challenging Roar",   -- druid AoE taunt
}
M.DEFAULT_WATCH = DEFAULT_WATCH

local function watchMatch(n, key) return n == key or n:find(key, 1, true) == 1 end

local function isWatched(name)
	if not name then return false end
	local n = name:lower()
	local db = M.db
	for key in pairs(DEFAULT_WATCH) do
		if not (db and db.watchRemove and db.watchRemove[key]) and watchMatch(n, key) then return true end
	end
	if db and db.watchAdd then
		for key in pairs(db.watchAdd) do
			if watchMatch(n, key) then return true end
		end
	end
	return false
end
M.IsWatched = isWatched

-- Effective watch list as a sorted { key, name } array (for the options UI).
function M.GetWatchList()
	local out, db = {}, M.db
	for key, name in pairs(DEFAULT_WATCH) do
		if not (db and db.watchRemove and db.watchRemove[key]) then out[#out + 1] = { key = key, name = name } end
	end
	if db and db.watchAdd then
		for key, name in pairs(db.watchAdd) do
			if not DEFAULT_WATCH[key] then out[#out + 1] = { key = key, name = name } end
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

function M.WatchAddName(name)
	name = name and name:gsub("^%s+", ""):gsub("%s+$", "") or ""
	if name == "" then return end
	local key = name:lower()
	M.db.watchAdd = M.db.watchAdd or {}
	M.db.watchAdd[key] = name
	if M.db.watchRemove then M.db.watchRemove[key] = nil end -- re-adding a removed default
	print("|cff66ccffMobber:|r prioritizing |cffffff00" .. name .. "|r")
	if M.RefreshWatchUI then M.RefreshWatchUI() end
	if M.Rebuild then M.dirty = true; M.Rebuild() end -- re-order the live rows now
end

function M.WatchRemoveKey(key)
	local db = M.db
	if db.watchAdd and db.watchAdd[key] then
		db.watchAdd[key] = nil            -- a user addition: delete it
	elseif DEFAULT_WATCH[key] then
		db.watchRemove = db.watchRemove or {}
		db.watchRemove[key] = true        -- a shipped default: mark it removed
	end
	if M.RefreshWatchUI then M.RefreshWatchUI() end
	if M.Rebuild then M.dirty = true; M.Rebuild() end -- re-order the live rows now
end

-- Data model (all mobs live in M.mobs, keyed by GUID):
-- mob   = { guid, name, level, marker, dead, deadAt, order, unit, stamp, hpfrac?, test?,
--           auras = {[spellId]=aura}, debuffs = {aura,...}, ghosts = {[spellId]=ghost} }
--   auras  = source of truth (keyed by spellId). debuffs = sorted render array (sortAuras).
--   order  = first-seen sequence (tiebreak for sorting). marker = raid icon 1..8 or nil.
--   stamp  = GetTime() of last activity (scan / combat-log) -> drives off-screen keep TTLs.
--   deadAt = GetTime() of death; the skull row lingers DEAD_TTL then drops.
--   test / hpfrac = test-mode only (fake mob + its fake health fraction).
-- aura  = { spellId, icon, name, expiration?, duration?, mine, srcName?, srcClass?, count }
--   expiration/duration are known only from a scan; combat-log-only auras show "?".
-- ghost = { spellId, icon, name, fellOff }  -- a fallen-off WATCH-LISTED debuff; fellOff =
--           GetTime() it dropped; lingers GHOST_TTL as a fading "0" in the window's lane.

local function spellIcon(id)
	if not id then return nil end
	if C_Spell and C_Spell.GetSpellTexture then
		local t = C_Spell.GetSpellTexture(id)
		if t then return t end
	end
	if GetSpellTexture then return (GetSpellTexture(id)) end
	return nil
end

-- The raid target marker (1=Star .. 8=Skull) rides along in the combat log's
-- raidFlags bitmask, so we can read it even for off-screen mobs with no unit token.
local function markerFromRaidFlags(rf)
	if not rf or rf == 0 then return nil end
	for i = 1, 8 do
		if bit.band(rf, bit.lshift(1, i - 1)) ~= 0 then return i end
	end
	return nil
end

local function ensureMob(guid)
	local m = mobs[guid]
	if not m then
		mobSeq = mobSeq + 1
		m = { guid = guid, order = mobSeq, auras = {}, debuffs = {} }
		mobs[guid] = m
		M.dirty = true
	end
	return m
end

local function removeMob(guid)
	if mobs[guid] then
		mobs[guid] = nil
		unitByGuid[guid] = nil
		M.dirty = true
	end
end
M.removeMob = removeMob

-- Drop every currently-tracked mob of a given npc id (used when it gets blacklisted).
local function dropByNpcId(id)
	for guid in pairs(mobs) do
		if npcIdFromGuid(guid) == id then
			mobs[guid] = nil
			unitByGuid[guid] = nil
			M.dirty = true
		end
	end
end

-- The effective blacklist as a sorted { id, name } list (for the options UI).
function M.GetBlacklist()
	local out, db = {}, M.db
	for id, name in pairs(DEFAULT_BLACKLIST) do
		if not (db and db.blRemove and db.blRemove[id]) then out[#out + 1] = { id = id, name = name } end
	end
	if db and db.blAdd then
		for id, name in pairs(db.blAdd) do
			if not DEFAULT_BLACKLIST[id] then out[#out + 1] = { id = id, name = name } end
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

function M.BlacklistAddTarget()
	if not UnitExists("target") or not UnitCanAttack("player", "target") then
		print("|cff66ccffMobber:|r target an enemy first, then add it to the ignore list.")
		return
	end
	local id = npcIdFromGuid(UnitGUID("target"))
	if not id then print("|cff66ccffMobber:|r couldn't read that target's creature id."); return end
	local name = UnitName("target") or ("npc " .. id)
	M.db.blAdd = M.db.blAdd or {}
	M.db.blAdd[id] = name
	if M.db.blRemove then M.db.blRemove[id] = nil end -- re-adding a previously-removed default
	dropByNpcId(id)
	print("|cff66ccffMobber:|r now ignoring |cffffff00" .. name .. "|r (" .. id .. ")")
	if M.RefreshBlacklistUI then M.RefreshBlacklistUI() end
end

function M.BlacklistRemoveId(id)
	local db = M.db
	if db.blAdd and db.blAdd[id] then
		db.blAdd[id] = nil               -- a user addition: just delete it
	elseif DEFAULT_BLACKLIST[id] then
		db.blRemove = db.blRemove or {}
		db.blRemove[id] = true           -- a shipped default: mark it removed
	end
	M.dirty = true
	if M.RefreshBlacklistUI then M.RefreshBlacklistUI() end
end

-- Soonest-to-expire first (index 1 -> RIGHTMOST slot); unknown-timer debuffs last.
local function debuffLess(a, b)
	local ae, be = a.expiration, b.expiration
	if (ae ~= nil) ~= (be ~= nil) then return ae ~= nil end
	if ae and be and ae ~= be then return ae < be end
	return (a.spellId or 0) < (b.spellId or 0)
end

-- Rebuild the sorted render array from the aura map.
local function sortAuras(m)
	local db = m.debuffs
	wipe(db)
	for _, a in pairs(m.auras) do db[#db + 1] = a end
	table.sort(db, debuffLess)
end

-- Ghost lane: a debuff that just fell off (and wasn't re-applied) lingers as a fading "0"
-- to the right of the live debuffs for GHOST_TTL seconds. Re-applying the same spell
-- clears its ghost (it was replaced, not gone). fellOff defaults to now (used as the age).
local function ghostAura(m, id, a, fellOff)
	if not a then return end
	if not isWatched(a.name) then return end -- only debuffs on the watch list linger
	m.ghosts = m.ghosts or {}
	local g = m.ghosts[id]
	if not g then g = {}; m.ghosts[id] = g end
	g.spellId = id
	g.icon = a.icon
	g.name = a.name
	-- Never in the future: an early-removed debuff (dispel / immunity) has an expiration
	-- still ahead of now, and a future fellOff would keep the ghost from ever aging out.
	local now = GetTime()
	g.fellOff = (fellOff and fellOff < now) and fellOff or now
	M.dirty = true
end

local function clearGhost(m, id)
	if m.ghosts and m.ghosts[id] then m.ghosts[id] = nil; M.dirty = true end
end

-- Raid target icons are unique in-game: only one unit can wear a given marker. When we
-- learn a mob has marker `idx`, strip that same icon off any other tracked mob so a stale
-- holder (e.g. one we marked off-screen via the combat log and never rescanned to clear)
-- doesn't keep showing it. Seeing a skull on one row means no other row can show a skull.
local function setMarker(m, idx)
	if m.marker == idx then return end -- already set; uniqueness holds, skip the O(n) scan
	if idx then
		for _, other in pairs(mobs) do
			if other ~= m and other.marker == idx then
				other.marker = nil
				M.dirty = true
			end
		end
	end
	if m.marker ~= idx then
		m.marker = idx
		M.dirty = true
	end
end

-- --- test mode: fill the display with fake mobs to preview / position it ---
local TEST_ICONS = {
	"Interface\\Icons\\Ability_Warrior_Sunder",
	"Interface\\Icons\\Spell_Nature_FaerieFire",
	"Interface\\Icons\\Ability_Rogue_ExposeArmor",
	"Interface\\Icons\\Spell_Shadow_CurseOfMannoroth",
	"Interface\\Icons\\Spell_Shadow_ShadowWordPain",
	"Interface\\Icons\\Spell_Fire_Immolation",
	"Interface\\Icons\\Spell_Frost_FrostBolt",
	"Interface\\Icons\\Ability_Poisons",
	"Interface\\Icons\\Spell_Nature_Drowsy",
	"Interface\\Icons\\Ability_Warrior_ThunderClap",
}
local TEST_NAMES = { "Training Dummy", "Fake Ogre", "Test Wraith", "Mock Drake",
	"Dummy Beast", "Phantom Add", "Straw Golem", "Practice Elemental" }
-- Names from the default prioritized list, so test mode shows the front/back split.
local TEST_PRI_NAMES = { "Sunder Armor", "Expose Armor", "Faerie Fire",
	"Curse of Recklessness", "Demoralizing Shout", "Thunder Clap" }

M.testMode = false

-- Toggle a preview: 8 fake mobs, each with a random number of random debuffs. While on,
-- real tracking is frozen (scan/combat-log/prune all bail) so only the fakes show.
function M.SetTestMode(on)
	M.testMode = on and true or false
	wipe(mobs)
	wipe(unitByGuid)
	if M.testMode then
		local now = GetTime()
		local myClass = select(2, UnitClass("player")) -- so the "by my class" glow previews too
		for i = 1, 8 do
			mobSeq = mobSeq + 1
			local m = {
				guid = "Test-" .. i, order = mobSeq, test = true,
				name = TEST_NAMES[i] or ("Test " .. i),
				level = (math.random(2) == 1) and -1 or math.random(50, 63),
				marker = (i <= 3) and (9 - i) or nil, -- Skull / Cross / Diamond on the first three
				hpfrac = math.random(12, 100) / 100,
				auras = {}, debuffs = {},
			}
			for j = 1, math.random(1, M.NUM_SLOTS) do
				local dur = math.random(20, 120)
				local sid = 990000 + i * 100 + j
				local pri = math.random(10) <= 4 -- ~40% prioritized so the split is visible
				local mine = math.random(2) == 1
				m.auras[sid] = {
					spellId = sid,
					icon = TEST_ICONS[math.random(#TEST_ICONS)],
					name = pri and TEST_PRI_NAMES[math.random(#TEST_PRI_NAMES)] or ("Test Debuff " .. j),
					expiration = now + math.random(15, dur), -- keep plenty of time on the preview
					duration = dur,
					mine = mine,
					srcClass = mine and myClass or (math.random(2) == 1 and myClass or "MAGE"),
					count = (math.random(3) == 1) and math.random(2, 5) or 1,
				}
			end
			sortAuras(m)
			mobs[m.guid] = m
		end
	end
	M.dirty = true
	if M.Rebuild then M.Rebuild() end
end

-- Authoritative refresh of a visible enemy from UnitAura (real durations + HP data).
local function scanMob(unit)
	if M.testMode then return end -- preview is showing fake mobs; ignore the real world
	-- Enemies only, and never players (a mind-controlled ally reads as attackable).
	if not UnitExists(unit) or not UnitCanAttack("player", unit) or UnitIsPlayer(unit) then return end
	local guid = UnitGUID(unit)
	if not guid then return end
	-- Blacklisted swarm add: never track it (and drop it if it somehow got a row).
	if isBlacklistedGuid(guid) then
		if mobs[guid] then removeMob(guid) end
		return
	end
	-- Never ADD an already-dead / downed mob (a corpse, or a Core Hound already collapsed
	-- to 0 HP); only mark an already-tracked one dead.
	if not mobs[guid] and (UnitIsDead(unit) or (UnitHealthMax(unit) > 0 and UnitHealth(unit) == 0)) then return end
	-- Already marked dead/downed (a collapsed Core Hound still has a nameplate): leave the
	-- skull row alone -- don't refill its wiped debuffs from a lingering UnitAura scan.
	if mobs[guid] and mobs[guid].dead then return end
	-- In a raid, don't track non-elite trash at all (unless it's raid-marked).
	if not mobs[guid] and inRaid and not GetRaidTargetIndex(unit) then
		local c = UnitClassification(unit)
		if c == "normal" or c == "minus" or c == "trivial" then return end
	end
	-- Track a mob if it has (or had) a debuff, OR it's an enemy in combat, OR it's raid-marked.
	if not mobs[guid] and not UnitAura(unit, 1, "HARMFUL") and not UnitAffectingCombat(unit) and not GetRaidTargetIndex(unit) then return end

	local m = ensureMob(guid)
	unitByGuid[guid] = unit
	m.unit = unit
	m.name = UnitName(unit) or m.name
	m.level = UnitLevel(unit)
	setMarker(m, GetRaidTargetIndex(unit))
	if UnitIsDead(unit) or (UnitHealthMax(unit) > 0 and UnitHealth(unit) == 0) then
		-- died, or collapsed to 0 HP (a Core Hound going down): skull it and clear its
		-- debuffs now, and don't repopulate from the scan.
		m.dead = true
		m.deadAt = m.deadAt or GetTime()
		wipe(m.auras)
		if m.ghosts then wipe(m.ghosts) end
		sortAuras(m)
		M.dirty = true
		return
	end

	-- Rebuild from the scan. On Classic Era, UnitAura on an ENEMY returns ALL debuffs
	-- (every caster's, up to the 16 cap) WITH real durations -- so a scannable mob's row is
	-- fully authoritative. Diff against the previous scan to detect fall-offs (for ghosts).
	wipe(scanOld)
	for id, a in pairs(m.auras) do scanOld[id] = a end -- keep the old aura tables for diffing
	wipe(m.auras)
	for i = 1, 40 do
		local name, icon, count, _, duration, expTime, source, _, _, spellId = UnitAura(unit, i, "HARMFUL")
		if not name then break end
		local old = scanOld[spellId]
		m.auras[spellId] = {
			spellId = spellId,
			icon = icon,
			name = name,
			expiration = (expTime and expTime > 0) and expTime or nil,
			duration = (duration and duration > 0) and duration or nil,
			mine = (source and UnitIsUnit(source, "player")) and true or false,
			srcName = (source and UnitName(source)) or (old and old.srcName),
			srcClass = (source and select(2, UnitClass(source))) or (old and old.srcClass),
			count = (count and count > 0) and count or 1,
		}
		clearGhost(m, spellId) -- present again -> it's live, not a ghost
	end
	-- Anything on last scan but gone now fell off -> ghost it (age from its old timer end).
	for id, a in pairs(scanOld) do
		if not m.auras[id] then ghostAura(m, id, a, a.expiration) end
	end
	m.stamp = GetTime()
	sortAuras(m)
	M.dirty = true
end
M.scanMob = scanMob

local function scanAllVisible()
	if C_NamePlate then
		for _, p in ipairs(C_NamePlate.GetNamePlates()) do
			local u = p.namePlateUnitToken
			if u then scanMob(u) end
		end
	end
	scanMob("target")
	scanMob("mouseover")
end
M.scanAllVisible = scanAllVisible

-- Combat log: track debuff presence on EVERY enemy in range (this is what gives
-- multi-target coverage without needing each mob targeted / nameplated).
local function onCombatLog()
	if M.testMode then return end -- preview active: ignore real combat
	local _, sub, _, srcGUID, srcName, _, _, dstGUID, dstName, dstFlags, dstRaidFlags, spellId, spellName, _, auraType, amount = CombatLogGetCurrentEventInfo()

	if sub == "UNIT_DIED" or sub == "UNIT_DESTROYED" or sub == "PARTY_KILL" then
		local m = mobs[dstGUID]
		if m then
			m.dead = true
			m.deadAt = m.deadAt or GetTime()
			wipe(m.auras)
			if m.ghosts then wipe(m.ghosts) end
			sortAuras(m)
			unitByGuid[dstGUID] = nil
			M.dirty = true
		end
		return
	end

	-- Any log event involving a tracked mob (as attacker or target) means it's still in
	-- combat -> refresh its activity stamp so its row survives while the fight goes on,
	-- even when it's not our target / has no nameplate. A dst event also refreshes the
	-- raid marker. Works off-screen (no unit token needed).
	local now = GetTime()
	local sm = srcGUID and mobs[srcGUID]
	if sm then sm.stamp = now end
	local dm = dstGUID and mobs[dstGUID]
	if dm then
		dm.stamp = now
		setMarker(dm, markerFromRaidFlags(dstRaidFlags))
	end

	-- Aura removal / break / stack-down: handle BEFORE the auraType guard. A
	-- SPELL_AURA_BROKEN_SPELL carries extra spell fields that push auraType to a later CLEU
	-- slot (18, not 15), so the guard below would wrongly skip it. These branches only touch
	-- auras we already track (all debuffs), so the DEBUFF/friendly/player filters are moot.
	if sub == "SPELL_AURA_REMOVED" or sub == "SPELL_AURA_BROKEN" or sub == "SPELL_AURA_BROKEN_SPELL" then
		local m = dstGUID and mobs[dstGUID]
		if m and m.auras[spellId] then
			ghostAura(m, spellId, m.auras[spellId]) -- fell off -> linger as a fading "0"
			m.auras[spellId] = nil
			sortAuras(m)
			M.dirty = true
		end
		return
	elseif sub == "SPELL_AURA_REMOVED_DOSE" then
		local m = dstGUID and mobs[dstGUID]
		local a = m and m.auras[spellId]
		if a then a.count = amount or a.count; sortAuras(m); M.dirty = true end -- stack-down
		return
	end

	-- Only harmful auras, on non-friendly units, never the player.
	if not dstGUID or auraType ~= "DEBUFF" then return end
	if dstGUID == playerGUID then return end
	if bit.band(dstFlags or 0, F_FRIENDLY) ~= 0 then return end
	if bit.band(dstFlags or 0, F_PLAYER) ~= 0 then return end -- no players (MC'd allies / enemy players)

	if sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" or sub == "SPELL_AURA_APPLIED_DOSE" then
		local m = mobs[dstGUID]
		if not m then
			if isBlacklistedGuid(dstGUID) then return end
			if inRaid then return end -- raids: only scans (which can classify) create rows
			m = ensureMob(dstGUID)
		elseif m.dead then
			return -- don't re-populate a dead mob (e.g. a channel's final tick after death)
		end
		m.name = dstName or m.name
		setMarker(m, markerFromRaidFlags(dstRaidFlags)) -- also set it for a freshly-created mob
		m.stamp = GetTime()
		local a = m.auras[spellId]
		if not a then a = { spellId = spellId }; m.auras[spellId] = a end
		clearGhost(m, spellId) -- (re)applied -> live, not a ghost
		a.name = spellName
		if not a.icon then a.icon = spellIcon(spellId) end
		a.mine = (srcGUID == playerGUID) and true or false
		a.srcName = srcName or a.srcName
		-- caster's class (english, e.g. "WARRIOR") for the "highlight by my class" option;
		-- GetPlayerInfoByGUID returns nil for non-player sources.
		a.srcClass = (srcGUID and select(2, GetPlayerInfoByGUID(srcGUID))) or a.srcClass
		a.count = amount or a.count or 1 -- APPLIED_DOSE carries the new stack count
		-- duration is unknown from the combat log; a scan fills it in when visible.
		sortAuras(m)
		M.dirty = true
	end
end

-- Drop live mobs we can no longer see AND that have no debuffs left (or went stale);
-- keep dead ones (they clear on leaving combat). Also refreshes guid->token for HP.
local visible = {}
local pruneTick = 0
local function pruneInvisible()
	if M.testMode then return end -- preview active: keep the fake mobs frozen in place
	pruneTick = pruneTick + 1
	local doCreate = (pruneTick % 5 == 0) -- only hunt for NEW in-combat/marked mobs ~every 0.5s
	wipe(visible)
	if C_NamePlate then
		for _, p in ipairs(C_NamePlate.GetNamePlates()) do
			local u = p.namePlateUnitToken
			if u then
				local g = UnitGUID(u)
				if g then
					visible[g] = true
					if mobs[g] then
						unitByGuid[g] = u
					elseif doCreate and UnitCanAttack("player", u) and (UnitAffectingCombat(u) or GetRaidTargetIndex(u)) then
						scanMob(u) -- a new enemy in combat or raid-marked: start its row
					end
				end
			end
		end
	end
	local tg = UnitGUID("target");    if tg then visible[tg] = true; if mobs[tg] then unitByGuid[tg] = "target" end end
	local mg = UnitGUID("mouseover"); if mg then visible[mg] = true; if mobs[mg] then unitByGuid[mg] = "mouseover" end end

	local now = GetTime()
	for guid, m in pairs(mobs) do
		if m.dead then
			-- keep the skull row briefly, then drop it
			if (now - (m.deadAt or now)) > DEAD_TTL then
				mobs[guid] = nil
				unitByGuid[guid] = nil
				M.dirty = true
			end
		else
			local tok = unitByGuid[guid]
			local scannable = tok and UnitExists(tok) and UnitGUID(tok) == guid
			if scannable and (UnitIsDead(tok) or (UnitHealthMax(tok) > 0 and UnitHealth(tok) == 0)) then
				-- Dead, or downed at 0 HP: a collapsed Core Hound reads as alive-but-0 and
				-- never fires UNIT_DIED, so it (and any missed death) would keep looking
				-- alive. Skull it and clear its debuffs so it ages out.
				m.dead = true
				m.deadAt = now
				wipe(m.auras)
				if m.ghosts then wipe(m.ghosts) end
				sortAuras(m)
				M.dirty = true
			else
				-- Off-screen we can't rescan, so a scanned debuff whose timer has clearly
				-- run out would otherwise sit frozen at "0s" forever (a Core Hound that
				-- vanished off the ground left a row full of them). Ghost expired auras (they
				-- fell off); scannable mobs are re-synced by their own scan anyway.
				local changed = false
				for id, a in pairs(m.auras) do
					if a.expiration and a.expiration > 0 and now > a.expiration + 1.5 then
						ghostAura(m, id, a, a.expiration)
						m.auras[id] = nil
						changed = true
					end
				end
				if changed then sortAuras(m); M.dirty = true end

				-- Age out ghosts that have lingered their full GHOST_TTL.
				if m.ghosts then
					for id, g in pairs(m.ghosts) do
						if now - (g.fellOff or now) > GHOST_TTL then m.ghosts[id] = nil; M.dirty = true end
					end
				end

				local vis = visible[guid]
				local fresh = now - (m.stamp or 0)
				local keep
				if m.marker then
					-- raid-marked: keep -- but bound it so a marked mob that despawns
					-- off-screen without dying (phase change / evade: no UNIT_DIED, not
					-- scannable, no more events) can't leak forever. Active combat keeps
					-- stamping it, so it survives real fights.
					keep = vis or fresh <= AURA_TTL
				elseif next(m.auras) ~= nil then
					-- debuffed: keep (a grace off-screen so combat-log-only rows linger)
					keep = vis or fresh <= AURA_TTL
				elseif m.ghosts and next(m.ghosts) ~= nil then
					keep = true -- hold the row while fallen-off debuffs are still lingering
				else
					-- no debuffs: keep while it's in combat -- by the visible combat flag, or
					-- by recent combat-log activity (so it stays when un-targeted mid-fight).
					local combatByUnit = (scannable and UnitAffectingCombat(tok)) and true or false
					keep = combatByUnit or fresh <= COMBAT_TTL
				end
				if not keep then
					mobs[guid] = nil
					unitByGuid[guid] = nil
					M.dirty = true
				end
			end
		end
	end
end

local function onTick()
	pruneInvisible()
	if M.dirty then
		M.dirty = false
		if M.Rebuild then M.Rebuild() end
	end
	if M.UpdateLive then M.UpdateLive() end
end

-- Saved variables (per character): M.db is our slice of AssfishAquariumCharDB. All fields
-- optional -- the code
-- falls back to the documented default when nil. Wiped by M.ResetDefaults().
--   locked      bool           window locked: no drag, no background. Default off.
--   point       {corner,x,y}   saved window position (pinned corner + screen coords).
--   slotSize    number         debuff icon size px (MIN_SLOT..MAX_SLOT in Window). Default 24.
--   growRight   bool           rows grow left (default) or right.
--   growUp      bool           mobs stack down (default) or up.
--   gridRows    1|2|"prio"     grid: 1x16 (default) / 2x8 / prioritized-only (no empties).
--   raidOnly    bool           only show the window in a raid. Default ON (nil/true);
--                              false = show everywhere. (Read as `db.raidOnly ~= false`.)
--   hlMine       bool          glow debuffs YOU applied. Default ON.
--   hlMineColor  {r,g,b}       color of the "by me" glow (default gold).
--   hlClass      bool          glow debuffs by your CLASS but not you. Default off.
--   hlClassColor {r,g,b}       color of the "by my class" glow (default blue).
--   minimap     {angle}        minimap button angle around the ring.
--   blAdd       {[npcId]=name} blacklist additions (creature ids we never track).
--   blRemove    {[npcId]=true} shipped-blacklist entries the player re-enabled.
--   watchAdd    {[lowerName]=display} extra debuffs that linger (ghost) when they fall off.
--   watchRemove {[lowerName]=true}    shipped watch-list entries the player removed.

-- Recompute the raid-instance flag: gates the non-elite trash filter AND the window's
-- "only show in raids" visibility. Marks dirty so a raid enter/exit re-evaluates showing.
local function refreshInRaid()
	inRaid = (select(2, IsInInstance()) == "raid")
	M.inRaid = inRaid
	M.dirty = true
end

-- --- lifecycle (driven by the shared core) ---------------------------------
-- Mobber's own (non-combat-log) events live on a module-owned frame so Disable can drop
-- them wholesale; the ONE COMBAT_LOG_EVENT_UNFILTERED registration lives in core and is
-- fanned out to us only while we're subscribed (i.e. enabled).
local liveEvents

local function onLiveEvent(_, event, unit)
	if event == "NAME_PLATE_UNIT_ADDED" then
		if unit then scanMob(unit) end
	elseif event == "UNIT_AURA" then
		if unit == "target" or unit == "mouseover" or (unit and unit:find("^nameplate%d")) then
			scanMob(unit)
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		scanMob("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		scanMob("mouseover")
	elseif event == "RAID_TARGET_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
		refreshInRaid()
		scanAllVisible()
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- Left combat: clear out the dead mobs.
		for guid, m in pairs(mobs) do
			if m.dead then mobs[guid] = nil; unitByGuid[guid] = nil; M.dirty = true end
		end
	end
end

-- Enable: build the window + start tracking. M.db was assigned by core before this runs.
function M.Enable()
	playerGUID = UnitGUID("player")
	refreshInRaid()
	if M.testMode then M.SetTestMode(false) end -- don't inherit a preview toggled on while disabled
	if M.BuildWindow then M.BuildWindow() end
	if not liveEvents then
		liveEvents = CreateFrame("Frame")
		liveEvents:SetScript("OnEvent", onLiveEvent)
	end
	liveEvents:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	liveEvents:RegisterEvent("UNIT_AURA")
	liveEvents:RegisterEvent("PLAYER_TARGET_CHANGED")
	liveEvents:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
	liveEvents:RegisterEvent("RAID_TARGET_UPDATE")
	liveEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
	liveEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
	core.SubscribeCLEU("mob", onCombatLog)
	scanAllVisible()
	core.NewTicker("mob", 0.1, onTick) -- tracked: core cancels it on disable
end

-- Disable: tear everything down (core has already cancelled our ticker + CLEU sub).
function M.Disable()
	if M.testMode then M.SetTestMode(false) end
	if liveEvents then liveEvents:UnregisterAllEvents() end
	wipe(mobs)
	wipe(unitByGuid)
	M.dirty = false
	if M.win then M.win:Hide() end
end

-- Tri-state display: "hidden" is handled by core via Disable; here we only apply lock while
-- shown. Lock state is stored per-character in M.db.locked (read by the window's ApplyLock).
function M.SetDisplayState(_, state)
	M.db.locked = (state == "locked")
	if M.ApplyLock then M.ApplyLock() end
	if M.Rebuild then M.Rebuild() end
end

-- Slash forwarded by the router (/mob, /mobber, /aq mob ...).
function M.OnSlash(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "ignore" then
		M.BlacklistAddTarget()
	elseif msg == "watch" then
		if M.ToggleWatchPanel then M.ToggleWatchPanel() end
	elseif msg == "options" or msg == "opt" or msg == "config" then
		core.OpenSettings()
	else -- bare /mob toggles lock; from disabled it reveals into unlocked (a usable state)
		local s = core.GetModuleState("mob")
		core.SetModuleState("mob", s == "unlocked" and "locked" or "unlocked")
	end
end
