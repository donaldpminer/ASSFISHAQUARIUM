--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Minimap

	The ONE minimap button for the whole bundle.
	  Left-click  : open the Hub (manage all tools).
	  Right-click : open the full Settings panel.
	  Drag        : reposition around the minimap ring (angle saved account-wide).

	The old left-click "cycle each module through hidden/unlocked/locked" dropdown is
	gone -- it didn't scale past a few tools. Management lives in the Hub now; the
	button's job is just to open it. A small badge shows how many newly-added tools
	you haven't looked at yet.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core

local RADIUS = 80
local button, badge

local STATE_LABEL = {
	hidden   = { 0.6, 0.6, 0.6, "off" },
	unlocked = { 1, 0.82, 0, "on (unlocked)" },
	locked   = { 0.4, 1, 0.4, "on (locked)" },
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

-- Badge: number of newly-registered tools not yet seen in the Hub/wizard.
local function refreshBadge()
	if not badge then return end
	local n = core.CountNewModules and core.CountNewModules() or 0
	if n > 0 then
		badge.text:SetText(n > 9 and "9+" or tostring(n))
		badge:Show()
	else
		badge:Hide()
	end
end
core.RefreshMinimap = refreshBadge -- Namespace calls this on any state change

local function showTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("ASSFISH AQUARIUM", 1, 1, 1)
	core.EachAvailableModule(function(M)
		local s = STATE_LABEL[core.GetModuleState(M.key)] or STATE_LABEL.hidden
		local label = M.title
		if core.IsNewModule and core.IsNewModule(M.key) then label = label .. " |cff40ff40(new)|r" end
		GameTooltip:AddDoubleLine(label, s[4], 0.8, 0.8, 0.8, s[1], s[2], s[3])
	end)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Left-click: manage tools (Hub)", 0.6, 0.85, 1)
	GameTooltip:AddLine("Right-click: settings", 0.6, 0.85, 1)
	GameTooltip:Show()
end

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

	-- "new tools" badge (bottom-right of the icon)
	badge = CreateFrame("Frame", nil, button)
	badge:SetSize(16, 16)
	badge:SetPoint("BOTTOMRIGHT", 2, -2)
	badge:SetFrameLevel(button:GetFrameLevel() + 2)
	local bt = badge:CreateTexture(nil, "BACKGROUND")
	bt:SetAllPoints()
	bt:SetColorTexture(0.8, 0.1, 0.1, 1)
	badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	badge.text:SetPoint("CENTER")
	badge.text:SetText("")
	badge:Hide()

	button:SetScript("OnClick", function(_, mbtn)
		if mbtn == "RightButton" then
			core.OpenSettings()
		else
			core.ToggleHub()
		end
	end)
	button:SetScript("OnDragStart", function() button:SetScript("OnUpdate", onDragUpdate) end)
	button:SetScript("OnDragStop", function() button:SetScript("OnUpdate", nil) end)
	button:SetScript("OnEnter", showTooltip)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	placeButton(angleDB().angle or 200)
	refreshBadge()
end
