--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Minimap

	The ONE minimap button for the whole bundle (the per-module buttons are dropped).
	  Left-click  : a dropdown, one row per module, each cycling
	                hidden -> unlocked -> locked with its current state shown.
	  Right-click : open the Settings page.
	  Drag        : reposition around the minimap ring (angle saved account-wide).

	A small self-built dropdown is used instead of the soft-deprecated UIDropDownMenu.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core

local RADIUS = 80
local button, dropdown

local STATE_COLOR = {
	hidden   = { 0.6, 0.6, 0.6, "disabled" },
	unlocked = { 1, 0.82, 0, "unlocked" },
	locked   = { 0.4, 1, 0.4, "locked" },
}

local function angleDB()
	ns.db.minimap = ns.db.minimap or {}
	return ns.db.minimap
end

local function placeButton(angle)
	local a = math.rad(angle)
	button:SetPoint("CENTER", Minimap, "CENTER", RADIUS * math.cos(a), RADIUS * math.sin(a))
end

local function onDragUpdate()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local px, py = GetCursorPosition()
	px, py = px / scale, py / scale
	local angle = math.deg(math.atan2(py - my, px - mx))
	angleDB().angle = angle
	placeButton(angle)
end

--------------------------------------------------------------------------------
-- Dropdown
--------------------------------------------------------------------------------
local rows = {}
local ROW_H = 18

local function getRow(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, dropdown)
	r:SetHeight(ROW_H)
	r:SetPoint("LEFT", 8, 0)
	r:SetPoint("RIGHT", -8, 0)
	r.hl = r:CreateTexture(nil, "HIGHLIGHT")
	r.hl:SetAllPoints()
	r.hl:SetColorTexture(1, 1, 1, 0.12)
	r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.label:SetPoint("LEFT", 2, 0)
	r.label:SetJustifyH("LEFT")
	r.state = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.state:SetPoint("RIGHT", -2, 0)
	r.state:SetJustifyH("RIGHT")
	rows[i] = r
	return r
end

local function refreshDropdown()
	if not dropdown then return end
	local i = 0
	core.EachModule(function(M)
		i = i + 1
		local r = getRow(i)
		r:SetPoint("TOPLEFT", dropdown, "TOPLEFT", 8, -8 - (i - 1) * ROW_H)
		r:SetPoint("TOPRIGHT", dropdown, "TOPRIGHT", -8, -8 - (i - 1) * ROW_H)
		r.label:SetText(M.title)
		local s = STATE_COLOR[core.GetModuleState(M.key)] or STATE_COLOR.hidden
		r.state:SetText(s[4])
		r.state:SetTextColor(s[1], s[2], s[3])
		r.key = M.key
		r:SetScript("OnClick", function(self) core.CycleModuleState(self.key) end)
		r:Show()
	end)
	for j = i + 1, #rows do rows[j]:Hide() end
	dropdown:SetHeight(16 + math.max(1, i) * ROW_H)
end

core.RefreshMinimap = refreshDropdown -- Namespace calls this on any state change

local function buildDropdown()
	dropdown = CreateFrame("Frame", "AssfishMinimapDropdown", UIParent, "BackdropTemplate")
	dropdown:SetWidth(150)
	dropdown:SetFrameStrata("FULLSCREEN_DIALOG")
	dropdown:SetClampedToScreen(true)
	dropdown:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	local bg = dropdown:CreateTexture(nil, "BACKGROUND", nil, 1)
	bg:SetPoint("TOPLEFT", 3, -3); bg:SetPoint("BOTTOMRIGHT", -3, 3)
	bg:SetColorTexture(0.03, 0.03, 0.04, 1)
	dropdown:Hide()

	-- Dismiss on a click anywhere outside the menu: a transparent fullscreen catcher sits at a
	-- lower strata (below the dropdown, above the rest of the UI); clicking it closes the menu.
	local catcher = CreateFrame("Button", nil, UIParent)
	catcher:SetAllPoints(UIParent)
	catcher:SetFrameStrata("FULLSCREEN")
	catcher:EnableMouse(true)
	catcher:Hide()
	catcher:SetScript("OnClick", function() dropdown:Hide() end)
	dropdown:SetScript("OnShow", function() catcher:Show() end)
	dropdown:SetScript("OnHide", function() catcher:Hide() end)
end

local function toggleDropdown()
	if not dropdown then buildDropdown() end
	if dropdown:IsShown() then dropdown:Hide(); return end
	dropdown:ClearAllPoints()
	dropdown:SetPoint("TOP", button, "BOTTOM", 0, -2)
	refreshDropdown()
	dropdown:Show()
	dropdown:Raise()
end

--------------------------------------------------------------------------------
function core.BuildMinimap()
	if button then return end
	button = CreateFrame("Button", "AssfishMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetMovable(true)

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\INV_Misc_Fish_24")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", function(_, mbtn)
		if mbtn == "RightButton" then
			if dropdown then dropdown:Hide() end
			core.OpenSettings()
		else
			toggleDropdown()
		end
	end)
	button:SetScript("OnDragStart", function() button:SetScript("OnUpdate", onDragUpdate) end)
	button:SetScript("OnDragStop", function() button:SetScript("OnUpdate", nil) end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("ASSFISH AQUARIUM", 1, 1, 1)
		core.EachModule(function(M)
			local s = STATE_COLOR[core.GetModuleState(M.key)] or STATE_COLOR.hidden
			GameTooltip:AddDoubleLine(M.title, s[4], 0.8, 0.8, 0.8, s[1], s[2], s[3])
		end)
		GameTooltip:AddLine("Left-click: show / lock tools", 0.6, 0.85, 1)
		GameTooltip:AddLine("Right-click: settings", 0.6, 0.85, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	placeButton(angleDB().angle or 200)
end
