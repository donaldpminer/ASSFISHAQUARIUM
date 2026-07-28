--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Onboarding

	First-run setup wizard. Because nothing auto-enables (opt-in, per character), the
	first time a character logs in we ask which tools to turn on instead of dumping
	everything on screen. Re-runnable any time from the Hub's "Setup" button or
	`/aq setup`.

	Selections are staged in `picked` (so scrolling/presets don't lose them) and only
	applied via core.SetEnabled when the user confirms.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core

local WIDTH   = 460
local ROW_H   = 40
local VISIBLE  = 7
local LIST_TOP = 96
local BOTPAD   = 44

local WIZ_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 14,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local frame, rows
local offset = 0
local picked = {}   -- key -> bool (staged selection)

local function eachAvail(fn) core.EachAvailableModule(fn) end

local function availList()
	local out = {}
	eachAvail(function(M) out[#out + 1] = M end)
	return out
end

-- ------------------------------------------------------------- rows --

local function makeRow(i)
	local r = CreateFrame("Frame", nil, frame)
	r:SetSize(WIDTH - 24, ROW_H - 4)

	local bg = r:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.04)

	local cb = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
	cb:SetSize(26, 26)
	cb:SetPoint("LEFT", 4, 0)
	cb:SetScript("OnClick", function(self) picked[r.key] = self:GetChecked() and true or false end)
	r.cb = cb

	local name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	name:SetPoint("TOPLEFT", cb, "TOPRIGHT", 6, -1)
	name:SetJustifyH("LEFT")
	r.name = name

	local rec = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	rec:SetPoint("LEFT", name, "RIGHT", 6, 0)
	rec:SetText("recommended")
	rec:SetTextColor(0.5, 0.8, 1)
	r.rec = rec

	local desc = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	desc:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
	desc:SetPoint("RIGHT", r, "RIGHT", -8, 0)
	desc:SetJustifyH("LEFT")
	desc:SetWordWrap(false)
	r.desc = desc

	rows[i] = r
	return r
end

local function fillRow(r, M)
	r.key = M.key
	r.cb:SetChecked(picked[M.key] and true or false)
	r.name:SetText(M.title)
	r.rec:SetShown(core.IsRecommended(M.key))
	local d = M.desc or ""
	if M.source == "adopted" and M.adoptedFrom then
		d = (d ~= "" and (d .. "  ") or "") .. "|cff888888(" .. M.adoptedFrom .. ")|r"
	end
	r.desc:SetText(d)
	r:Show()
end

local function render()
	if not frame then return end
	local list = availList()
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
	frame.scrollHint:SetShown(#list > VISIBLE)
	if #list > VISIBLE then
		frame.scrollHint:SetText(string.format("%d-%d of %d  (scroll)", offset + 1,
			math.min(offset + VISIBLE, #list), #list))
	end
end

local function scroll(step)
	local list = availList()
	local maxOffset = math.max(0, #list - VISIBLE)
	offset = offset + step
	if offset < 0 then offset = 0 elseif offset > maxOffset then offset = maxOffset end
	render()
end

-- ------------------------------------------------------------- build --

local function build()
	if frame then return end
	rows = {}

	frame = CreateFrame("Frame", "AssfishSetupFrame", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, LIST_TOP + VISIBLE * ROW_H + BOTPAD)
	frame:SetPoint("CENTER")
	frame:SetBackdrop(WIZ_BACKDROP)
	frame:SetBackdropColor(0.05, 0.05, 0.07, 0.98)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta) scroll(-delta) end)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -14)
	title:SetText("Welcome to ASSFISH AQUARIUM")
	title:SetTextColor(1, 0.82, 0)

	local sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", 16, -40)
	sub:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	sub:SetJustifyH("LEFT")
	sub:SetText("Pick the tools to turn on for this character. Change them any time: left-click the minimap button, or /aq.")

	-- preset buttons
	local function preset(x, label, w, fn)
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetSize(w, 20)
		b:SetPoint("TOPLEFT", x, -68)
		b:SetText(label)
		b:SetScript("OnClick", function() fn(); render() end)
		return b
	end
	preset(14, "Recommended", 96, function()
		eachAvail(function(M) picked[M.key] = core.IsRecommended(M.key) end)
	end)
	preset(114, "Everything", 90, function()
		eachAvail(function(M) picked[M.key] = true end)
	end)
	preset(208, "None", 60, function()
		eachAvail(function(M) picked[M.key] = false end)
	end)

	frame.scrollHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.scrollHint:SetPoint("BOTTOM", 0, 32)
	frame.scrollHint:Hide()

	-- confirm / skip
	local apply = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	apply:SetSize(150, 24)
	apply:SetPoint("BOTTOMRIGHT", -14, 12)
	apply:SetText("Enable selected")
	apply:SetScript("OnClick", function()
		eachAvail(function(M) core.SetEnabled(M.key, picked[M.key] and true or false) end)
		core.MarkSetupDone()
		core.MarkAllSeen()
		frame:Hide()
		print("|cffffd200ASSFISH AQUARIUM|r: setup saved. Left-click the minimap button (or /aq) to manage tools.")
		if core.ShowHub then core.ShowHub() end
	end)

	local skip = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	skip:SetSize(80, 24)
	skip:SetPoint("BOTTOMLEFT", 14, 12)
	skip:SetText("Skip")
	skip:SetScript("OnClick", function()
		core.MarkSetupDone()
		core.MarkAllSeen()
		frame:Hide()
	end)
end

-- Seed staged selections: on first run use the recommendations; on a re-run reflect what's
-- currently enabled so the wizard is non-destructive to review/tweak.
local function seedPicks()
	local firstRun = not core.IsSetupDone()
	eachAvail(function(M)
		picked[M.key] = firstRun and core.IsRecommended(M.key) or core.IsEnabled(M.key)
	end)
end

-- Show the wizard. force=true from the Setup button; otherwise only meaningful on first run.
function core.ShowOnboarding(force)
	build()
	offset = 0
	seedPicks()
	frame:Show()
	render()
end

-- Called by Boot at login: show the wizard once per character (unless already set up).
-- On subsequent logins we do NOT mark modules seen -- that's what keeps a newly-added
-- (post-update) tool flagged "new" until the user actually opens the Hub.
function core.MaybeShowOnboarding()
	if core.IsSetupDone() then return end
	core.ShowOnboarding(false)
end
