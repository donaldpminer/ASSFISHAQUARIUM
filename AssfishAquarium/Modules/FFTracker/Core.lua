--[[--------------------------------------------------------------------------
	FF Tracker - Core (tracking engine)

	Tracks any aura in Data.lua, keyed by (spellKey, destGUID). Sources of truth:

	  * Combat log - applications/refreshes/removals for anyone in range. Matched
	    by aura NAME (rank-agnostic) with spellId as a fallback. Every caster is
	    tracked, but there's only one row per (spell, target): simultaneous casters
	    merge, and the "mine"/ME flag and timer reflect the last-seen instance.
	  * UnitAura scans on mouseover/target/UNIT_AURA - resync our own exact timer,
	    read stack counts, note another caster's aura, and mark auras that fell off.

	When an aura runs out we DON'T delete its row - we mark it "expired" and keep
	it while the mob is around, dropping it on death or after a grace period.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local M = ns.modules.ff

local SPELL_BY_ID = M.SPELL_BY_ID
local SPELL_BY_KEY = M.SPELL_BY_KEY
local SPELL_BY_NAME = M.SPELL_BY_NAME

-- Name coloring (used by both display views): your class / another player's class
-- / bright red for an enemy mob / bright green for a friendly mob.
M.playerClass = nil
local RAID_COLORS = RAID_CLASS_COLORS
local F_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
local F_FRIENDLY = COMBATLOG_OBJECT_REACTION_FRIENDLY or 0x00000010
local function classRGB(class)
	local c = class and RAID_COLORS and RAID_COLORS[class]
	if c then return c.r, c.g, c.b end
	return 0.9, 0.9, 0.9
end
-- Color for a combat-log actor from its GUID + flags (nil if we can't tell).
local function clRGB(guid, flags)
	if not guid or guid == "" then return nil end
	if guid == M.playerGUID then return classRGB(M.playerClass) end
	if flags and bit.band(flags, F_PLAYER) ~= 0 then
		return classRGB(select(2, GetPlayerInfoByGUID(guid)))
	end
	-- NPC: green only for an explicit friendly reaction, red otherwise (hostile /
	-- neutral) - matching unitRGB so a neutral unit doesn't flip color by path.
	if flags and bit.band(flags, F_FRIENDLY) ~= 0 then return 0.25, 1, 0.25 end
	return 1, 0.25, 0.25
end
-- Color for a unit token (nil if it doesn't exist).
local function unitRGB(unit)
	if not unit or not UnitExists(unit) then return nil end
	if UnitIsUnit(unit, "player") then return classRGB(M.playerClass) end
	if UnitIsPlayer(unit) then return classRGB(select(2, UnitClass(unit))) end
	local r = UnitReaction("player", unit)
	if r and r >= 5 then return 0.25, 1, 0.25 end
	return 1, 0.25, 0.25
end
-- Store an {r,g,b} on the entry, flagging a redraw only when it changes.
local function setColor(e, field, r, g, b)
	if not r then return end
	local c = e[field]
	if not c then e[field] = { r, g, b }; M.dirty = true
	elseif c[1] ~= r or c[2] ~= g or c[3] ~= b then c[1], c[2], c[3] = r, g, b; M.dirty = true end
end

-- state[spellKey][destGUID] = { key, guid, name, srcName, srcColor, tgtColor,
--                               expiration, mine, unknown, expired, expiredAt,
--                               frozen, stacks, marker, srcMarker, stamp }
M.state = M.state or {}
local state = M.state

-- First-seen order per GUID (a monotonic counter) so "group by target" can order the
-- groups by when a mob's first debuff appeared. Cleared once the mob has no rows left.
M.guidSeen = M.guidSeen or {}
local guidSeen = M.guidSeen
local guidSeq = 0
local function markGuidSeen(guid)
	if guid and not guidSeen[guid] then
		guidSeq = guidSeq + 1
		guidSeen[guid] = guidSeq
	end
end
local liveGuids = {} -- scratch reused by ExpireState's prune

M.activeSpellKeys = {}
local active = M.activeSpellKeys
local activeFilters = { HARMFUL = false, HELPFUL = false }
-- True when any window has the "show all enemy debuffs" toggle on. Populated by
-- RecomputeActiveSpells; gates the synthetic "@" tracking + nameplate scanning.
M.anyShowAllDebuffs = false

M.dirty = false
M.playerGUID = nil

local UNKNOWN_TTL = 60
local EXPIRED_TTL = 2.5 -- auto-remove a row this long after its aura runs out

local function ensure(key)
	local t = state[key]
	if not t then
		t = {}
		state[key] = t
	end
	return t
end

-- Insert/update an entry. Only flags a redraw when something the UI shows changed.
local function track(key, guid, name, expiration, mine, unknown, stacks, srcName)
	if not guid then return end
	markGuidSeen(guid)
	local t = ensure(key)
	local e = t[guid]
	local changed = false
	if not e then
		e = {}
		t[guid] = e
		changed = true
	end
	-- Spells with no reliable duration (e.g. Chilled) get the timerless "??"
	-- treatment no matter what expiration the caller guessed.
	local sp = SPELL_BY_KEY[key]
	if sp and sp.approx then expiration = nil; unknown = true end
	if name and name ~= "" and e.name ~= name then e.name = name; changed = true end
	if srcName and srcName ~= "" and e.srcName ~= srcName then e.srcName = srcName; changed = true end
	if e.expiration ~= expiration then e.expiration = expiration; changed = true end
	local m = mine and true or false
	if e.mine ~= m then e.mine = m; changed = true end
	local u = unknown and true or false
	if e.unknown ~= u then e.unknown = u; changed = true end
	if stacks and e.stacks ~= stacks then e.stacks = stacks; changed = true end
	if e.expired then e.expired = false; e.expiredAt = nil; changed = true end
	e.key = key
	e.guid = guid
	e.stamp = GetTime()
	if changed then M.dirty = true end
end

-- The aura ran out / was removed, but keep the row (dimmed) until the mob dies
-- or the grace period lapses.
local function markExpired(key, guid)
	local t = state[key]
	local e = t and t[guid]
	if not e then return end
	local sp = SPELL_BY_KEY[key]
	if sp and sp.approx then t[guid] = nil; M.dirty = true; return end -- no timer to freeze
	if not e.expired then
		-- Freeze the counter where it was: a dispel / early fall-off shows the time
		-- it had left, a natural run-out is ~0, so the lingering row doesn't jump.
		e.frozen = e.expiration and math.max(0, e.expiration - GetTime()) or 0
		e.expired = true
		e.expiration = nil
		e.unknown = false
		e.expiredAt = GetTime()
		e.stamp = e.expiredAt
		M.dirty = true
	end
end

local function untrackGuid(guid)
	guidSeen[guid] = nil
	for _, t in pairs(state) do
		if t[guid] then
			t[guid] = nil
			M.dirty = true
		end
	end
end

-- "Show all enemy debuffs" tracks auras that AREN'T in Data.lua, so they get their
-- own synthetic "@<spellId>" keys: never colliding with a curated spell, and skipped
-- by the RecomputeActiveSpells wipe (which only prunes real keys). Each entry carries
-- its own icon/name/seenDur since there's no Data.lua spell behind it; e.dbKey links
-- back to a curated spell when one exists (used for its icon and stack cap).
local function allKey(spellId, name) return "@" .. tostring(spellId or name or "?") end

local function trackAll(spellId, name, icon, guid, tgtName, expiration, mine, unknown, stacks, srcName, dbKey)
	if not guid then return end
	markGuidSeen(guid)
	local key = allKey(spellId, name)
	local t = ensure(key)
	local e = t[guid]
	if not e then e = {}; t[guid] = e; M.dirty = true end
	if tgtName and tgtName ~= "" and e.name ~= tgtName then e.name = tgtName; M.dirty = true end
	if srcName and srcName ~= "" and e.srcName ~= srcName then e.srcName = srcName; M.dirty = true end
	if e.expiration ~= expiration then e.expiration = expiration; M.dirty = true end
	if expiration then
		-- Approximate the full duration by the largest remaining time we've witnessed,
		-- so the bar has a sane 0-1 scale (we never see the caster's chosen duration).
		local rem = expiration - GetTime()
		if not e.seenDur or rem > e.seenDur then e.seenDur = rem end
	end
	local m = mine and true or false
	if e.mine ~= m then e.mine = m; M.dirty = true end
	local u = unknown and true or false
	if e.unknown ~= u then e.unknown = u; M.dirty = true end
	if stacks and e.stacks ~= stacks then e.stacks = stacks; M.dirty = true end
	if e.expired then e.expired = false; e.expiredAt = nil; M.dirty = true end
	e.key = key
	e.guid = guid
	e.spellId = spellId
	e.icon = icon
	e.dbKey = dbKey
	e.stamp = GetTime()
end

-- Drop synthetic "@" entries: for one guid, or (guid == nil) all of them when the
-- last show-all window is turned off.
local function purgeAllKeys(guid)
	for key, t in pairs(state) do
		if key:byte(1) == 64 then -- "@"
			if guid then
				if t[guid] then t[guid] = nil; M.dirty = true end
			else
				state[key] = nil; M.dirty = true
			end
		end
	end
end
M.purgeAllKeys = purgeAllKeys

local function recent(e)
	return e ~= nil and e.stamp ~= nil and (GetTime() - e.stamp) < 1.5
end

local function isTracked(guid)
	if not guid then return false end
	for key in pairs(active) do
		local t = state[key]
		if t and t[guid] then return true end
	end
	return false
end

function M.RecomputeActiveSpells()
	wipe(active)
	activeFilters.HARMFUL = false
	activeFilters.HELPFUL = false
	M.anyShowAllDebuffs = false
	if M.db and M.db.windows then
		for _, w in ipairs(M.db.windows) do
			if w.allEnemyDebuffs then M.anyShowAllDebuffs = true end
			if w.spells then
				for key, cfg in pairs(w.spells) do
					local spell = SPELL_BY_KEY[key]
					if cfg.enabled and spell then
						active[key] = true
						activeFilters[spell.auraType] = true
					end
				end
			end
		end
	end
	-- Show-all needs harmful scans even if no curated debuff is enabled.
	if M.anyShowAllDebuffs then activeFilters.HARMFUL = true end
	-- Prune real keys no window tracks; leave the synthetic "@" bucket alone (it has
	-- its own lifecycle) unless show-all just turned off, in which case drop it all.
	for key in pairs(state) do
		if key:byte(1) ~= 64 and not active[key] then state[key] = nil end
	end
	if not M.anyShowAllDebuffs then purgeAllKeys(nil) end
	M.dirty = true
end

local function onCombatLog()
	local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags, _, spellId, spellName, _, _, amount =
		CombatLogGetCurrentEventInfo()

	if sub == "UNIT_DIED" or sub == "UNIT_DESTROYED" or sub == "PARTY_KILL" then
		untrackGuid(dstGUID)
		return
	end

	-- A mob that deaggroed / leashed home reports "EVADE" on hits against it.
	-- Drop it immediately rather than letting its rows linger the grace period.
	if sub == "SWING_MISSED" then
		if select(12, CombatLogGetCurrentEventInfo()) == "EVADE" then untrackGuid(dstGUID) end
		return
	elseif sub == "SPELL_MISSED" or sub == "RANGE_MISSED" or sub == "SPELL_PERIODIC_MISSED" then
		if select(15, CombatLogGetCurrentEventInfo()) == "EVADE" then untrackGuid(dstGUID) end
		return
	end

	local spell = SPELL_BY_NAME[spellName] or SPELL_BY_ID[spellId]
	if not spell or not active[spell.key] then return end

	if sub == "SPELL_AURA_APPLIED" then
		track(spell.key, dstGUID, dstName, GetTime() + spell.duration,
			srcGUID == M.playerGUID, false, amount or 1, srcName)
	elseif sub == "SPELL_AURA_REFRESH" or sub == "SPELL_AURA_APPLIED_DOSE" then
		-- REFRESH can omit the stack count; pass raw amount (nil-safe) so track()
		-- keeps the known count rather than resetting a stacked aura to 1.
		track(spell.key, dstGUID, dstName, GetTime() + spell.duration,
			srcGUID == M.playerGUID, false, amount, srcName)
	elseif sub == "SPELL_AURA_REMOVED_DOSE" then
		local e = state[spell.key] and state[spell.key][dstGUID]
		if e and amount then e.stacks = amount; M.dirty = true end
		return
	elseif sub == "SPELL_AURA_REMOVED"
		or sub == "SPELL_AURA_BROKEN"
		or sub == "SPELL_AURA_BROKEN_SPELL" then
		markExpired(spell.key, dstGUID)
		return
	else
		return
	end
	-- Applied / refreshed: color the source + target names by class / reaction.
	local ent = state[spell.key][dstGUID]
	if ent then
		setColor(ent, "srcColor", clRGB(srcGUID, srcFlags))
		setColor(ent, "tgtColor", clRGB(dstGUID, dstFlags))
	end
end

-- Reconcile our tracking with what a unit actually has right now.
local FILTERS = { "HARMFUL", "HELPFUL" }
local seenExp, seenSrc, seenStacks = {}, {}, {}

-- Show-all mode: record EVERY harmful aura on an enemy unit under a synthetic key,
-- regardless of the curated list, then expire any we'd stored for this unit that are
-- no longer present. Only called for enemies (UnitCanAttack) so friendly debuffs and
-- our own buffs are left to the curated engine.
local seenAll = {}
local function scanUnitAllDebuffs(unit, guid, uname)
	wipe(seenAll)
	local tr, tg, tb = unitRGB(unit)
	local marker = GetRaidTargetIndex(unit)
	for i = 1, 40 do
		local name, icon, count, _, _, expTime, source, _, _, spellId = core.GetAura(unit, i, "HARMFUL")
		if not name then break end
		local key = allKey(spellId, name)
		seenAll[key] = true
		local mine = (source and UnitIsUnit(source, "player")) and true or false
		local srcName = source and UnitName(source)
		local dbSpell = SPELL_BY_NAME[name] or SPELL_BY_ID[spellId]
		local dbKey = dbSpell and dbSpell.key
		local st = (count and count > 0) and count or 1
		local e = state[key] and state[key][guid]
		if expTime and expTime > 0 then
			trackAll(spellId, name, icon, guid, uname, expTime, mine, false, st, srcName, dbKey)
		elseif not (e and not e.mine and e.expiration and not e.unknown) and not recent(e) then
			-- Present but no readable timer (another caster's enemy debuff): "?".
			trackAll(spellId, name, icon, guid, uname, nil, mine, true, st, srcName, dbKey)
		elseif e and st and e.stacks ~= st then
			e.stacks = st; M.dirty = true
		end
		e = state[key] and state[key][guid]
		if e then
			if e.marker ~= marker then e.marker = marker; M.dirty = true end
			setColor(e, "tgtColor", tr, tg, tb)
			if source then setColor(e, "srcColor", unitRGB(source)) end
			local sunit = source or (mine and "player")
			local sm = sunit and GetRaidTargetIndex(sunit) or nil
			if e.srcMarker ~= sm then e.srcMarker = sm; M.dirty = true end
		end
	end
	-- Anything we had on this guid that's no longer present -> expire it (grace period).
	for key, t in pairs(state) do
		if key:byte(1) == 64 then
			local e = t[guid]
			if e and not e.expired and not seenAll[key] and not recent(e) then
				markExpired(key, guid)
			end
		end
	end
end

local function scanUnit(unit)
	if not UnitExists(unit) then return end
	local guid = UnitGUID(unit)
	if not guid then return end

	wipe(seenExp)
	wipe(seenSrc)
	wipe(seenStacks)
	for _, filter in ipairs(FILTERS) do
		if activeFilters[filter] then
			for i = 1, 40 do
				local name, _, count, _, _, expTime, source, _, _, spellId = core.GetAura(unit, i, filter)
				if not name then break end
				local spell = SPELL_BY_NAME[name] or SPELL_BY_ID[spellId]
				if spell and active[spell.key] then
					seenExp[spell.key] = expTime or 0 -- 0 => present but time unknown
					seenSrc[spell.key] = source
					seenStacks[spell.key] = (count and count > 0) and count or 1
				end
			end
		end
	end

	local uname = UnitName(unit)
	for key in pairs(active) do
		local exp = seenExp[key]
		local e = state[key] and state[key][guid]
		if exp ~= nil then
			-- Whether it's ours is decided by the CASTER, not by whether the timer
			-- is readable (friendly HoTs expose their duration for all casters).
			local src = seenSrc[key]
			local mine = (src and UnitIsUnit(src, "player")) and true or false
			local srcName = src and UnitName(src)
			if exp > 0 then
				track(key, guid, uname, exp, mine, false, seenStacks[key], srcName)
			else
				-- Present but no readable timer (typically another caster's enemy
				-- debuff). Keep a witnessed timer, else mark unknown - but never
				-- clobber a just-set combat-log entry.
				if e and not e.mine and e.expiration and not e.unknown then
					if seenStacks[key] and e.stacks ~= seenStacks[key] then
						e.stacks = seenStacks[key]; M.dirty = true
					end
				elseif not recent(e) then
					track(key, guid, uname, nil, mine, true, seenStacks[key], srcName)
				end
			end
		elseif e and not e.expired and not recent(e) then
			-- Fell off while we watched it -> mark expired (auto-removes after EXPIRED_TTL).
			markExpired(key, guid)
		end
	end

	-- Per-GUID stash for this unit's rows: raid target marker + name colors (the
	-- target color is the same for every aura on the unit; the source color comes
	-- from whoever cast each aura). Only readable while the unit is accessible.
	local marker = GetRaidTargetIndex(unit)
	local tr, tg, tb = unitRGB(unit)
	for key in pairs(active) do
		local e = state[key] and state[key][guid]
		if e then
			if e.marker ~= marker then e.marker = marker; M.dirty = true end
			local src = seenSrc[key]
			-- The caster's own raid marker (from its unit token, or "player" if it's
			-- mine) so a marked source shows a marker on the source side too.
			local sunit = src or (e.mine and "player")
			local sm = sunit and GetRaidTargetIndex(sunit) or nil
			if e.srcMarker ~= sm then e.srcMarker = sm; M.dirty = true end
			setColor(e, "tgtColor", tr, tg, tb)
			if src then setColor(e, "srcColor", unitRGB(src)) end
		end
	end

	-- Show-all: every debuff on this unit, but only if it's an enemy and some window
	-- has the toggle on. Curated tracking above is unaffected.
	if M.anyShowAllDebuffs and UnitCanAttack("player", unit) then
		scanUnitAllDebuffs(unit, guid, uname)
	end
end

-- Scan every visible enemy nameplate (that's what "enemies I can see" resolves to).
function M.ScanNameplates()
	if not M.anyShowAllDebuffs or not C_NamePlate then return end
	for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
		local u = plate.namePlateUnitToken
		if u and UnitExists(u) then scanUnit(u) end
	end
end

function M.Rescan()
	scanUnit("target")
	scanUnit("mouseover")
	M.ScanNameplates()
end

function M.ExpireState(now)
	local changed = false
	-- A timerless "?" row only gets its stamp refreshed by a scan, and a unit whose
	-- auras aren't changing never fires UNIT_AURA - so don't age out an unknown row
	-- that's still on the unit we're actively looking at (it'd wrongly vanish for a
	-- statically-held target and not return until the next interaction).
	local tGuid = UnitGUID("target")
	local mGuid = UnitGUID("mouseover")
	wipe(liveGuids)
	for _, t in pairs(state) do
		for guid, e in pairs(t) do
			if e.expired then
				if now - (e.expiredAt or e.stamp or now) > EXPIRED_TTL then
					t[guid] = nil
					changed = true
				end
			elseif e.expiration then
				if now >= e.expiration then
					e.frozen = 0 -- ran out naturally: frozen counter reads 0
					e.expired = true
					e.expiration = nil
					e.unknown = false
					e.expiredAt = now
					e.stamp = now
					changed = true
				end
			elseif e.unknown and e.stamp and (now - e.stamp) > UNKNOWN_TTL then
				if guid ~= tGuid and guid ~= mGuid then
					t[guid] = nil
					changed = true
				end
			end
			if t[guid] then liveGuids[guid] = true end
		end
	end
	-- Forget the first-seen order for guids that no longer have any rows.
	for guid in pairs(guidSeen) do
		if not liveGuids[guid] then guidSeen[guid] = nil end
	end
	return changed
end

-- The 0.05s ticker handles state (expiry + re-sort/rebuild on change). The bar
-- animation itself runs per-frame (see the OnUpdate animator in Window.lua). Routed
-- through core.NewTicker so the shared core cancels it on Disable.
local function onTick()
	local now = GetTime()
	if M.ExpireState(now) then M.dirty = true end
	if M.dirty then
		M.dirty = false
		if M.RefreshAll then M.RefreshAll() end
	end
end

-- --- lifecycle (driven by the shared core) ---------------------------------
-- FF Tracker's own (non-combat-log) events live on a module-owned frame so Disable
-- can drop them wholesale; the ONE COMBAT_LOG_EVENT_UNFILTERED registration lives in
-- core and is fanned out to us only while we're subscribed (i.e. enabled).
local liveEvents

local function onLiveEvent(_, event, unit)
	if event == "UPDATE_MOUSEOVER_UNIT" then
		scanUnit("mouseover")
	elseif event == "PLAYER_TARGET_CHANGED" then
		scanUnit("target")
	elseif event == "RAID_TARGET_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
		scanUnit("player") -- so marking yourself refreshes your own source markers
		scanUnit("target")
		scanUnit("mouseover")
		M.ScanNameplates()
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		-- A new enemy came into view: snapshot its debuffs for show-all windows.
		if M.anyShowAllDebuffs and unit then scanUnit(unit) end
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		-- It left view: drop its synthetic rows (curated tracking keeps its own).
		if M.anyShowAllDebuffs and unit then
			local g = UnitGUID(unit)
			if g then M.purgeAllKeys(g) end
		end
	elseif event == "UNIT_AURA" then
		if unit == "player" or unit == "target" or unit == "mouseover" then
			scanUnit(unit)
		elseif M.anyShowAllDebuffs and unit and unit:find("^nameplate%d") then
			-- Enemy nameplate's auras changed -> re-scan it for show-all windows.
			scanUnit(unit)
		elseif unit and activeFilters.HELPFUL and (unit:find("^party%d") or unit:find("^raid%d")) then
			-- Catch friendly HoTs (e.g. another druid's Rejuv) on group members
			-- even when the combat log misses the cast (out of range / in cities).
			scanUnit(unit)
		elseif unit and isTracked(UnitGUID(unit)) then
			scanUnit(unit)
		end
	end
end

-- Enable: build the windows + start tracking. M.db (per-character) was assigned by
-- core before this runs.
function M.Enable()
	M.playerGUID = UnitGUID("player")
	M.playerClass = select(2, UnitClass("player"))

	if type(M.db.windows) ~= "table" then M.db.windows = {} end
	-- First run seeds one window ONLY if the class has default spells; classes with
	-- none (Hunter/Shaman/Paladin) start with zero windows (make one from the FF Tracker
	-- settings page or `/fft new`). After first run, zero windows is a valid state.
	if not M.db.seeded and #M.db.windows == 0 and M.DefaultWindowConfig then
		local defaults = M.CLASS_DEFAULT_SPELLS and M.CLASS_DEFAULT_SPELLS[M.playerClass]
		if defaults and #defaults > 0 then
			table.insert(M.db.windows, M.DefaultWindowConfig())
		end
	end
	M.db.seeded = true

	M.RecomputeActiveSpells()
	if M.BuildWindows then M.BuildWindows() end
	if M.StartAnimator then M.StartAnimator() end -- the always-on per-frame bar animator

	if not liveEvents then
		liveEvents = CreateFrame("Frame")
		liveEvents:SetScript("OnEvent", onLiveEvent)
	end
	liveEvents:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
	liveEvents:RegisterEvent("PLAYER_TARGET_CHANGED")
	liveEvents:RegisterEvent("UNIT_AURA")
	liveEvents:RegisterEvent("RAID_TARGET_UPDATE")
	liveEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
	liveEvents:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	liveEvents:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	core.SubscribeCLEU("ff", onCombatLog)

	M.Rescan() -- snapshot auras already on our target/mouseover (e.g. after enabling)
	core.NewTicker("ff", 0.05, onTick) -- tracked: core cancels it on Disable
end

-- Disable: tear everything down (core has already cancelled our ticker + CLEU sub).
-- Stop the per-frame animator, drop our events, destroy the windows, and wipe all
-- transient tracking so nothing keeps firing or lingers on re-enable.
function M.Disable()
	if M.StopAnimator then M.StopAnimator() end
	if liveEvents then liveEvents:UnregisterAllEvents() end
	if M.DestroyWindows then M.DestroyWindows() end
	wipe(state)
	wipe(active)
	wipe(guidSeen)
	M.anyShowAllDebuffs = false
	M.dirty = false
end

-- Tri-state display: "hidden" is handled by core via Disable; here we only apply the
-- lock (lock-all) while shown. Locked = icons only (no header/background).
function M.SetDisplayState(_, state_)
	if state_ == "locked" then
		if M.LockAll then M.LockAll() end
	else
		if M.UnlockAll then M.UnlockAll() end
	end
end

-- Slash forwarded by the router (/fft, /fftracker, /aq ff ...).
function M.OnSlash(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "new" then
		if core.GetModuleState("ff") == "hidden" then core.SetModuleState("ff", "unlocked") end
		M.AddWindow()
	elseif msg == "options" or msg == "opt" or msg == "config" then
		core.OpenSettings()
	else -- bare /fft toggles the lock, routed through core so the state store stays in sync
		local s = core.GetModuleState("ff")
		core.SetModuleState("ff", s == "locked" and "unlocked" or "locked")
	end
end
