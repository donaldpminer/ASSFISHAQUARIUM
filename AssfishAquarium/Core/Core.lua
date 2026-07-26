--[[--------------------------------------------------------------------------
	Assfish Aquarium - shared core (skeleton)

	The umbrella that hosts each bundled tool as a "module". This file will grow
	into: the module registry (register / enable-disable), the merged saved
	variables, the ONE native-Settings parent category (a subcategory per module),
	and the ONE minimap button. Modules live under `ns.<module>` sub-namespaces so
	their symbols don't collide.

	Being assembled from the four standalone addons; skeleton for now.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

ns.ADDON = ADDON
ns.VERSION = "0.1.0"
ns.modules = {} -- name -> module record (populated during integration)

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
	AssfishAquariumDB = AssfishAquariumDB or {}
	AssfishAquariumCharDB = AssfishAquariumCharDB or {}
	ns.db = AssfishAquariumDB          -- account-wide settings
	ns.cdb = AssfishAquariumCharDB     -- per-character settings
	-- module registration + init is wired up here as modules are integrated.
end)
