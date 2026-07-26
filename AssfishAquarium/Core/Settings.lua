--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Settings

	One native Settings page (Options -> AddOns -> Assfish Aquarium) with a
	subcategory per module. The parent page just enables/disables each tool; each
	module's own page (built by its BuildSettings) holds that tool's controls plus
	a shared Display tri-state (Disabled / Unlocked / Locked).

	Feature-detected: on the modern client the native Settings API is used; if it's
	absent the modules simply have no settings screen (reachable state is still fully
	drivable from the minimap dropdown + slash commands).
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local W = core.widgets

core.useNativeSettings = (Settings and Settings.RegisterCanvasLayoutCategory) and true or false

local parentCategory
local settingsSyncs = {} -- re-run to reflect state changed elsewhere (minimap, slash)

function core.RefreshSettingsUI()
	for _, fn in ipairs(settingsSyncs) do fn() end
end

-- A Display tri-state (Disabled/Unlocked/Locked) a module drops into its own panel wherever
-- it likes; drives core.SetModuleState. Returns the radio row.
function core.DisplayControl(panel, x, y, M)
	local row = W.radioRow(panel, x, y, "Display:",
		{ { text = "Disabled", value = "hidden" }, { text = "Unlocked", value = "unlocked" }, { text = "Locked", value = "locked" } },
		function() return core.GetModuleState(M.key) end,
		function(v) core.SetModuleState(M.key, v) end)
	settingsSyncs[#settingsSyncs + 1] = row.sync
	return row
end

function core.AddSubcategory(M)
	if not core.useNativeSettings or not parentCategory then return end
	local f = CreateFrame("Frame")
	core.SafeCall(M.title .. ":BuildSettings", M.BuildSettings, f, M)
	M.settingsCategory = Settings.RegisterCanvasLayoutSubcategory(parentCategory, f, M.title)
end

local function buildParentPanel(f)
	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -16)
	title:SetText("ASSFISH AQUARIUM")
	title:SetTextColor(1, 0.82, 0)
	local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", 16, -40)
	sub:SetText("Enable the tools you want. Each has its own page in the list at the left.")
	local y = -70
	core.EachAvailableModule(function(M)
		local cb = W.check(f, 16, y, "Enable " .. M.title,
			function() return core.GetModuleState(M.key) ~= "hidden" end,
			function(v) core.SetModuleState(M.key, v and "unlocked" or "hidden") end)
		settingsSyncs[#settingsSyncs + 1] = cb.sync
		y = y - 26
	end)
end

-- Called by Boot at login, after SVs are loaded and every module has registered.
function core.InitSettings()
	if not core.useNativeSettings then return end
	local root = CreateFrame("Frame")
	buildParentPanel(root)
	parentCategory = Settings.RegisterCanvasLayoutCategory(root, "ASSFISH AQUARIUM")
	Settings.RegisterAddOnCategory(parentCategory)
	core.settingsParent = parentCategory
	core.EachAvailableModule(function(M) core.AddSubcategory(M) end)
end

function core.OpenSettings()
	if core.useNativeSettings and parentCategory and Settings.OpenToCategory then
		Settings.OpenToCategory(parentCategory.GetID and parentCategory:GetID() or parentCategory.ID)
	end
end
