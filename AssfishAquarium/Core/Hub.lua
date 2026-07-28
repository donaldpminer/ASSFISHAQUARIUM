--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Hub

	The management dashboard: one window that lists every available module as a row
	you can toggle on/off, lock/unlock (framed modules), and jump into settings for.
	This replaces the old cycle-through-a-dropdown minimap menu as the primary way to
	manage the bundle -- it scales to many adopted addons via search + a source filter.

	Opened by the minimap left-click and `/aq` (also `/aq hub`). Rebuilt live whenever
	module state changes (core.RefreshHub, called from SetModuleState).

	Reuses the tri-state under the hood (core.SetEnabled / core.SetLocked) so nothing
	about the lifecycle changes -- the Hub is just a nicer face on it.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local W = core.widgets

local WIDTH    = 470
local ROW_H    = 42
local VISIBLE  = 8          -- rows shown before the list scrolls
local LIST_TOP = 132        -- y of the first row below the header/search/filters/actions
local BOTPAD   = 26

local HUB_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 14,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local frame, rows, listMsg
local offset = 0
local filterSource = "all"   -- all | mine | adopted
local searchText = ""

-- ------------------------------------------------------------- filtering --

-- The modules that pass the current source filter + search, in registration order.
local function filtered()
	local out = {}
	local q = searchText
	core.EachAvailableModule(function(M)
		if filterSource == "mine" and M.source ~= "mine" then return end
		if filterSource == "adopted" and M.source ~= "adopted" then return end
		if q ~= "" then
			local hay = (M.title .. " " .. (M.desc or "") .. " " .. (M.category or "")
				.. " " .. (M.adoptedFrom or "")):lower()
			if not hay:find(q, 1, true) then return end
		end
		out[#out + 1] = M
	end)
	return out
end

-- --------------------------------------------------------------- a row --

local function makeRow(i)
	local r = CreateFrame("Frame", nil, frame)
	r:SetSize(WIDTH - 24, ROW_H - 4)

	local bg = r:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.04)
	r.bg = bg

	-- enabled checkbox (left)
	local en = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
	en:SetSize(24, 24)
	en:SetPoint("LEFT", 4, 0)
	en:SetScript("OnClick", function(self) core.SetEnabled(r.key, self:GetChecked() and true or false) end)
	en:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self:GetChecked() and "Enabled -- click to turn off" or "Disabled -- click to turn on", 1, 1, 1)
		GameTooltip:Show()
	end)
	en:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r.enabled = en

	-- status dot (far right)
	local dot = r:CreateTexture(nil, "OVERLAY")
	dot:SetSize(10, 10)
	dot:SetPoint("RIGHT", -4, 0)
	dot:SetColorTexture(0.4, 0.4, 0.4, 1)
	r.dot = dot

	-- config gear (left of the dot)
	local gear = W.gearButton(r, 16, "Open this tool's settings", function() core.OpenModuleSettings(r.key) end)
	gear:SetPoint("RIGHT", dot, "LEFT", -8, 0)
	r.gear = gear

	-- lock toggle (left of the gear; only for framed + enabled modules)
	local lock = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
	lock:SetSize(20, 20)
	lock:SetPoint("RIGHT", gear, "LEFT", -6, 0)
	lock:SetScript("OnClick", function(self) core.SetLocked(r.key, self:GetChecked() and true or false) end)
	lock:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self:GetChecked() and "Locked -- click to unlock/move" or "Unlocked (movable) -- click to lock", 1, 1, 1)
		GameTooltip:Show()
	end)
	lock:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r.lock = lock

	-- name (top line) + a "New" tag
	local name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	name:SetPoint("TOPLEFT", en, "TOPRIGHT", 4, -1)
	name:SetJustifyH("LEFT")
	r.name = name

	local newtag = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	newtag:SetPoint("LEFT", name, "RIGHT", 6, 0)
	newtag:SetText("NEW")
	newtag:SetTextColor(0.4, 1, 0.4)
	r.newtag = newtag

	-- description + credit (second line)
	local desc = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	desc:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
	desc:SetPoint("RIGHT", lock, "LEFT", -8, 0)
	desc:SetJustifyH("LEFT")
	desc:SetWordWrap(false)
	r.desc = desc

	rows[i] = r
	return r
end

local function statusColor(M)
	local enabled = core.IsEnabled(M.key)
	if enabled and M._enabled == false then return 0.9, 0.3, 0.3 end -- errored (Enable failed)
	if enabled then return 0.3, 0.9, 0.3 end
	return 0.4, 0.4, 0.4
end

local function fillRow(r, M)
	r.key = M.key
	local enabled = core.IsEnabled(M.key)

	r.enabled:SetChecked(enabled)
	r.name:SetText(M.title)
	r.name:SetTextColor(enabled and 1 or 0.7, enabled and 0.82 or 0.7, enabled and 0 or 0.7)
	r.newtag:SetShown(core.IsNewModule(M.key))

	-- description line, with an adopted-from credit appended
	local d = M.desc or ""
	if M.source == "adopted" and M.adoptedFrom then
		d = (d ~= "" and (d .. "  ") or "") .. "|cff888888(adopted: " .. M.adoptedFrom
			.. (M.author and (" by " .. M.author) or "") .. ")|r"
	elseif M.category and M.category ~= "Other" then
		d = (d ~= "" and (d .. "  ") or "") .. "|cff666666" .. M.category .. "|r"
	end
	r.desc:SetText(d)

	-- lock toggle only meaningful for an enabled, framed module
	if M.hasFrame and enabled then
		r.lock:Show()
		r.lock:SetChecked(core.GetModuleState(M.key) == "locked")
	else
		r.lock:Hide()
	end

	r.dot:SetColorTexture(statusColor(M))
	r:Show()
end

-- ------------------------------------------------------------- rendering --

function core.RefreshHub()
	if not (frame and frame:IsShown()) then return end
	local list = filtered()
	local total, enabledCount = 0, 0
	core.EachAvailableModule(function(M)
		total = total + 1
		if core.IsEnabled(M.key) then enabledCount = enabledCount + 1 end
	end)
	frame.subtitle:SetText(string.format("%d of %d tools enabled", enabledCount, total))

	local maxOffset = math.max(0, #list - VISIBLE)
	if offset > maxOffset then offset = maxOffset end
	if offset < 0 then offset = 0 end

	for i = 1, VISIBLE do
		local M = list[offset + i]
		local r = rows[i] or makeRow(i)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -(LIST_TOP + (i - 1) * ROW_H))
		r:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
		if M then fillRow(r, M) else r:Hide() end
	end

	listMsg:SetShown(#list == 0)
	frame.scrollHint:SetShown(#list > VISIBLE)
	if #list > VISIBLE then
		frame.scrollHint:SetText(string.format("%d-%d of %d  (scroll)", offset + 1,
			math.min(offset + VISIBLE, #list), #list))
	end
end

local function scroll(step)
	local list = filtered()
	local maxOffset = math.max(0, #list - VISIBLE)
	offset = offset + step
	if offset < 0 then offset = 0 elseif offset > maxOffset then offset = maxOffset end
	core.RefreshHub()
end

-- ----------------------------------------------------------------- build --

local function sourceTab(parent, x, label, value)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(70, 20)
	b:SetPoint("TOPLEFT", x, -60)
	b:SetText(label)
	b:SetScript("OnClick", function()
		filterSource = value
		offset = 0
		parent.updateTabs()
		core.RefreshHub()
	end)
	b.value = value
	return b
end

local function build()
	if frame then return end
	rows = {}

	frame = CreateFrame("Frame", "AssfishHubFrame", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, LIST_TOP + VISIBLE * ROW_H + BOTPAD)
	frame:SetPoint("CENTER")
	frame:SetBackdrop(HUB_BACKDROP)
	frame:SetBackdropColor(0.05, 0.05, 0.07, 0.96)
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta) scroll(-delta) end)
	tinsert(UISpecialFrames, "AssfishHubFrame") -- close with Escape

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -12)
	title:SetText("ASSFISH AQUARIUM")
	title:SetTextColor(1, 0.82, 0)

	frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.subtitle:SetPoint("TOPLEFT", 16, -34)
	frame.subtitle:SetText("")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	-- search box
	local search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	search:SetSize(180, 20)
	search:SetPoint("TOPRIGHT", -28, -32)
	search:SetAutoFocus(false)
	search:SetScript("OnTextChanged", function(self)
		searchText = (self:GetText() or ""):lower()
		offset = 0
		core.RefreshHub()
	end)
	search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
	local slabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	slabel:SetPoint("RIGHT", search, "LEFT", -4, 0)
	slabel:SetText("Search")

	-- source filter tabs
	local tabs = {}
	tabs[#tabs + 1] = sourceTab(frame, 14, "All", "all")
	tabs[#tabs + 1] = sourceTab(frame, 88, "Mine", "mine")
	tabs[#tabs + 1] = sourceTab(frame, 162, "Adopted", "adopted")
	frame.updateTabs = function()
		for _, b in ipairs(tabs) do
			if b.value == filterSource then b:LockHighlight() else b:UnlockHighlight() end
		end
	end
	frame.updateTabs()

	-- global action buttons
	local function actionBtn(x, label, w, onClick, tip)
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetSize(w, 20)
		b:SetPoint("TOPLEFT", x, -90)
		b:SetText(label)
		b:SetScript("OnClick", onClick)
		if tip then
			b:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(tip, 1, 1, 1); GameTooltip:Show()
			end)
			b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
		return b
	end
	actionBtn(14, "Unlock frames", 100, function() core.SetAllFramesLocked(false) end,
		"Show + move every enabled window")
	actionBtn(118, "Lock frames", 90, function() core.SetAllFramesLocked(true) end,
		"Pin every enabled window in place")
	actionBtn(212, "Setup", 70, function() if core.ShowOnboarding then core.ShowOnboarding(true) end end,
		"Re-run the first-time setup")
	actionBtn(286, "Settings", 90, function() core.OpenSettings() end,
		"Open the full settings panel")

	-- empty-list message + scroll hint
	listMsg = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	listMsg:SetPoint("CENTER", 0, -20)
	listMsg:SetText("No tools match.")
	listMsg:SetTextColor(0.6, 0.6, 0.6)
	listMsg:Hide()

	frame.scrollHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.scrollHint:SetPoint("BOTTOM", 0, 8)
	frame.scrollHint:Hide()

	-- Start hidden (frames are shown by default) BEFORE wiring OnHide, so this initial hide
	-- doesn't fire it. "New" flags clear when the window CLOSES (any path: button, Escape,
	-- toggle) -- that keeps the NEW tags visible the whole time you're looking at the Hub.
	frame:Hide()
	-- Only treat this as a genuine close (not an ancestor hide like Alt-Z / a cinematic, which
	-- also fires OnHide) -- otherwise the NEW flags would clear while the Hub is still "open".
	frame:SetScript("OnHide", function() if UIParent:IsShown() then core.MarkAllSeen() end end)
end

function core.ShowHub()
	build()
	frame:Show()
	core.RefreshHub()
end

function core.ToggleHub()
	build()
	if frame:IsShown() then frame:Hide() else core.ShowHub() end
end

function core.HideHub()
	if frame then frame:Hide() end
end
