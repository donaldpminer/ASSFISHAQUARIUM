--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Boot   (loads LAST in Core/)

	The single boot frame: initializes the two SavedVariables, wires up Settings +
	the minimap, applies each module's saved display state, and owns the ONE
	COMBAT_LOG_EVENT_UNFILTERED registration (fanned out to enabled modules). Also
	the slash router.

	All module files have already run RegisterModule() by the time PLAYER_LOGIN fires
	(Lua files load before any event), so the registry is complete here.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:SetScript("OnEvent", function(_, event)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		core.DispatchCLEU()
		return
	end
	-- PLAYER_LOGIN: SavedVariables are loaded by now.
	AssfishAquariumDB = AssfishAquariumDB or {}
	AssfishAquariumCharDB = AssfishAquariumCharDB or {}
	ns.db = AssfishAquariumDB       -- account-wide
	ns.cdb = AssfishAquariumCharDB  -- per-character

	-- Give every module its SV slice up front so its settings page works even while disabled.
	core.EachModule(function(M) M.db = core.GetDB(M.key) end)

	if core.InitSettings then core.InitSettings() end
	if core.BuildMinimap then core.BuildMinimap() end
	if core.StartServices then core.StartServices() end -- always-on services (e.g. Windfury)
	core.StartModules()                                 -- apply saved hidden/unlocked/locked
	if core.MaybeShowOnboarding then core.MaybeShowOnboarding() end -- first-run setup wizard
end)

--------------------------------------------------------------------------------
-- Slash router: /aquarium (/aq). `/aq` alone opens the Hub. Core words (hub / setup /
-- settings) are handled here; `/aq <key> <rest>` and the per-module aliases forward
-- `rest` to that module's M.OnSlash.
--------------------------------------------------------------------------------
local function route(key, rest)
	local M = ns.modules[key]
	if M and M.OnSlash then M.OnSlash(rest or "") end
end

SLASH_ASSFISH1 = "/aquarium"
SLASH_ASSFISH2 = "/aq"
SlashCmdList.ASSFISH = function(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local key, rest = msg:match("^(%S+)%s*(.*)$")
	key = key and key:lower() or ""
	if key == "" or key == "hub" then
		core.ToggleHub()
	elseif key == "setup" then
		if core.ShowOnboarding then core.ShowOnboarding(true) end
	elseif key == "settings" or key == "options" or key == "config" then
		core.OpenSettings()
	elseif ns.modules[key] then
		route(key, rest)
	else
		core.ToggleHub()
	end
end

-- Convenience aliases that forward to a module (kept so muscle memory still works).
local ALIASES = { mob = "mob", mobber = "mob", fft = "ff", fftracker = "ff",
	sb = "sb", sunderboard = "sb", bb = "bb", buttbass = "bb" }
for cmd, key in pairs(ALIASES) do
	local up = "ASSFISH_" .. cmd:upper()
	_G["SLASH_" .. up .. "1"] = "/" .. cmd
	SlashCmdList[up] = function(msg) route(key, (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
end
