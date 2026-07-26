--[[--------------------------------------------------------------------------
	ButtBass - Settings (fills the module's Assfish Aquarium Settings subcategory).

	Replaces the standalone options window (which was opened by the old minimap
	button). Uses the shared core widgets. Sections:
	  * Display tri-state (Disabled / Unlocked / Locked) via core.DisplayControl.
	  * Windfury announcements checkbox -> toggles the always-on SERVICE live
	    (core.GetDB("bb").windfury, default ON) via M.WF_SetEnabled.
	  * Heal Tracker: Enabled, amount-side layout, size.
	  * Party Frame: Enabled, size, WF-drop sound toggle + a UIDropDownMenu sound picker.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local M = ns.modules.bb
local W = core.widgets

-- Called by the shared core (core.AddSubcategory) with a fresh canvas frame.
function M.BuildSettings(panel)
	if M.SeedDB then M.SeedDB() end
	local syncs = {}
	local function reg(w) if w and w.sync then syncs[#syncs + 1] = w.sync end return w end

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -16)
	title:SetText("Shaman Stuff")
	title:SetTextColor(1, 0.82, 0)

	core.DisplayControl(panel, 14, -46, M) -- shared Hidden / Unlocked / Locked tri-state

	-- Windfury announcer (the always-on service; runs for every class regardless of
	-- whether the ButtBass panels are shown).
	reg(W.check(panel, 16, -76, "Windfury announcements (broadcast + receive)",
		function() return core.GetDB("bb").windfury ~= false end,
		function(v) if M.WF_SetEnabled then M.WF_SetEnabled(v) end end))
	local wfNote = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	wfNote:SetPoint("TOPLEFT", 40, -98)
	wfNote:SetText("Runs for all classes, even while Shaman Stuff is disabled.")

	-- ===== Heal Tracker =====
	local h1 = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	h1:SetPoint("TOPLEFT", 16, -124)
	h1:SetText("|cff66ccffHeal Tracker|r")

	reg(W.check(panel, 16, -146, "Enabled",
		function() return M.db.chEnabled ~= false end,
		function(v)
			M.db.chEnabled = v
			if not v and M.Display_HideNow then M.Display_HideNow() end
		end))

	reg(W.radioRow(panel, 16, -176, "Heal amount:",
		{ { text = "Left", value = "heal_name" }, { text = "Right", value = "name_heal" } },
		function() return M.db.chLayout or "heal_name" end,
		function(v) M.db.chLayout = v; if M.Display_ApplyLayout then M.Display_ApplyLayout() end end))

	reg(W.slider(panel, 16, -208, "Heal display size", 0.5, 2.5, 0.25,
		function() return M.db.chScale or 1 end,
		function(v) M.db.chScale = v; if M.Display_ApplyScale then M.Display_ApplyScale() end end))

	-- ===== Party Frame =====
	local h2 = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	h2:SetPoint("TOPLEFT", 16, -258)
	h2:SetText("|cff66ccffParty Frame|r")

	reg(W.check(panel, 16, -280, "Enabled",
		function() return M.db.wfEnabled ~= false end,
		function(v) M.db.wfEnabled = v; if M.WFDisplay_ApplyEnabled then M.WFDisplay_ApplyEnabled() end end))

	-- Only show players Windfury helps (melee); the non-melee rows drop out instead of fading.
	reg(W.check(panel, 16, -304, "Only show melee (Windfury users)",
		function() return M.db.wfMeleeOnly and true or false end,
		function(v) M.db.wfMeleeOnly = v; if M.WFDisplay_OnRosterChange then M.WFDisplay_OnRosterChange() end end))

	reg(W.slider(panel, 16, -334, "Party frame size", 0.5, 2.5, 0.25,
		function() return M.db.wfScale or 1 end,
		function(v) M.db.wfScale = v; if M.WFDisplay_ApplyScale then M.WFDisplay_ApplyScale() end end))

	reg(W.check(panel, 16, -374, "Play sound when Windfury drops",
		function() return M.db.wfDropSound ~= false end,
		function(v) M.db.wfDropSound = v end))

	-- sound picker (UIDropDownMenu, same pattern the standalone addon used)
	local ddLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ddLabel:SetPoint("TOPLEFT", 20, -400)
	ddLabel:SetText("WF-drop sound")
	local dd = CreateFrame("Frame", "AssfishButtBassWFSoundDD", panel, "UIDropDownMenuTemplate")
	dd:SetPoint("TOPLEFT", 4, -416)
	UIDropDownMenu_SetWidth(dd, 130)
	UIDropDownMenu_Initialize(dd, function(_, level)
		for i, s in ipairs(M.WF_SOUNDS or {}) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = s.name
			info.checked = (M.db.wfSoundIdx or 1) == i
			info.func = function()
				M.db.wfSoundIdx = i
				UIDropDownMenu_SetText(dd, s.name)
				if M.WF_PlaySound then M.WF_PlaySound(i) end   -- preview
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)
	local function syncDD()
		local s = (M.WF_SOUNDS or {})[M.db.wfSoundIdx or 1]
		UIDropDownMenu_SetText(dd, (s and s.name) or "-")
	end
	syncs[#syncs + 1] = syncDD

	local function refresh() for _, fn in ipairs(syncs) do fn() end end
	panel:SetScript("OnShow", refresh)
	refresh()
end
