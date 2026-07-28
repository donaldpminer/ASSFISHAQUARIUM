-- Sunderboard :: Data.lua
-- Static definitions: which debuffs we track, their armor-reduction weights,
-- and the labels used in chat / the leaderboard.
--
-- The armor numbers below are WoW Classic Era (1.12 mechanics) values at MAX RANK -- the
-- actual armor each debuff strips. They are used both to split credit between debuffs active on
-- the same target AND, in the marginal-damage model (see BASE_ARMOR / BaseArmorForLevel below),
-- as real armor points subtracted from the target's estimated base armor.
--
-- Sunderboard is a MODULE of Assfish Aquarium. This is the module's FIRST-loaded
-- file, so it registers the module with the shared core (account-wide SV). Every
-- other Sunderboard file grabs `local M = ns.modules.sb` instead.

local ns = AssfishAquarium
local core = ns.core
local M = core.RegisterModule({
	key = "sb", title = "Sunderboard", perChar = false, default = true,
	category = "Raid", source = "mine", hasFrame = true,
	desc = "Leaderboard for armor-reduction debuffs (Sunder / Expose / Faerie Fire / CoR).",
})

M.Data = {}
local D = M.Data

-- Armor reduced by each debuff (max rank assumed for everything).
D.ARMOR = {
	SUNDER_PER_STACK = 450,   -- Sunder Armor, per stack (5 stacks = 2250)
	EXPOSE           = 3825,  -- Expose Armor at 5 combo points + Improved Expose Armor (2/2)
	FAERIE_FIRE      = 505,   -- Faerie Fire / Faerie Fire (Feral)
	RECKLESSNESS     = 640,   -- Curse of Recklessness
}

D.SUNDER_MAX_STACKS = 5

-- Base debuff durations (seconds, max rank). Used by the "refresh with little time left still
-- counts" rule: refreshing a debuff while it has <= D.REFRESH_WINDOW seconds remaining is
-- credited as an effective (needed maintenance) cast; refreshing early -- with more time left --
-- is not. Sunder/Expose 30s, Faerie Fire 40s, Curse of Recklessness 2 min.
D.DURATION = {
	sunder = 30,
	expose = 30,
	faerie = 40,
	reck   = 120,
}
D.REFRESH_WINDOW = 16

-- Debuffs we track, keyed by the spellName the combat log reports. Matching by
-- NAME (not spellId) collapses every rank into one entry, which is exactly what
-- we want. Caveat: spellName is client-locale text -- this table is enUS; add
-- other locales' strings here if needed.
--
--   key            internal id used for per-debuff subtotals
--   kind           "sunder" = stacking, multi-warrior owned; "single" = one caster
--   exclusiveGroup debuffs in the same group cannot coexist on a target
--                  (Sunder Armor and Expose Armor overwrite each other)
D.DEBUFFS = {
	["Sunder Armor"]          = { key = "sunder", kind = "sunder", exclusiveGroup = "armor_flat" },
	["Expose Armor"]          = { key = "expose", kind = "single", exclusiveGroup = "armor_flat" },
	["Faerie Fire"]           = { key = "faerie", kind = "single" },
	["Faerie Fire (Feral)"]   = { key = "faerie", kind = "single" },
	["Curse of Recklessness"] = { key = "reck",   kind = "single" },
}

-- Current armor reduction contributed by an active debuff (sunder scales with
-- its stack count; the rest are flat).
function D.ArmorValue(def, stacks)
	local k = def.key
	if k == "sunder" then
		return D.ARMOR.SUNDER_PER_STACK * (stacks or 1)
	elseif k == "expose" then
		return D.ARMOR.EXPOSE
	elseif k == "faerie" then
		return D.ARMOR.FAERIE_FIRE
	elseif k == "reck" then
		return D.ARMOR.RECKLESSNESS
	end
	return 0
end

-- Display labels, keyed by internal id.
D.LABEL = {
	sunder = "Sunder Armor",
	expose = "Expose Armor",
	faerie = "Faerie Fire",
	reck   = "Curse of Recklessness",
}

-- Order used for the per-debuff breakdown, so it's stable.
D.KEYS = { "sunder", "expose", "faerie", "reck" }

-- ---------------------------------------------------------------------------
-- Base-armor estimate for the marginal-damage model
-- ---------------------------------------------------------------------------
-- Classic creature armor is set by the mob's LEVEL + hidden unit-class. Raid mobs are the
-- "warrior" (melee) tier: 3731 at level 63 (confirmed), ~55 less per level below that (3566 at
-- level 60). A mob's combat class and its exact armor aren't readable at runtime, so we estimate
-- from level; caster-tier bosses and outliers are corrected by NPC id in ARMOR_OVERRIDE.
D.BASE_ARMOR_L63  = 3731  -- confirmed vanilla level-63 warrior-class armor (= most raid bosses)
D.ARMOR_PER_LEVEL = 55    -- warrior-tier armor drop per level below 63
D.ATTACKER_K      = 5500  -- 400 + 85*60: the armor mitigation constant for a level-60 attacker

-- NPC id -> exact base armor, overriding the level curve (the known caster-tier bosses at ~3009,
-- plus the Sulfuron Harbinger outlier). Everything else falls through to the melee curve.
D.ARMOR_OVERRIDE = {
	[12118] = 3009,  -- Lucifron (Molten Core, caster tier)
	[12259] = 3009,  -- Gehennas
	[12264] = 3009,  -- Shazzrah
	[15263] = 3009,  -- The Prophet Skeram (AQ40)
	[12098] = 4638,  -- Sulfuron Harbinger (heavier than the 3731 norm)
}

-- NPC id from a creature GUID: Creature-0-<srv>-<inst>-<zone>-<npcID>-<spawn>.
function D.NpcId(guid)
	if not guid then return nil end
	local kind, _, _, _, _, npcID = strsplit("-", guid)
	if kind == "Creature" or kind == "Vehicle" then return tonumber(npcID) end
	return nil
end

-- Estimated base armor (no debuffs) for a mob at `level`. nil / <=0 / ?? (level -1) or anything
-- above 63 is treated as a level-63 boss -- raid armor is nearly flat across 60-63 anyway.
function D.BaseArmorForLevel(level)
	if not level or level <= 0 or level > 63 then level = 63 end
	local a = D.BASE_ARMOR_L63 - (63 - level) * D.ARMOR_PER_LEVEL
	if a < 100 then a = 100 end
	return a
end
