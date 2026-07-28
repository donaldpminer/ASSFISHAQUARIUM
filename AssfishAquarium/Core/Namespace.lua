--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Namespace

	The shared surface every bundled tool plugs into. Loads FIRST (see the .toc).

	Layout of the addon private table `ns`:
	  ns.core            shared API (this file + the other Core/ files hang helpers here)
	  ns.modules[key]    one table per bundled tool -- its former `ns.*` contents live here,
	                     so Mobber's ns.Rebuild becomes ns.modules.mob.Rebuild, etc. Modules
	                     grab a local `M = ns.modules.<key>` at the top of each file.
	  ns.services[name]  always-on services that run regardless of any module's enable state
	                     (e.g. the Windfury announcer).

	A "module" is a bundled tool the user can turn on/off. Its lifecycle is a TRI-STATE:
	  "hidden"    disabled entirely -- no frames, no events, no tickers.
	  "unlocked"  enabled + its window(s) shown and movable.
	  "locked"    enabled + shown but pinned / click-through.
	The Hub, the setup wizard, and the Settings page drive this via core.SetModuleState. The Hub
	presents it as two plain toggles (Enabled + Lock) via core.SetEnabled / core.SetLocked.

	State is PER-CHARACTER (an alt can run a different set of tools) and OPT-IN: nothing enables
	itself on a fresh character -- the first-run setup wizard (Onboarding.lua) asks what to turn
	on. A module's `default` means "recommended in the wizard", not "auto-enable".
----------------------------------------------------------------------------]]

local ADDON = ...

-- The Core exposes its shared surface as a GLOBAL. Each module now ships as its OWN addon
-- (AssfishAquarium_Mobber, _Sunderboard, ...), and separate addons do NOT share this addon's
-- private `...` table -- so they reach Core through this global instead. Core is every module
-- addon's declared dependency, so it (and this table) always loads first.
AssfishAquarium = AssfishAquarium or {}
local ns = AssfishAquarium

ns.ADDON = ADDON
ns.core = ns.core or {}
ns.modules = ns.modules or {}      -- key -> module table
ns.services = ns.services or {}    -- name -> service table
ns.moduleOrder = ns.moduleOrder or {} -- registration order (for stable dropdown/settings order)

local core = ns.core

-- ns.db (account) and ns.cdb (per-character) are assigned by Boot.lua at PLAYER_LOGIN,
-- before any module is enabled.

--------------------------------------------------------------------------------
-- Module registry
--------------------------------------------------------------------------------
-- Register a bundled tool. Called at FILE LOAD (before any event fires). spec fields:
--   key             stable id -> SavedVariables slice + slash subcommand + dropdown row
--   title           display name (Settings subcategory + minimap dropdown)
--   perChar         true = per-character saved settings, false = account-wide (Sunderboard)
--   default         enabled on first run? (default true)
--   Enable(M)       build frames, register events, start tickers (called when leaving "hidden")
--   Disable(M)      tear all that down (called when entering "hidden")
--   SetDisplayState(M, "unlocked"|"locked")  apply the lock/show state while enabled
--   BuildSettings(panel, M)  fill a Settings canvas with this module's controls
function core.RegisterModule(spec)
	local M = ns.modules[spec.key]
	if not M then
		M = { key = spec.key, _tickers = {} }
		ns.modules[spec.key] = M
		ns.moduleOrder[#ns.moduleOrder + 1] = spec.key
	end
	M.title = spec.title or spec.key
	M.perChar = spec.perChar and true or false
	-- default may be a boolean OR a function -- it now means "RECOMMENDED on first setup" (the
	-- setup wizard pre-checks it), NOT "auto-enable". Nothing auto-enables; the user opts in.
	if spec.default == nil then M.default = true else M.default = spec.default end
	M.Enable = spec.Enable
	M.Disable = spec.Disable
	M.SetDisplayState = spec.SetDisplayState
	M.BuildSettings = spec.BuildSettings
	-- available: bool/function -> should this module EXIST for the player at all? An
	-- unavailable module (e.g. Shaman Stuff for a non-Shaman) is registered so its always-on
	-- service still has an M/DB, but it never appears in the minimap, settings, or gets enabled.
	M.available = spec.available -- nil = always available

	-- Catalog metadata (the meta-manager surfaces these in the Hub + setup wizard).
	M.category    = spec.category or "Other"        -- grouping in the Hub
	M.source      = spec.source or "mine"           -- "mine" | "adopted"
	M.author      = spec.author                     -- original author (adopted addons)
	M.adoptedFrom = spec.adoptedFrom                -- original addon name / URL
	M.desc        = spec.desc or ""                 -- one-line summary
	M.hasFrame    = spec.hasFrame and true or false -- owns a movable window (lock/unlock applies)
	M.icon        = spec.icon                       -- optional texture path for the Hub row
	M.version     = spec.version                    -- optional per-module version string
	return M
end

-- Distinct module categories present, in first-registration order (for Hub grouping).
function core.Categories()
	local order, seen = {}, {}
	for _, key in ipairs(ns.moduleOrder) do
		local M = ns.modules[key]
		if M and core.IsAvailable(key) and not seen[M.category] then
			seen[M.category] = true
			order[#order + 1] = M.category
		end
	end
	return order
end

-- Is a module available to this player? (class-gated modules answer via a function.)
function core.IsAvailable(key)
	local M = ns.modules[key]
	if not M then return false end
	local a = M.available
	if a == nil then return true end
	if type(a) == "function" then return a() and true or false end
	return a and true or false
end

function core.EachModule(fn) -- iterate ALL registered modules, in registration order
	for _, key in ipairs(ns.moduleOrder) do fn(ns.modules[key]) end
end

-- Iterate only modules available to this player (used by every user-facing surface).
function core.EachAvailableModule(fn)
	for _, key in ipairs(ns.moduleOrder) do
		if core.IsAvailable(key) then fn(ns.modules[key]) end
	end
end

-- Call a module/service hook defensively: one module's error must never abort login or the
-- lifecycle of the others. Nil fn is a no-op. Surfaces the error to chat so it's not silent.
function core.SafeCall(label, fn, ...)
	if type(fn) ~= "function" then return end
	local ok, err = pcall(fn, ...)
	if not ok then
		print("|cffff5555ASSFISH AQUARIUM|r error in " .. tostring(label) .. ": " .. tostring(err))
	end
	return ok
end

--------------------------------------------------------------------------------
-- Always-on services: run regardless of any module's enable state (e.g. ButtBass's
-- Windfury announcer, which the user wants live unless explicitly turned off). A service
-- registers a Start() that Boot calls once at login; the service itself decides whether to
-- act based on its own saved setting, and re-checks that setting when it changes.
--------------------------------------------------------------------------------
function core.RegisterService(name, spec)
	ns.services[name] = spec
	return spec
end

function core.StartServices()
	for name, s in pairs(ns.services) do
		core.SafeCall("service:" .. name, s.Start)
	end
end

--------------------------------------------------------------------------------
-- SavedVariables slices
--------------------------------------------------------------------------------
-- The umbrella declares BOTH an account SV (ns.db) and a per-character SV (ns.cdb).
-- Each module gets its own slice, routed by its `perChar` flag; created lazily.
function core.GetDB(key)
	local M = ns.modules[key]
	local root = (M and M.perChar) and ns.cdb or ns.db
	root.modules = root.modules or {}
	root.modules[key] = root.modules[key] or {}
	return root.modules[key]
end

--------------------------------------------------------------------------------
-- Tracked tickers (so a disabled module leaves nothing running)
--------------------------------------------------------------------------------
function core.NewTicker(key, interval, fn)
	local t = C_Timer.NewTicker(interval, fn)
	local M = ns.modules[key]
	if M then M._tickers[#M._tickers + 1] = t end
	return t
end

function core.CancelTickers(key)
	local M = ns.modules[key]
	if not M then return end
	for _, t in ipairs(M._tickers) do
		if t and t.Cancel then t:Cancel() end
	end
	wipe(M._tickers)
end

--------------------------------------------------------------------------------
-- Combat-log router: ONE COMBAT_LOG_EVENT_UNFILTERED registration (in Boot.lua),
-- unpacked once, fanned out only to currently-subscribed (i.e. enabled) modules.
--------------------------------------------------------------------------------
local cleuSubs = {} -- key -> fn(CombatLogGetCurrentEventInfo()...)
function core.SubscribeCLEU(key, fn) cleuSubs[key] = fn end
function core.UnsubscribeCLEU(key) cleuSubs[key] = nil end
function core.DispatchCLEU() -- called by Boot's event frame
	for _, fn in pairs(cleuSubs) do fn(CombatLogGetCurrentEventInfo()) end
end

--------------------------------------------------------------------------------
-- Aura read shim (modern-API compat). Prefer C_UnitAuras (retail-style, the direction
-- the client is moving) and normalize to the classic positional shape modules expect;
-- fall back to the still-present global UnitAura. Returns:
--   name, icon, count, dispelType, duration, expirationTime, source, isStealable,
--   nameplateShowPersonal, spellId  (nil past the last aura, like UnitAura)
--------------------------------------------------------------------------------
local GetAuraDataByIndex = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
function core.GetAura(unit, index, filter)
	if GetAuraDataByIndex then
		local d = GetAuraDataByIndex(unit, index, filter)
		if not d then return nil end
		return d.name, d.icon, d.applications, d.dispelName, d.duration, d.expirationTime,
			d.sourceUnit, d.isStealable, d.nameplateShowPersonal, d.spellId
	end
	return UnitAura(unit, index, filter)
end

--------------------------------------------------------------------------------
-- Module lifecycle (enable / disable / tri-state), stored in the account SV so it
-- survives reload. Boot restores it at login; the minimap + Settings drive it live.
--------------------------------------------------------------------------------
-- Module enable/lock state is now PER-CHARACTER (an alt can run a different set of tools),
-- which is the fix for "settings shared across every character". Lives in the per-char SV.
local function stateStore()
	ns.cdb.moduleState = ns.cdb.moduleState or {}
	return ns.cdb.moduleState
end

-- Now that each module ships as its OWN addon, "enabled" = the addon being loaded (Blizzard
-- AddOn list / Hub, applied on reload). So a module that IS loaded should be ACTIVE: this
-- per-char state now only remembers its LOCK ("unlocked" default so a fresh window can be
-- positioned; "locked" once pinned). "hidden" survives only as a live per-window hide (a
-- module's own /slash hide), never the primary on/off.
function core.GetModuleState(key) -- "hidden" | "unlocked" | "locked"
	local st = stateStore()[key]
	if st == "unlocked" or st == "locked" or st == "hidden" then return st end
	return "unlocked" -- loaded => shown; the addon being loaded is the "enabled" gate
end

function core.IsEnabled(key)
	return core.GetModuleState(key) ~= "hidden"
end

-- Should the setup wizard PRE-CHECK this module? (the former "default on" signal, e.g. a
-- class-conditional function.) Recommendation != auto-enable; the user still confirms.
function core.IsRecommended(key)
	local M = ns.modules[key]
	if not M then return false end
	local d = M.default
	if type(d) == "function" then
		local ok, res = pcall(d)
		return ok and res and true or false
	end
	return d and true or false
end

--------------------------------------------------------------------------------
-- Sub-addon management. Each tool ships as its OWN addon ("AssfishAquarium_<X>"); enabling /
-- disabling one is the Blizzard addon enable state (per character, applied on reload). These
-- wrappers feature-detect C_AddOns (modern) vs the legacy globals so the Hub can list + toggle
-- every tool -- including ones that aren't currently loaded.
--------------------------------------------------------------------------------
core.SUITE_PREFIX = "AssfishAquarium_"

local CA = C_AddOns or {}
local _GetNum      = CA.GetNumAddOns       or GetNumAddOns
local _GetInfo     = CA.GetAddOnInfo       or GetAddOnInfo
local _GetMeta     = CA.GetAddOnMetadata   or GetAddOnMetadata
local _IsLoaded    = CA.IsAddOnLoaded      or IsAddOnLoaded
local _Enable      = CA.EnableAddOn        or EnableAddOn
local _Disable     = CA.DisableAddOn       or DisableAddOn
local _EnableState = CA.GetAddOnEnableState or GetAddOnEnableState

function core.AddonMeta(name, field) return _GetMeta and _GetMeta(name, field) or nil end
function core.AddonLoaded(name) return (_IsLoaded and _IsLoaded(name)) and true or false end

-- Is this addon set to load for THIS character? (0 = disabled, 1/2 = enabled.)
function core.AddonEnabled(name)
	if not _EnableState then return core.AddonLoaded(name) end
	local player = UnitName("player")
	local st = _EnableState(name, player)        -- modern (name, character)
	if type(st) ~= "number" then st = _EnableState(player, name) end -- legacy (character, name)
	return (tonumber(st) or 0) ~= 0
end

function core.SetAddonEnabled(name, on)
	local player = UnitName("player")
	if on then
		if _Enable then pcall(_Enable, name, player) end
	else
		if _Disable then pcall(_Disable, name, player) end
	end
end

-- Iterate every tool addon (name starts with the suite prefix; the Core addon itself has no
-- underscore so it's skipped). fn(name).
function core.EachSuiteAddon(fn)
	local n = (_GetNum and _GetNum()) or 0
	for i = 1, n do
		local name = _GetInfo and _GetInfo(i)
		if name and name:sub(1, #core.SUITE_PREFIX) == core.SUITE_PREFIX then fn(name) end
	end
end

-- First login on a character: seed default addon-enable states ONCE (per-char flag, so we never
-- re-disable something the user later turned back on). Rule: Windfury is useless on Alliance
-- (no Shamans), so default it OFF there.
function core.SeedAddonDefaults()
	if not ns.cdb or ns.cdb.addonSeeded then return end
	ns.cdb.addonSeeded = true
	if UnitFactionGroup("player") == "Alliance" and core.AddonEnabled("AssfishAquarium_Windfury") then
		core.SetAddonEnabled("AssfishAquarium_Windfury", false) -- effective next reload/login
	end
end

-- First-run setup gate + "new module since last visit" tracking, both PER-CHARACTER.
function core.IsSetupDone() return ns.cdb and ns.cdb.setupDone and true or false end
function core.MarkSetupDone() if ns.cdb then ns.cdb.setupDone = true end end

local function seenStore() ns.cdb.seen = ns.cdb.seen or {}; return ns.cdb.seen end
function core.IsNewModule(key) return not seenStore()[key] end
function core.MarkModuleSeen(key) seenStore()[key] = true end
function core.MarkAllSeen()
	core.EachAvailableModule(function(M) seenStore()[M.key] = true end)
	-- also mark installed-but-DISABLED tool addons seen (they never load/register, so the loop
	-- above misses them); their key comes from the TOC. Otherwise their NEW tag never clears.
	core.EachSuiteAddon(function(name)
		local k = core.AddonMeta(name, "X-AAQ-Key")
		if k then seenStore()[k] = true end
	end)
	if core.RefreshMinimap then core.RefreshMinimap() end -- clear the "new" badge
end
function core.CountNewModules()
	local n = 0
	core.EachAvailableModule(function(M) if core.IsNewModule(M.key) then n = n + 1 end end)
	return n
end

function core.SetModuleState(key, state)
	local M = ns.modules[key]
	if not M then return end
	-- Single choke point for every caller (Hub, Settings, StartModules, and the module slash
	-- aliases). Guard the class gate here so e.g. `/bb` on a non-Shaman can't force-enable a
	-- module that's meant to be invisible to that character.
	if not core.IsAvailable(key) then return end
	local prev = core.GetModuleState(key)
	if state == "hidden" then
		-- Tear down on ANY non-hidden -> hidden transition, not only when M._enabled is true: a
		-- partially-failed Enable (events/CLEU/tickers registered, then it errored) leaves
		-- _enabled false but live subs, and this is the only place that cleans them up. The
		-- teardown calls are all idempotent / nil-guarded, so running them is always safe.
		if prev ~= "hidden" then
			core.SafeCall(key .. ":Disable", M.Disable, M)
			core.CancelTickers(key)
			core.UnsubscribeCLEU(key)
			M._enabled = false
		end
	else
		if not M._enabled then
			-- Only mark enabled if Enable actually succeeded (or there's no Enable hook), so a
			-- module whose Enable errored is left consistent and gets retried next time.
			local ok = true
			if M.Enable then ok = core.SafeCall(key .. ":Enable", M.Enable, M) end
			M._enabled = ok and true or false
		end
		if M._enabled then
			core.SafeCall(key .. ":SetDisplayState", M.SetDisplayState, M, state)
		end
		M._lastShown = state -- remember unlocked/locked so re-enabling restores it
	end
	stateStore()[key] = state
	if core.RefreshMinimap then core.RefreshMinimap() end
	if core.RefreshSettingsUI then core.RefreshSettingsUI() end
	if core.RefreshHub then core.RefreshHub() end
end

-- Cycle for the minimap dropdown: hidden -> unlocked -> locked -> hidden.
function core.CycleModuleState(key)
	local s = core.GetModuleState(key)
	local nextState = (s == "hidden" and "unlocked") or (s == "unlocked" and "locked") or "hidden"
	core.SetModuleState(key, nextState)
	return nextState
end

-- Enable/disable as a plain boolean (the Hub + wizard use this). Enabling restores the module's
-- last shown state, or picks a sensible one: framed modules come back UNLOCKED (so they can be
-- positioned), frameless ones LOCKED (just "on"). Locking is a separate concern (SetLocked).
function core.SetEnabled(key, on)
	if on then
		local M = ns.modules[key]
		local want = M and M._lastShown
		if want ~= "unlocked" and want ~= "locked" then
			want = (M and M.hasFrame) and "unlocked" or "locked"
		end
		core.SetModuleState(key, want)
	else
		core.SetModuleState(key, "hidden")
	end
end

-- Lock / unlock an enabled framed module's window (no-op if it's disabled).
function core.SetLocked(key, locked)
	if core.GetModuleState(key) == "hidden" then return end
	core.SetModuleState(key, locked and "locked" or "unlocked")
end

-- Bulk lock/unlock every enabled framed module (the Hub's global config-mode buttons).
function core.SetAllFramesLocked(locked)
	core.EachAvailableModule(function(M)
		if M.hasFrame and core.IsEnabled(M.key) then core.SetLocked(M.key, locked) end
	end)
end

-- Apply saved states to every AVAILABLE module (called by Boot at login). Unavailable
-- modules (wrong class) are left untouched -- never enabled, never shown.
function core.StartModules()
	core.EachAvailableModule(function(M)
		core.SetModuleState(M.key, core.GetModuleState(M.key))
	end)
end
