--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Lib_Widgets

	Shared option-panel widgets (checkbox, radio row, slider, colour swatch + picker),
	used by the Core Settings pages AND every module's settings canvas. Native-looking,
	built on stock templates (UICheckButtonTemplate / OptionsSliderTemplate) so nothing
	depends on the version-sensitive Settings.RegisterAddOnSetting control API.

	Each factory returns a widget with a :sync() that re-reads its value from get().
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local core = ns.core
local W = {}
core.widgets = W

-- A labelled checkbox reflecting get() and calling set(bool) on click.
function W.check(parent, x, y, label, get, set)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	cb:SetSize(24, 24)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	cb.sync = function() cb:SetChecked(get() and true or false) end
	cb.sync()
	return cb
end

-- A radio-style row: mutually-exclusive check buttons. options = {{text,value},...};
-- get() returns the current value; clicking one calls set(value). Returns { sync = fn }.
function W.radioRow(parent, x, y, labelText, options, get, set)
	local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	lbl:SetPoint("TOPLEFT", x, y - 4)
	lbl:SetText(labelText)
	local btns = {}
	local function refresh()
		local v = get()
		for _, o in ipairs(btns) do o:SetChecked(o.value == v) end
	end
	for i, opt in ipairs(options) do
		local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
		cb:SetPoint("TOPLEFT", x + 82 + (i - 1) * 66, y)
		cb:SetSize(22, 22)
		local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", cb, "RIGHT", 1, 0)
		fs:SetText(opt.text)
		cb.value = opt.value
		cb:SetScript("OnClick", function(self) set(self.value); refresh() end)
		btns[#btns + 1] = cb
	end
	refresh()
	return { sync = refresh }
end

-- A horizontal slider bound to get()/set(number). low..high, stepped. Returns { sync }.
function W.slider(parent, x, y, label, low, high, step, get, set)
	local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	lbl:SetPoint("TOPLEFT", x, y)
	lbl:SetText(label)
	local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
	s:SetPoint("TOPLEFT", x + 2, y - 18)
	s:SetWidth(160)
	s:SetMinMaxValues(low, high)
	s:SetValueStep(step)
	if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
	-- OptionsSliderTemplate wants named _G children for its Low/High/Text; unnamed is fine
	-- if we don't touch them. We set our own edge labels only if the template exposed them.
	s:SetScript("OnValueChanged", function(_, v)
		v = math.floor(v / step + 0.5) * step
		set(v)
	end)
	s.sync = function() s:SetValue(get()) end
	s.sync()
	return s
end

-- Open the standard colour picker seeded with (r,g,b); onChange(r,g,b) fires live.
-- Feature-detects the modern SetupColorPickerAndShow vs the legacy func/cancelFunc API.
function W.showColorPicker(r, g, b, onChange)
	local function applyNow()
		local nr, ng, nb = ColorPickerFrame:GetColorRGB()
		onChange(nr, ng, nb)
	end
	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({
			r = r, g = g, b = b, hasOpacity = false,
			swatchFunc = applyNow,
			cancelFunc = function() onChange(r, g, b) end,
		})
	else
		ColorPickerFrame:Hide()
		ColorPickerFrame.func = applyNow
		ColorPickerFrame.cancelFunc = function() onChange(r, g, b) end
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.previousValues = { r = r, g = g, b = b }
		ColorPickerFrame:SetColorRGB(r, g, b)
		ColorPickerFrame:Show()
	end
end

-- A small square window-header button with the standard mouse-over highlight and an optional
-- GameTooltip. `tex` = an icon texture (pass nil for a bare button you can drop a letter onto).
-- The shared header-button style used across the bundle's module windows.
function W.iconButton(parent, size, tex, tooltip, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size, size)
	if tex then b:SetNormalTexture(tex) end
	b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	if onClick then b:SetScript("OnClick", onClick) end
	if tooltip then
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(tooltip, 1, 1, 1)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	return b
end

-- A clickable colour swatch showing get()'s {r,g,b}; clicking opens the picker and
-- calls set({r,g,b}). Has :sync().
function W.colorSwatch(parent, x, y, get, set)
	local sw = CreateFrame("Button", nil, parent)
	sw:SetSize(18, 18)
	sw:SetPoint("TOPLEFT", x, y)
	local border = sw:CreateTexture(nil, "BACKGROUND")
	border:SetAllPoints()
	border:SetColorTexture(0, 0, 0, 1)
	local tex = sw:CreateTexture(nil, "ARTWORK")
	tex:SetPoint("TOPLEFT", 1, -1)
	tex:SetPoint("BOTTOMRIGHT", -1, 1)
	sw.sync = function() local c = get(); tex:SetColorTexture(c[1], c[2], c[3], 1) end
	sw:SetScript("OnClick", function()
		local c = get()
		W.showColorPicker(c[1], c[2], c[3], function(r, g, b) set({ r, g, b }); sw.sync() end)
	end)
	sw.sync()
	return sw
end
