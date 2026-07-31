--[[--------------------------------------------------------------------------
	Target Frame+ - Core

	Total control over the Blizzard target frame's aura row on the modernized
	1.15.9 client. We POST-HOOK TargetFrame:UpdateAuras and re-style what Blizzard
	drew:

	  * size + sort auras by CATEGORY -- "important raid auras" (a curated spell set),
	    "my class auras" (cast by a player of THIS character's class), and "everything
	    else". Each category has a sort order (a 1/2/3 permutation) and a size OFFSET
	    (+/- px vs the global size); any spell can carry its own offset override.
	  * highlight auras YOU cast with a coloured outline
	  * a Test button that fills the real target frame with 16 fake debuffs mixed
	    across the categories

	Cooldown NUMBERS are intentionally left to OmniCC / the native countdown -- we
	don't draw or suppress them.

	Ground rules (from OmniCC / tullaCTC + ClassicAuraDurations): hooksecurefunc
	can't be undone, so hooks install ONCE and every hook body early-outs on
	M._active; work happens on UpdateAuras (aura CHANGES, not a SetCooldown storm);
	overlay widgets are created once per button and reused; the origin is cached.
----------------------------------------------------------------------------]]

local ns = AssfishAquarium
local core = ns.core

local M = core.RegisterModule({
	key = "utf", title = "Target Frame+", perChar = true, default = true,
	category = "Interface", source = "mine", hasFrame = false,
	desc = "Category-based size + sort of the target frame's auras, and highlight your own.",
})

M.DEFAULTS = {
	debuffSize    = 28,
	buffSize      = 22,
	rowWidth      = 220,   -- px before wrapping to a new row
	gapX          = 2,
	gapY          = 12,
	highlightMine = true,
	hlColor       = { 1.0, 0.85, 0.1 },

	-- Category model. Every aura is "raid" (in raidMembers), "class" (cast by a
	-- player of this character's class), or "other". Each has a sort order (a 1/2/3
	-- permutation, lower = front) and a size PERCENT of the global size (100 = same,
	-- clamped 50-200 in the UI).
	sortByCategory = true,
	catRaidOrder  = 1, catRaidPct  = 125,
	catClassOrder = 2, catClassPct = 110,
	catOtherOrder = 3, catOtherPct = 100,
	raidMembers = { -- the "important raid auras" set (ffKey -> true)
		sunder_armor = true, faerie_fire = true, curse_of_recklessness = true,
		expose_armor = true, demoralizing_shout = true,
	},
}
-- The shipped raid auras, in order -- shown first in the settings checklist.
M.DEFAULT_RAID = { "sunder_armor", "faerie_fire", "curse_of_recklessness", "expose_armor", "demoralizing_shout" }

M._active = false
local hooksInstalled = false
local MAXA = 40 -- safe upper bound when walking aura buttons

--------------------------------------------------------------------------------
-- FF Tracker spell list (optional dependency), used to identify a spell by id/name.
--------------------------------------------------------------------------------
local function ffSpell(spellId, name)
	local ff = ns.modules and ns.modules.ff
	if not ff then return nil end
	return (spellId and ff.SPELL_BY_ID and ff.SPELL_BY_ID[spellId])
		or (name and ff.SPELL_BY_NAME and ff.SPELL_BY_NAME[name])
end

--------------------------------------------------------------------------------
-- Categories: raid (in the curated set) > class (caster is a player of my class) > other.
--------------------------------------------------------------------------------
local playerClass -- english class token, filled at Enable

local function categoryOf(key, caster)
	local d = M.db
	if key and d.raidMembers[key] then return "raid" end
	if caster then
		local _, cls = UnitClass(caster)
		if cls and cls == playerClass then return "class" end
	end
	return "other"
end

local function catOrder(cat)
	local d = M.db
	return (cat == "raid" and d.catRaidOrder) or (cat == "class" and d.catClassOrder) or d.catOtherOrder
end

-- Size percent for a category (100 = same as the global size).
local function catPct(cat)
	local d = M.db
	return (cat == "raid" and d.catRaidPct) or (cat == "class" and d.catClassPct) or d.catOtherPct
end

M.CategoryOf = categoryOf
M.CatPct = catPct

-- Keep the three sort orders a 1/2/3 permutation: setting one swaps with whoever held it.
local ORDER_FIELD = { raid = "catRaidOrder", class = "catClassOrder", other = "catOtherOrder" }
function M.SetCatOrder(cat, order)
	local d = M.db
	local field = ORDER_FIELD[cat]
	if not field then return end
	local old = d[field]
	if old == order then return end
	for c, f in pairs(ORDER_FIELD) do
		if c ~= cat and d[f] == order then d[f] = old end
	end
	d[field] = order
end

--------------------------------------------------------------------------------
-- Modern/legacy target-frame shims (feature-detected, mirroring ClassicAuraDurations).
--------------------------------------------------------------------------------
local function HookUpdateAuras(cb)
	if TargetFrame and type(TargetFrame.UpdateAuras) == "function" then
		hooksecurefunc(TargetFrame, "UpdateAuras", cb); return true
	elseif type(TargetFrame_UpdateAuras) == "function" then
		hooksecurefunc("TargetFrame_UpdateAuras", cb); return true
	end
	return false
end

local function RefreshAuras()
	if TargetFrame and type(TargetFrame.UpdateAuras) == "function" then
		TargetFrame:UpdateAuras()
	elseif type(TargetFrame_UpdateAuras) == "function" then
		TargetFrame_UpdateAuras(TargetFrame)
	end
end

local function ShouldShowDebuff(frame, unit, caster, npAll, casterIsPlayer)
	if frame and type(frame.ShouldShowDebuffs) == "function" then
		return frame:ShouldShowDebuffs(unit, caster, npAll, casterIsPlayer)
	elseif type(TargetFrame_ShouldShowDebuffs) == "function" then
		return TargetFrame_ShouldShowDebuffs(unit, caster, npAll, casterIsPlayer)
	end
	return true
end

--------------------------------------------------------------------------------
-- Per-button overlay (created once, reused): a coloured outline for "mine".
--------------------------------------------------------------------------------
local function ensureGlow(btn)
	if btn._utfGlow then return btn._utfGlow end
	local function edge()
		local t = btn:CreateTexture(nil, "OVERLAY")
		t:SetColorTexture(1, 1, 1, 1)
		t:Hide()
		return t
	end
	btn._utfGlow = { top = edge(), bottom = edge(), left = edge(), right = edge() }
	return btn._utfGlow
end

local function setGlow(btn, show, r, g, b)
	local gl = btn._utfGlow
	if not show then
		if gl then gl.top:Hide(); gl.bottom:Hide(); gl.left:Hide(); gl.right:Hide() end
		return
	end
	gl = ensureGlow(btn)
	local th = 2
	gl.top:ClearAllPoints();    gl.top:SetPoint("TOPLEFT", btn, "TOPLEFT", -1, 1);       gl.top:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 1, 1);        gl.top:SetHeight(th)
	gl.bottom:ClearAllPoints(); gl.bottom:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -1, -1); gl.bottom:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, -1); gl.bottom:SetHeight(th)
	gl.left:ClearAllPoints();   gl.left:SetPoint("TOPLEFT", btn, "TOPLEFT", -1, 1);      gl.left:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -1, -1);  gl.left:SetWidth(th)
	gl.right:ClearAllPoints();  gl.right:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 1, 1);    gl.right:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, -1); gl.right:SetWidth(th)
	for _, t in pairs(gl) do t:SetColorTexture(r, g, b, 1); t:Show() end
end

--------------------------------------------------------------------------------
-- Gather the auras Blizzard actually placed, mapped to their buttons (CAD-style
-- walk so button N <-> the Nth SHOWN aura, matching Blizzard's own assignment).
--------------------------------------------------------------------------------
local function gatherDebuffs(frame, unit)
	local list, frameNum, index = {}, 1, 1
	while frameNum <= MAXA do
		local name, _, _, _, _, _, caster, _, _, spellId, _, _, casterIsPlayer, npAll =
			UnitDebuff(unit, index, "INCLUDE_NAME_PLATE_ONLY")
		if not name then break end
		if ShouldShowDebuff(frame, unit, caster, npAll, casterIsPlayer) then
			local btn = _G["TargetFrameDebuff" .. frameNum]
			if btn and btn:IsShown() then
				local sp = ffSpell(spellId, name)
				local key = sp and sp.key
				list[#list + 1] = {
					btn = btn, name = name, spellId = spellId, key = key, cat = categoryOf(key, caster),
					mine = (caster == "player"),
				}
			end
			frameNum = frameNum + 1
		end
		index = index + 1
	end
	return list
end

local function gatherBuffs(unit)
	local list = {}
	for i = 1, MAXA do
		local name, _, _, _, _, _, caster, _, _, spellId = UnitBuff(unit, i)
		if not name then break end
		local btn = _G["TargetFrameBuff" .. i]
		if btn and btn:IsShown() then
			local sp = ffSpell(spellId, name)
			local key = sp and sp.key
			list[#list + 1] = {
				btn = btn, name = name, spellId = spellId, key = key, cat = categoryOf(key, caster),
				mine = (caster == "player"),
			}
		end
	end
	return list
end

--------------------------------------------------------------------------------
-- Layout + overlay. Origin (block start) is captured once from Blizzard's own
-- placement of the first button and cached, so our re-anchoring never drifts.
--------------------------------------------------------------------------------
local function originFor(prefix, cacheField)
	if M[cacheField] then return M[cacheField] end
	local btn = _G[prefix .. "1"]
	if not btn then return nil end
	local p, relTo, relP, x, y = btn:GetPoint()
	if not p then return nil end
	M[cacheField] = { p, relTo, relP, x, y }
	return M[cacheField]
end

local function sizeFor(entry, isDebuff)
	local base = isDebuff and M.db.debuffSize or M.db.buffSize
	-- Category sizing only applies when the category system is on; otherwise uniform.
	if not M.db.sortByCategory then return base end
	return math.max(8, math.floor(base * catPct(entry.cat) / 100 + 0.5))
end

local function process(list, isDebuff, prefix, cacheField)
	if #list == 0 then return end
	local d = M.db

	-- Sort by category order (raid < class < other), stable within a category.
	if d.sortByCategory then
		local orig = {}
		for i, e in ipairs(list) do orig[e] = i end
		table.sort(list, function(a, b)
			local ra, rb = catOrder(a.cat), catOrder(b.cat)
			if ra ~= rb then return ra < rb end
			return orig[a] < orig[b]
		end)
	end

	-- We always resize + re-anchor (there's no "off" now).
	local o = originFor(prefix, cacheField)
	local x, rowY, rowH = 0, 0, 0
	for _, e in ipairs(list) do
		local w = sizeFor(e, isDebuff)
		if o then
			e.btn:SetSize(w, w)
			if x > 0 and (x + w) > d.rowWidth then x = 0; rowY = rowY + rowH + d.gapY; rowH = 0 end
			e.btn:ClearAllPoints()
			e.btn:SetPoint(o[1], o[2], o[3], o[4] + x, o[5] - rowY)
			x = x + w + d.gapX
			if w > rowH then rowH = w end
		end
		setGlow(e.btn, d.highlightMine and e.mine, d.hlColor[1], d.hlColor[2], d.hlColor[3])
	end
end

-- The post-hook body: re-style whatever Blizzard just drew.
local function apply()
	if not M._active then return end
	local frame = TargetFrame
	if not frame then return end
	local unit = frame.unit or "target"
	if not UnitExists(unit) then return end
	process(gatherDebuffs(frame, unit), true, "TargetFrameDebuff", "_utfOriginD")
	process(gatherBuffs(unit),          false, "TargetFrameBuff",   "_utfOriginB")
end
M.Apply = apply

-- Settings changes route through here: re-drive Blizzard's layout so our post-hook re-applies.
function M.Refresh()
	if M._active then RefreshAuras() end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
-- Public + idempotent: the Settings panel is built (Boot's InitSettings) BEFORE the
-- module is enabled, so BuildSettings calls this to seed the DB before it reads it.
function M.EnsureDefaults()
	local d = M.db
	if not d then return end
	for k, v in pairs(M.DEFAULTS) do
		if d[k] == nil then
			if type(v) == "table" then
				d[k] = {}
				for kk, vv in pairs(v) do d[k][kk] = vv end
			else
				d[k] = v
			end
		end
	end
end

-- Restore every Target Frame+ setting to its default (the "Reset to Addon Defaults" button).
function M.ResetDefaults()
	local d = M.db
	if not d then return end
	for k in pairs(M.DEFAULTS) do d[k] = nil end
	M.EnsureDefaults()
	M.Refresh()
end

-- Set the aura sizes + row wrap to Blizzard's native values (the target-frame
-- constants) and neutralise the category percents so nothing scales -- leaving
-- sorting, highlight and membership alone.
function M.BlizzardSizes()
	local d = M.db
	if not d then return end
	d.debuffSize = 21   -- LARGE_AURA_SIZE
	d.buffSize   = 21
	d.rowWidth   = 122  -- AURA_ROW_WIDTH
	d.catRaidPct, d.catClassPct, d.catOtherPct = 100, 100, 100
	M.Refresh()
end

function M.Enable()
	M.EnsureDefaults()
	playerClass = select(2, UnitClass("player"))
	if not hooksInstalled then
		HookUpdateAuras(function() apply() end)
		hooksInstalled = true
	end
	M._active = true
	if not M._ev then
		M._ev = CreateFrame("Frame")
		M._ev:SetScript("OnEvent", function() apply() end)
	end
	-- Aura CHANGES come through the UpdateAuras hook; we only need target swaps here.
	M._ev:RegisterEvent("PLAYER_TARGET_CHANGED")
	apply()
	RefreshAuras()
end

function M.Disable()
	M._active = false
	if M._ev then M._ev:UnregisterAllEvents() end
	for i = 1, MAXA do
		for _, prefix in ipairs({ "TargetFrameDebuff", "TargetFrameBuff" }) do
			local btn = _G[prefix .. i]
			if btn then setGlow(btn, false) end
		end
	end
	RefreshAuras() -- Blizzard relays the row out at its default sizes/anchors
end

-- Diagnostic: what did we compute + apply for the current target's debuffs?
function M.Debug()
	print(string.format("|cffff7d0aTF+|r active=%s sort=%s class=%s",
		tostring(M._active), tostring(M.db and M.db.sortByCategory), tostring(playerClass)))
	if not UnitExists("target") then print("  (no target)") return end
	local i = 1
	while true do
		local name, _, _, _, _, _, caster, _, _, spellId = UnitDebuff("target", i, "INCLUDE_NAME_PLATE_ONLY")
		if not name then break end
		local sp = ffSpell(spellId, name)
		local key = sp and sp.key
		local cat = categoryOf(key, caster)
		local btn = _G["TargetFrameDebuff" .. i]
		print(string.format("  '%s' key=%s cat=%s caster=%s want=%d btnW=%s",
			name, tostring(key), cat, tostring(caster),
			math.floor(M.db.debuffSize * catPct(cat) / 100 + 0.5),
			btn and string.format("%.0f", btn:GetWidth() or 0) or "nil-btn"))
		i = i + 1
	end
end

-- No movable window (hasFrame=false); the slash just opens options (or the /utf debug readout).
function M.OnSlash(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "debug" then M.Debug() else core.OpenModuleSettings("utf") end
end

-- Standalone /utf (the suite router already provides "/aq utf").
SLASH_AAQ_UTF1 = "/utf"
SlashCmdList.AAQ_UTF = function(msg) M.OnSlash(msg) end
