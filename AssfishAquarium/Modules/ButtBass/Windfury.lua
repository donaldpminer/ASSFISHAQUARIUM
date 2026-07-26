--[[--------------------------------------------------------------------------
	ButtBass - Windfury comms (an ALWAYS-ON SERVICE, not part of the module).

	Reads Windfury weapon-imbue status off TWO addon-message channels:
	  * "WF_STATUS"  - the shared WF Now / WindfuryComm protocol (READ ONLY)
	  * BB_PREFIX    - our own line, which we fully control (READ + SEND)
	We only ever SEND on our own line, so we never risk malforming WF Now's feed;
	but we still SEE everyone running WF Now because we listen on WF_STATUS too.

	This runs for EVERY class and REGARDLESS of the ButtBass module's enable state --
	a non-Shaman (or a Shaman with the ButtBass panels hidden) still broadcasts their
	own WF imbue so other clients can aggregate it. That is why it is a core service:
	  core.RegisterService("windfury", { Start = ... })
	The on/off flag lives in the ButtBass DB slice (db.windfury, default ON); the
	settings checkbox calls M.WF_SetEnabled to start/stop the announcer live.

	Detection uses GetWeaponEnchantInfo (your own weapon only -- you can't read anyone
	else's, which is the whole reason this gossip protocol exists).
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local M = ns.modules.bb

--------------------------------------------------------------------------------
-- Protocol
--------------------------------------------------------------------------------
local BB_PREFIX  = "ButtBassWF"   -- our own channel (send + receive)
local WF_PREFIX  = "WF_STATUS"    -- WF Now / WindfuryComm channel (receive only)
local BB_VER     = 1

-- Windfury Totem weapon-imbue enchant IDs (Classic ranks 1-3). enchid -> rank.
-- Exposed on M so the party frame (WFDisplay.lua) shares this one definition.
local WF_ENCHANTS = { [1783] = 1, [563] = 2, [564] = 3 }
M.WF_ENCHANTS = WF_ENCHANTS

local MIN_SEND_INTERVAL = 0.5     -- throttle refresh broadcasts (state changes bypass it)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
-- M.wf[guid] = { name, class, hasWF, rank, expiresAt, combat, isdead, source, lastSeen }
M.wf = {}

local myGUID
local eventFrame
local pollTicker
local running = false
local prefixesDone = false
local sendPending
local lastSent, lastHasWF, lastEnchid, lastExpire = 0, nil, nil, nil

-- The announcer runs unless db.windfury is explicitly false (default ON).
local function isOn()
	local db = core.GetDB("bb")
	return db.windfury ~= false
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function sendMsg(msg)
	if C_ChatInfo and C_ChatInfo.SendAddonMessage then
		local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
		if channel then C_ChatInfo.SendAddonMessage(BB_PREFIX, msg, channel) end
	end
end

-- Read our own mainhand imbue and broadcast it on OUR line. force = always send.
local function broadcast(force)
	if not running then return end
	if not IsInGroup() then return end
	local now = GetTime()
	local has, expireMs, _, enchid = GetWeaponEnchantInfo()
	local isWF = (has and enchid and WF_ENCHANTS[enchid]) and true or false

	local changed   = (isWF ~= (lastHasWF or false)) or (enchid ~= lastEnchid)
	local refreshed = isWF and (not lastExpire or (expireMs or 0) > lastExpire)
	if force or changed then
		-- send now
	elseif refreshed and (now - lastSent) >= MIN_SEND_INTERVAL then
		-- send now
	else
		return
	end

	local _, _, lagHome = GetNetStats()
	local combat = InCombatLockdown() and "1" or "0"
	local isdead = UnitIsDeadOrGhost("player") and "1" or "0"
	local msg
	if isWF then
		msg = string.format("%s:%d:%d:%d:%s:%s:%d",
			myGUID, enchid, expireMs or 0, lagHome or 0, combat, isdead, BB_VER)
	else
		msg = string.format("%s:nil:nil:%d:%s:%s:%d",
			myGUID, lagHome or 0, combat, isdead, BB_VER)
	end
	sendMsg(msg)
	lastSent, lastHasWF, lastEnchid, lastExpire = now, isWF, enchid, expireMs
end

-- Coalesce bursts of UNIT_INVENTORY_CHANGED into a single broadcast.
local function scheduleBroadcast()
	if sendPending then return end
	sendPending = true
	C_Timer.After(0.15, function() sendPending = false; broadcast(false) end)
end

-- Parse one incoming message (same grammar on both channels) into M.wf.
local function onMessage(prefix, text, source)
	local guid, enchid, expire, lag = strsplit(":", text)
	if not guid or guid == myGUID then return end   -- ignore self / malformed

	local enchNum = tonumber(enchid)                -- "nil" -> nil
	local rank    = enchNum and WF_ENCHANTS[enchNum]
	local rec     = M.wf[guid] or {}

	if rank then
		local ms  = tonumber(expire) or 0
		local lms = tonumber(lag) or 0
		rec.hasWF     = true
		rec.rank      = rank
		-- absolute expiry on our clock, nudged back by ~half the sender's latency
		rec.expiresAt = GetTime() + (ms - lms / 2) / 1000
	else
		rec.hasWF     = false
		rec.rank      = nil
		rec.expiresAt = nil
	end

	-- fill name/class from the GUID (works for anyone the client knows about)
	local _, class, _, _, _, name = GetPlayerInfoByGUID(guid)
	rec.name     = name or rec.name
	rec.class    = class or rec.class
	rec.source   = source
	rec.lastSeen = GetTime()
	M.wf[guid]   = rec

	if M.WF_OnUpdate then M.WF_OnUpdate(guid, rec) end   -- hook for the party frame
end

--------------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------------
local function onEvent(_, event, arg1, arg2)
	if not running then return end
	if event == "CHAT_MSG_ADDON" then
		local prefix, text = arg1, arg2
		if prefix == WF_PREFIX then
			onMessage(prefix, text, "wfnow")
		elseif prefix == BB_PREFIX then
			onMessage(prefix, text, "buttbass")
		end
	elseif event == "UNIT_INVENTORY_CHANGED" then
		scheduleBroadcast()                          -- imbue changed/refreshed
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED"
		or event == "PLAYER_UNGHOST" or event == "PLAYER_ALIVE" or event == "PLAYER_DEAD" then
		broadcast(true)                              -- combat / life-state change
	elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
		broadcast(true)                              -- new members need our current state
	end
end

--------------------------------------------------------------------------------
-- start / stop (live-toggled by the settings checkbox)
--------------------------------------------------------------------------------
local function startAnnouncer()
	if running then return end
	running = true
	myGUID = UnitGUID("player")

	if not prefixesDone and C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		C_ChatInfo.RegisterAddonMessagePrefix(WF_PREFIX)   -- required to RECEIVE these
		C_ChatInfo.RegisterAddonMessagePrefix(BB_PREFIX)
		prefixesDone = true
	end

	if not eventFrame then
		eventFrame = CreateFrame("Frame")
		eventFrame:SetScript("OnEvent", onEvent)
	end
	eventFrame:RegisterEvent("CHAT_MSG_ADDON")
	eventFrame:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")  -- imbue changes, player only
	eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
	eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	eventFrame:RegisterEvent("PLAYER_DEAD")
	eventFrame:RegisterEvent("PLAYER_ALIVE")
	eventFrame:RegisterEvent("PLAYER_UNGHOST")
	eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

	-- Poll every 1s. UNIT_INVENTORY_CHANGED does NOT fire reliably for temporary
	-- weapon enchants (the Windfury imbue), so -- like WF Now -- we also poll and let
	-- broadcast() decide if the state actually changed. Every ~4s we force-resend an
	-- active WF so a party member who joined mid-fight (and missed our event-driven
	-- broadcast) still picks it up. A service is not tied to the module ticker set, so
	-- this uses C_Timer directly and keeps the handle to cancel on stop.
	local hb = 0
	pollTicker = C_Timer.NewTicker(1, function()
		hb = (hb + 1) % 4
		if hb == 0 then
			local has, _, _, enchid = GetWeaponEnchantInfo()
			if has and enchid and WF_ENCHANTS[enchid] then broadcast(true); return end
		end
		broadcast(false)
	end)

	broadcast(true)   -- announce our current state
end

local function stopAnnouncer()
	if not running then return end
	running = false
	if pollTicker then pollTicker:Cancel(); pollTicker = nil end
	if eventFrame then eventFrame:UnregisterAllEvents() end
	lastSent, lastHasWF, lastEnchid, lastExpire = 0, nil, nil, nil
end

-- Called by the settings "Windfury announcements" checkbox to flip the flag + apply live.
function M.WF_SetEnabled(on)
	core.GetDB("bb").windfury = on and true or false
	if on then startAnnouncer() else stopAnnouncer() end
end

-- Snapshot of currently-known WF, freshest first (for /bb wf and the party frame).
-- Also prunes entries not heard from in a while, so M.wf can't grow without bound
-- across a long session of PUGs (and /bb wf stops listing players who left).
local STALE_TTL = 120
function M.WF_GetAll()
	local now, out = GetTime(), {}
	for guid, rec in pairs(M.wf) do
		if rec.lastSeen and (now - rec.lastSeen) > STALE_TTL then
			M.wf[guid] = nil   -- safe: setting an existing field to nil during pairs()
		else
			out[#out + 1] = {
				guid = guid, name = rec.name, class = rec.class, source = rec.source,
				hasWF = rec.hasWF, rank = rec.rank,
				remaining = rec.expiresAt and math.max(0, rec.expiresAt - now) or 0,
				combat = rec.combat, lastSeen = rec.lastSeen,
			}
		end
	end
	table.sort(out, function(a, b) return (a.remaining or 0) > (b.remaining or 0) end)
	return out
end

--------------------------------------------------------------------------------
-- service registration (core.StartServices calls Start once at login)
--------------------------------------------------------------------------------
core.RegisterService("windfury", {
	Start = function()
		if isOn() then startAnnouncer() end
	end,
})
