-- Spell data for the FF Tracker module (originally AUTO-GENERATED from spells.json by
-- gen_data.py). The module header below (local core / RegisterModule) and the M.* prefix
-- were added by hand when FF Tracker was bundled into Assfish Aquarium. NOTE: the upstream
-- gen_data.py still emits `ns.*`, so a regen must be re-adapted (add the two header lines and
-- rename ns.* -> M.*) before replacing this file. Detection is by aura NAME (rank-agnostic);
-- `ids` gives the icon + a fallback.

local ADDON, ns = ...
local core = ns.core
local M = core.RegisterModule({
	key = "ff", title = "FF Tracker", perChar = true, default = true,
	category = "Combat", source = "mine", hasFrame = true,
	desc = "Tracks your debuffs and crowd control on the target and nearby enemies.",
})

M.FALLBACK_ICON = 134400 -- INV_Misc_QuestionMark

-- The spells a new window is seeded with, per the player's class (a list).
-- A class absent here starts with no window at all.
M.CLASS_DEFAULT_SPELLS = {
	DRUID = { "faerie_fire" },
	MAGE = { "fire_vulnerability" },
	PRIEST = { "power_word_shield", "weakened_soul" },
	ROGUE = { "expose_armor" },
	WARLOCK = { "curse_of_elements", "curse_of_shadow", "curse_of_recklessness" },
	WARRIOR = { "sunder_armor" },
}

M.SPELLS = {
	{ key = "faerie_fire", name = "Faerie Fire", class = "DRUID", ids = { 770, 778, 9749, 9907, 16857, 17390, 17391, 17392 }, duration = 40, auraType = "HARMFUL", color = { 0.62, 0.36, 0.94 } },
	{ key = "rejuvenation", name = "Rejuvenation", class = "DRUID", ids = { 774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841 }, duration = 12, auraType = "HELPFUL", color = { 0.95, 0.35, 0.80 } },
	{ key = "regrowth", name = "Regrowth", class = "DRUID", ids = { 8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858 }, duration = 21, auraType = "HELPFUL", color = { 0.30, 0.85, 0.45 } },
	{ key = "abolish_poison", name = "Abolish Poison", class = "DRUID", ids = { 2893, 8946 }, duration = 8, auraType = "HELPFUL", color = { 0.45, 0.85, 0.55 } },
	{ key = "hibernate", name = "Hibernate", class = "DRUID", ids = { 2637, 18657, 18658 }, duration = 40, auraType = "HARMFUL", color = { 0.45, 0.80, 0.72 } },
	{ key = "sunder_armor", name = "Sunder Armor", class = "WARRIOR", ids = { 7386, 7405, 8380, 11596, 11597, 25225 }, duration = 30, auraType = "HARMFUL", color = { 0.80, 0.55, 0.30 }, maxStacks = 5 },
	{ key = "demoralizing_shout", name = "Demoralizing Shout", class = "WARRIOR", ids = { 1160, 6190, 11554, 11555, 11556 }, duration = 30, auraType = "HARMFUL", color = { 0.72, 0.38, 0.36 } },
	{ key = "thunder_clap", name = "Thunder Clap", class = "WARRIOR", ids = { 6343, 8198, 8204, 8205, 11580, 11581 }, duration = 30, auraType = "HARMFUL", color = { 0.55, 0.70, 0.85 } },
	{ key = "intimidating_shout", name = "Intimidating Shout", class = "WARRIOR", ids = { 5246 }, duration = 8, auraType = "HARMFUL", color = { 0.72, 0.38, 0.34 } },
	{ key = "expose_armor", name = "Expose Armor", class = "ROGUE", ids = { 8647, 8649, 8650, 11197, 11198 }, duration = 30, auraType = "HARMFUL", color = { 0.85, 0.70, 0.40 } },
	{ key = "mind_numbing_poison", name = "Mind-numbing Poison", class = "ROGUE", ids = { 5760 }, duration = 10, auraType = "HARMFUL", color = { 0.55, 0.75, 0.40 } },
	{ key = "crippling_poison", name = "Crippling Poison", class = "ROGUE", ids = { 3409 }, duration = 12, auraType = "HARMFUL", color = { 0.40, 0.70, 0.45 } },
	{ key = "kidney_shot", name = "Kidney Shot", class = "ROGUE", ids = { 408, 8643 }, duration = 6, auraType = "HARMFUL", color = { 0.85, 0.30, 0.35 } },
	{ key = "cheap_shot", name = "Cheap Shot", class = "ROGUE", ids = { 1833 }, duration = 4, auraType = "HARMFUL", color = { 0.90, 0.45, 0.35 } },
	{ key = "gouge", name = "Gouge", class = "ROGUE", ids = { 1776, 1777, 8629, 11285, 11286 }, duration = 4, auraType = "HARMFUL", color = { 0.70, 0.50, 0.75 } },
	{ key = "blind", name = "Blind", class = "ROGUE", ids = { 2094 }, duration = 10, auraType = "HARMFUL", color = { 0.60, 0.62, 0.70 } },
	{ key = "curse_of_elements", name = "Curse of the Elements", class = "WARLOCK", ids = { 1490, 11721, 11722 }, duration = 300, auraType = "HARMFUL", color = { 0.30, 0.80, 0.75 } },
	{ key = "curse_of_shadow", name = "Curse of Shadow", class = "WARLOCK", ids = { 17862, 17937 }, duration = 300, auraType = "HARMFUL", color = { 0.55, 0.35, 0.80 } },
	{ key = "curse_of_recklessness", name = "Curse of Recklessness", class = "WARLOCK", ids = { 704, 7658, 7659, 11717 }, duration = 120, auraType = "HARMFUL", color = { 0.80, 0.50, 0.30 } },
	{ key = "curse_of_agony", name = "Curse of Agony", class = "WARLOCK", ids = { 980, 1014, 6217, 11711, 11712, 11713 }, duration = 24, auraType = "HARMFUL", color = { 0.66, 0.40, 0.76 } },
	{ key = "corruption", name = "Corruption", class = "WARLOCK", ids = { 172, 6222, 6223, 7648, 11671, 11672, 25311 }, duration = 18, auraType = "HARMFUL", color = { 0.45, 0.70, 0.40 } },
	{ key = "immolate", name = "Immolate", class = "WARLOCK", ids = { 348, 707, 1094, 2941, 11665, 11667, 11668, 25309 }, duration = 15, auraType = "HARMFUL", color = { 0.95, 0.45, 0.15 } },
	{ key = "siphon_life", name = "Siphon Life", class = "WARLOCK", ids = { 18265, 18879, 18880, 18881 }, duration = 30, auraType = "HARMFUL", color = { 0.70, 0.25, 0.45 } },
	{ key = "curse_of_tongues", name = "Curse of Tongues", class = "WARLOCK", ids = { 1714, 11719 }, duration = 30, auraType = "HARMFUL", color = { 0.60, 0.42, 0.78 } },
	{ key = "fear", name = "Fear", class = "WARLOCK", ids = { 5782, 6213, 6215 }, duration = 20, auraType = "HARMFUL", color = { 0.48, 0.30, 0.62 } },
	{ key = "fire_vulnerability", name = "Improved Scorch", class = "MAGE", ids = { 22959 }, duration = 30, auraType = "HARMFUL", color = { 0.95, 0.40, 0.20 }, maxStacks = 5 },
	{ key = "winters_chill", name = "Winter's Chill", class = "MAGE", ids = { 12579 }, duration = 15, auraType = "HARMFUL", color = { 0.55, 0.82, 0.95 }, maxStacks = 5 },
	{ key = "chilled", name = "Chilled", class = "MAGE", ids = { 6136 }, duration = 9, auraType = "HARMFUL", color = { 0.60, 0.85, 1.00 }, approx = true },
	{ key = "frost_nova", name = "Frost Nova", class = "MAGE", ids = { 122, 865, 6131, 10230 }, duration = 8, auraType = "HARMFUL", color = { 0.62, 0.87, 1.00 } },
	{ key = "frostbite", name = "Frostbite", class = "MAGE", ids = { 12494 }, duration = 5, auraType = "HARMFUL", color = { 0.45, 0.72, 0.95 } },
	{ key = "polymorph", name = "Polymorph", class = "MAGE", ids = { 118, 12824, 12825, 12826 }, duration = 50, auraType = "HARMFUL", color = { 0.95, 0.75, 0.85 } },
	{ key = "shadow_word_pain", name = "Shadow Word: Pain", class = "PRIEST", ids = { 589, 594, 970, 992, 2767, 10892, 10893, 10894 }, duration = 18, auraType = "HARMFUL", color = { 0.60, 0.40, 0.78 } },
	{ key = "devouring_plague", name = "Devouring Plague", class = "PRIEST", ids = { 2944, 19276, 19277, 19278, 19279, 19280 }, duration = 24, auraType = "HARMFUL", color = { 0.55, 0.75, 0.30 } },
	{ key = "shadow_weaving", name = "Shadow Weaving", class = "PRIEST", ids = { 15258 }, duration = 15, auraType = "HARMFUL", color = { 0.72, 0.45, 0.88 }, maxStacks = 5 },
	{ key = "renew", name = "Renew", class = "PRIEST", ids = { 139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929, 25315 }, duration = 15, auraType = "HELPFUL", color = { 0.85, 0.85, 0.60 } },
	{ key = "power_word_shield", name = "Power Word: Shield", class = "PRIEST", ids = { 17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901 }, duration = 30, auraType = "HELPFUL", color = { 0.60, 0.75, 0.98 } },
	{ key = "weakened_soul", name = "Weakened Soul", class = "PRIEST", ids = { 6788 }, duration = 15, auraType = "HARMFUL", color = { 0.55, 0.55, 0.62 } },
	{ key = "abolish_disease", name = "Abolish Disease", class = "PRIEST", ids = { 552 }, duration = 20, auraType = "HELPFUL", color = { 0.80, 0.78, 0.50 } },
	{ key = "shackle_undead", name = "Shackle Undead", class = "PRIEST", ids = { 9484, 9485, 10955 }, duration = 50, auraType = "HARMFUL", color = { 0.90, 0.88, 0.62 } },
	{ key = "psychic_scream", name = "Psychic Scream", class = "PRIEST", ids = { 8122, 8124, 10888, 10890 }, duration = 8, auraType = "HARMFUL", color = { 0.78, 0.52, 0.88 } },
	{ key = "judgement_of_wisdom", name = "Judgement of Wisdom", class = "PALADIN", ids = { 20186, 20355 }, duration = 10, auraType = "HARMFUL", color = { 0.45, 0.62, 0.92 } },
	{ key = "judgement_of_light", name = "Judgement of Light", class = "PALADIN", ids = { 20185, 20344, 20345, 20346 }, duration = 10, auraType = "HARMFUL", color = { 0.95, 0.85, 0.40 } },
	{ key = "judgement_crusader", name = "Judgement of the Crusader", class = "PALADIN", ids = { 20303, 20304, 20305, 21183 }, duration = 10, auraType = "HARMFUL", color = { 0.95, 0.60, 0.45 } },
	{ key = "turn_undead", name = "Turn Undead", class = "PALADIN", ids = { 2878, 5627, 10326 }, duration = 20, auraType = "HARMFUL", color = { 0.95, 0.90, 0.55 } },
}

-- Lookups + runtime name/icon resolution.
M.SPELL_BY_KEY = {}
M.SPELL_BY_ID = {}
M.SPELL_BY_NAME = {} -- keyed by the client's localized name (rank-agnostic)

local function resolveName(id)
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(id)
		if info and info.name then return info.name end
	end
	if GetSpellInfo then return (GetSpellInfo(id)) end
	return nil
end

local function resolveIcon(id)
	return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id))
		or (GetSpellTexture and GetSpellTexture(id))
		or M.FALLBACK_ICON
end

for _, spell in ipairs(M.SPELLS) do
	M.SPELL_BY_KEY[spell.key] = spell
	for _, id in ipairs(spell.ids) do
		M.SPELL_BY_ID[id] = spell
	end
	spell.icon = resolveIcon(spell.ids[1])
	local localized = resolveName(spell.ids[1])
	if localized then M.SPELL_BY_NAME[localized] = spell end
	M.SPELL_BY_NAME[spell.name] = spell -- English fallback
end
