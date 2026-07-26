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
	The minimap dropdown and the Settings page both drive this via core.SetModuleState.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

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
	-- default may be a boolean OR a function evaluated at first-run seed time (login) -- e.g.
	-- a module that should default on only for a given class checks UnitClass then. nil => true.
	if spec.default == nil then M.default = true else M.default = spec.default end
	M.Enable = spec.Enable
	M.Disable = spec.Disable
	M.SetDisplayState = spec.SetDisplayState
	M.BuildSettings = spec.BuildSettings
	-- available: bool/function -> should this module EXIST for the player at all? An
	-- unavailable module (e.g. Shaman Stuff for a non-Shaman) is registered so its always-on
	-- service still has an M/DB, but it never appears in the minimap, settings, or gets enabled.
	M.available = spec.available -- nil = always available
	return M
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
local function stateStore()
	ns.db.moduleState = ns.db.moduleState or {}
	return ns.db.moduleState
end

function core.GetModuleState(key) -- "hidden" | "unlocked" | "locked"
	local st = stateStore()[key]
	if st == "unlocked" or st == "locked" or st == "hidden" then return st end
	local M = ns.modules[key]
	local def = M and M.default
	if type(def) == "function" then def = def() end -- class-conditional defaults resolve here
	return def and "unlocked" or "hidden" -- seed from default on first run
end

function core.SetModuleState(key, state)
	local M = ns.modules[key]
	if not M then return end
	local prev = core.GetModuleState(key)
	if state == "hidden" then
		if prev ~= "hidden" and M._enabled then
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
	end
	stateStore()[key] = state
	if core.RefreshMinimap then core.RefreshMinimap() end
	if core.RefreshSettingsUI then core.RefreshSettingsUI() end
end

-- Cycle for the minimap dropdown: hidden -> unlocked -> locked -> hidden.
function core.CycleModuleState(key)
	local s = core.GetModuleState(key)
	local nextState = (s == "hidden" and "unlocked") or (s == "unlocked" and "locked") or "hidden"
	core.SetModuleState(key, nextState)
	return nextState
end

-- Apply saved states to every AVAILABLE module (called by Boot at login). Unavailable
-- modules (wrong class) are left untouched -- never enabled, never shown.
function core.StartModules()
	core.EachAvailableModule(function(M)
		core.SetModuleState(M.key, core.GetModuleState(M.key))
	end)
end
