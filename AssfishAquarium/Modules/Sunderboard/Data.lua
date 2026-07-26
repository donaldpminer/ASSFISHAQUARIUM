-- Sunderboard :: Data.lua
-- Static definitions: which debuffs we track, their armor-reduction weights,
-- and the labels used in chat / the leaderboard.
--
-- The armor numbers below are WoW Classic Era (1.12 mechanics) values at MAX
-- RANK. They are used only as *relative weights* when splitting credit between
-- several debuffs that are active on the same target at once -- so their exact
-- values matter far less than their ratios. Tune freely.
--
-- Sunderboard is a MODULE of Assfish Aquarium. This is the module's FIRST-loaded
-- file, so it registers the module with the shared core (account-wide SV). Every
-- other Sunderboard file grabs `local M = ns.modules.sb` instead.

local ADDON, ns = ...
local core = ns.core
local M = core.RegisterModule({ key = "sb", title = "Sunderboard", perChar = false, default = true })

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
