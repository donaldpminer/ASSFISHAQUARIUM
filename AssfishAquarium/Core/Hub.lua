--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Hub

	The management dashboard. Each tool is now its OWN addon ("AssfishAquarium_<X>"),
	so the Hub lists every suite addon -- loaded or not -- and its Enabled checkbox
	drives the Blizzard addon enable state (core.SetAddonEnabled), which takes effect
	on RELOAD. A reload bar appears while a change is pending. Lock / unlock and the
	settings gear act on LOADED modules live (no reload needed for those).

	Opened by the minimap left-click and `/aq` (also `/aq hub`).
----------------------------------------------------------------------------]]

local ns = AssfishAquarium
local core = ns.core
local W = core.widgets

local WIDTH    = 470
local NAME_H   = 16          -- approx height of the name line
local DESC_W   = 332         -- fixed desc width so it wraps (leaves room for the right controls)
local ROWGAP   = 4           -- vertical gap between rows
local LIST_TOP = 104         -- y of the first row
local LIST_H   = 336         -- height of the scrollable list area
local BOTPAD   = 52          -- room for the reload bar / hint below the list

local HUB_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 14,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local frame, rows, listMsg
local offset = 0
local searchText = ""

-- ------------------------------------------------------------- data --

-- Every suite addon as a display item {addon,title,desc,cat,key,enabled,loaded}, search-filtered.
local function suiteList()
	local out = {}
	local q = searchText
	core.EachSuiteAddon(function(name)
		local adopted = core.ADOPTED[name]        -- third-party addon we bundle (manifest)
		local title = core.AddonMeta(name, "Title") or name
		local desc  = (adopted and adopted.desc) or core.AddonMeta(name, "Notes") or ""
		local cat   = (adopted and adopted.hubCategory) or core.AddonMeta(name, "X-AAQ-HubCategory") or "Other"
		local key   = core.AddonMeta(name, "X-AAQ-Key")
		if q ~= "" and not (title .. " " .. desc .. " " .. cat):lower():find(q, 1, true) then return end
		out[#out + 1] = {
			addon = name, title = title, desc = desc, cat = cat, key = key,
			source = adopted and "adopted" or "mine",
			enabled = core.AddonEnabled(name), loaded = core.AddonLoaded(name),
		}
	end)
	table.sort(out, function(a, b) return a.title < b.title end)
	return out
end

-- A suite addon is "pending" when its enable state no longer matches what's loaded this session.
local function anyPending()
	local pending = false
	core.EachSuiteAddon(function(name)
		if core.AddonEnabled(name) ~= core.AddonLoaded(name) then pending = true end
	end)
	return pending
end

-- --------------------------------------------------------------- a row --

local function makeRow(i)
	local r = CreateFrame("Frame", nil, frame)
	r:SetSize(WIDTH - 24, 40) -- height is recomputed per content in fillRow

	local bg = r:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.04)

	-- enabled checkbox -> Blizzard addon enable state (reload to apply); top-aligned
	local en = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
	en:SetSize(24, 24)
	en:SetPoint("TOPLEFT", 2, -2)
	en:SetScript("OnClick", function(self)
		core.SetAddonEnabled(r.addon, self:GetChecked() and true or false)
		core.RefreshHub()
	end)
	r.enabled = en

	-- right-side controls sit on the top (name) line, not the row's vertical center
	local dot = r:CreateTexture(nil, "OVERLAY")
	dot:SetSize(10, 10)
	dot:SetPoint("TOPRIGHT", -4, -10)
	dot:SetColorTexture(0.4, 0.4, 0.4, 1)
	r.dot = dot

	local gear = W.gearButton(r, 16, "Open this tool's settings", function()
		if r.key then core.OpenModuleSettings(r.key) end
	end)
	gear:SetPoint("RIGHT", dot, "LEFT", -8, 0)
	r.gear = gear

	local lock = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
	lock:SetSize(20, 20)
	lock:SetPoint("RIGHT", gear, "LEFT", -6, 0)
	lock:SetScript("OnClick", function(self)
		if r.key then core.SetLocked(r.key, self:GetChecked() and true or false); core.RefreshHub() end
	end)
	lock:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self:GetChecked() and "Locked -- click to unlock/move" or "Unlocked (movable) -- click to lock", 1, 1, 1)
		GameTooltip:Show()
	end)
	lock:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r.lock = lock

	local name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	name:SetPoint("TOPLEFT", en, "TOPRIGHT", 4, -2)
	name:SetJustifyH("LEFT")
	r.name = name

	local newtag = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	newtag:SetPoint("LEFT", name, "RIGHT", 6, 0)
	newtag:SetText("NEW")
	newtag:SetTextColor(0.4, 1, 0.4)
	r.newtag = newtag

	-- fixed width + wrap so a long description flows onto multiple lines
	local desc = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	desc:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
	desc:SetWidth(DESC_W)
	desc:SetJustifyH("LEFT")
	desc:SetWordWrap(true)
	r.desc = desc

	rows[i] = r
	return r
end

local function fillRow(r, item)
	r.addon = item.addon
	r.key = item.key
	local pending = (item.enabled ~= item.loaded)
	local avail = (not item.key) or core.IsAvailable(item.key) -- class gate (e.g. Shaman Stuff)

	r.enabled:SetChecked(item.enabled)
	-- adopted third-party addons carry a plain "(Adopted)" after the name
	r.name:SetText(item.source == "adopted" and (item.title .. " |cff888888(Adopted)|r") or item.title)
	local bright = item.enabled and avail
	r.name:SetTextColor(bright and 1 or 0.55, bright and 0.82 or 0.55, bright and 0 or 0.55)
	r.newtag:SetShown(item.key and core.IsNewModule(item.key) or false)
	r.desc:SetText(item.desc or "")

	-- lock + gear only for a loaded, AVAILABLE, framed module (a class-gated module loaded on
	-- the wrong class registers an M but never activates, so its controls would be dead).
	local M = (item.key and item.loaded and avail) and ns.modules[item.key] or nil
	if M and M.hasFrame then
		r.lock:Show()
		r.lock:SetChecked(core.GetModuleState(item.key) == "locked")
	else
		r.lock:Hide()
	end
	r.gear:SetShown(M and true or false)

	if pending then
		r.dot:SetColorTexture(1, 0.8, 0.2)             -- toggled, needs reload
	elseif item.loaded and avail then
		r.dot:SetColorTexture(0.3, 0.9, 0.3)           -- on
	else
		r.dot:SetColorTexture(0.4, 0.4, 0.4)           -- off / loaded-but-not-for-this-class
	end

	-- dynamic height = name line + the wrapped description
	local descH = (item.desc and item.desc ~= "") and r.desc:GetStringHeight() or 0
	r._h = 6 + NAME_H + (descH > 0 and (3 + descH) or 0) + 6
	if r._h < 30 then r._h = 30 end
	r:SetHeight(r._h)
	r:Show()
end

-- ------------------------------------------------------------- rendering --

function core.RefreshHub()
	if not (frame and frame:IsShown()) then return end
	local list = suiteList()
	local total, on = 0, 0
	core.EachSuiteAddon(function(name)
		total = total + 1
		if core.AddonEnabled(name) then on = on + 1 end
	end)
	frame.subtitle:SetText(string.format("%d of %d tools enabled", on, total))

	if offset > #list - 1 then offset = math.max(0, #list - 1) end
	if offset < 0 then offset = 0 end

	-- stack rows by their actual heights, starting at `offset`, until the list area is full
	local y, shown = 0, 0
	for idx = offset + 1, #list do
		local r = rows[shown + 1] or makeRow(shown + 1)
		fillRow(r, list[idx]) -- sets r._h
		if shown > 0 and (y + r._h) > LIST_H then r:Hide(); break end
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -(LIST_TOP + y))
		r:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
		y = y + r._h + ROWGAP
		shown = shown + 1
	end
	for j = shown + 1, #rows do rows[j]:Hide() end

	listMsg:SetShown(#list == 0)
	frame.reloadBar:SetShown(anyPending())
	local clipped = (offset > 0) or ((offset + shown) < #list)
	frame.scrollHint:SetShown(clipped and not anyPending())
	if clipped then
		frame.scrollHint:SetText(string.format("%d-%d of %d  (scroll)", offset + 1, offset + shown, #list))
	end
end

local function scroll(step)
	local list = suiteList()
	offset = offset + step
	if offset < 0 then offset = 0 elseif offset > #list - 1 then offset = math.max(0, #list - 1) end
	core.RefreshHub()
end

-- ----------------------------------------------------------------- build --

local function build()
	if frame then return end
	rows = {}

	frame = CreateFrame("Frame", "AssfishHubFrame", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, LIST_TOP + LIST_H + BOTPAD)
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
	tinsert(UISpecialFrames, "AssfishHubFrame")

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -12)
	title:SetText("ASSFISH AQUARIUM")
	title:SetTextColor(1, 0.82, 0)

	frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.subtitle:SetPoint("TOPLEFT", 16, -34)
	frame.subtitle:SetText("")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

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

	-- global action buttons
	local function actionBtn(x, label, w, onClick, tip)
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetSize(w, 20)
		b:SetPoint("TOPLEFT", x, -62)
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
		"Show + move every loaded window")
	actionBtn(118, "Lock frames", 90, function() core.SetAllFramesLocked(true) end,
		"Pin every loaded window in place")
	actionBtn(292, "Settings", 90, function() core.OpenSettings() end,
		"Open the full settings panel")

	listMsg = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	listMsg:SetPoint("CENTER", 0, -20)
	listMsg:SetText("No tools found.")
	listMsg:SetTextColor(0.6, 0.6, 0.6)
	listMsg:Hide()

	frame.scrollHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.scrollHint:SetPoint("BOTTOM", 0, 8)
	frame.scrollHint:Hide()

	-- reload bar: appears once an enable/disable is pending (takes effect on reload)
	local bar = CreateFrame("Frame", nil, frame)
	bar:SetPoint("BOTTOMLEFT", 8, 6)
	bar:SetPoint("BOTTOMRIGHT", -8, 6)
	bar:SetHeight(28)
	local bt = bar:CreateTexture(nil, "BACKGROUND")
	bt:SetAllPoints(); bt:SetColorTexture(0.5, 0.4, 0.05, 0.6)
	local btext = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	btext:SetPoint("LEFT", 8, 0)
	btext:SetText("|cffffd200Reload to apply your changes|r")
	local rl = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
	rl:SetSize(110, 22); rl:SetPoint("RIGHT", -4, 0); rl:SetText("Reload UI")
	rl:SetScript("OnClick", function() ReloadUI() end)
	bar:Hide()
	frame.reloadBar = bar

	frame:Hide()
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
