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

local ns = AssfishAquarium
local core = ns.core
local W = core.widgets

core.useNativeSettings = (Settings and Settings.RegisterCanvasLayoutCategory) and true or false

local parentCategory
local settingsSyncs = {} -- re-run to reflect state changed elsewhere (minimap, slash)

function core.RefreshSettingsUI()
	for _, fn in ipairs(settingsSyncs) do fn() end
end

-- A Lock toggle a module drops into its own panel. Enabling/disabling the tool is done at the
-- ADDON level now (Hub / AddOns list), so this only controls whether the window is pinned. Kept
-- the name core.DisplayControl so module BuildSettings calls don't change. Returns the checkbox.
function core.DisplayControl(panel, x, y, M)
	local cb = W.check(panel, x, y, "Lock window in place",
		function() return core.GetModuleState(M.key) == "locked" end,
		function(v) core.SetLocked(M.key, v) end)
	settingsSyncs[#settingsSyncs + 1] = cb.sync
	return cb
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
	sub:SetPoint("RIGHT", f, "RIGHT", -16, 0)
	sub:SetJustifyH("LEFT")
	sub:SetText("Each tool is its own addon. Turn tools on/off in the Hub (or the AddOns list); each tool's own page is in the list at the left.")

	local openHub = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	openHub:SetSize(150, 24)
	openHub:SetPoint("TOPLEFT", 16, -78)
	openHub:SetText("Open the Hub")
	openHub:SetScript("OnClick", function() if core.ToggleHub then core.ShowHub() end end)
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

-- Open the Settings window straight to one module's own subcategory (used by the gear
-- Options button on each module window). Falls back to the parent page if we can't.
function core.OpenModuleSettings(key)
	local M = ns.modules[key]
	local cat = M and M.settingsCategory
	if core.useNativeSettings and cat and Settings.OpenToCategory then
		Settings.OpenToCategory(cat.GetID and cat:GetID() or cat.ID)
	else
		core.OpenSettings()
	end
end
