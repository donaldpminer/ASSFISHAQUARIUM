--[[--------------------------------------------------------------------------
	Target Frame+ - Settings

	Native Settings subcategory: global sizes (with a live numeric value + Small/Large
	ends), then the category section -- gated entirely by "Sort auras by category":
	when that's off, the sort orders, size percents, and the raid-aura checklist all
	grey out (and the target frame uses one uniform size). Reset sits off in the top
	corner. Everything calls touch() so the target frame updates live.
----------------------------------------------------------------------------]]

local ns = AssfishAquarium
local core = ns.core
local W = core.widgets
local M = ns.modules.utf

local function d() return M.db end
local derivedRefresh -- refreshes computed labels (e.g. the row-width "N auras" count)
local function touch()
	if M.Refresh then M.Refresh() end
	if derivedRefresh then derivedRefresh() end
end

local ORDER_OPTS = { { text = "1st", value = 1 }, { text = "2nd", value = 2 }, { text = "3rd", value = 3 } }
local ORDER_FIELD = { raid = "catRaidOrder", class = "catClassOrder", other = "catOtherOrder" }

-- A size slider that shows its numeric value and reads "Small"/"Large" at the ends.
local function sizeSlider(panel, x, y, label, low, high, step, get, set)
	local val
	local s = W.slider(panel, x, y, label, low, high, step, get, function(v)
		set(v)
		if val then val:SetText(tostring(v)) end
		touch()
	end)
	if s.Low then s.Low:SetText("Small") end
	if s.High then s.High:SetText("Large") end
	val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	val:SetPoint("LEFT", s, "RIGHT", 8, 0)
	local function sync() s.sync(); val:SetText(tostring(get())) end
	sync()
	return { sync = sync }
end

-- A compact [-] value [+] stepper. Returns { refresh, setEnabled }.
local function stepper(panel, x, y, get, set, fmt, step)
	step = step or 1
	local minus = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	minus:SetSize(20, 20); minus:SetText("-"); minus:SetPoint("TOPLEFT", x, y)
	local val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	val:SetPoint("TOPLEFT", x + 22, y - 4); val:SetWidth(46); val:SetJustifyH("CENTER")
	local plus = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	plus:SetSize(20, 20); plus:SetText("+"); plus:SetPoint("TOPLEFT", x + 70, y)
	local function refresh() val:SetText(fmt(get())) end
	minus:SetScript("OnClick", function() set(get() - step); refresh(); touch() end)
	plus:SetScript("OnClick", function() set(get() + step); refresh(); touch() end)
	refresh()
	return {
		refresh = refresh,
		setEnabled = function(on)
			minus:SetEnabled(on); plus:SetEnabled(on)
			minus:SetAlpha(on and 1 or 0.35); plus:SetAlpha(on and 1 or 0.35); val:SetAlpha(on and 1 or 0.35)
		end,
	}
end

function M.BuildSettings(panel)
	if M.EnsureDefaults then M.EnsureDefaults() end
	local className = UnitClass("player")
	local syncers = {}
	local function reg(w) if w and (w.sync or w.refresh) then syncers[#syncers + 1] = w.sync or w.refresh end return w end

	-- controls that grey out when the category system is off
	local gated = {}
	local function gate(fn) gated[#gated + 1] = fn end
	local function updateEnable()
		local on = d().sortByCategory
		for _, fn in ipairs(gated) do fn(on) end
	end

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -16)
	title:SetText("Target Frame+"); title:SetTextColor(1, 0.82, 0)

	local help = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", 16, -44); help:SetWidth(520); help:SetJustifyH("LEFT")
	help:SetText("Restyles the Blizzard target frame's auras. Turn the whole tool on/off in the Hub or the AddOns list.")

	-- ---- sizes (left) + highlight / row width (right) ----
	reg(sizeSlider(panel, 16, -76, "Debuff size", 10, 64, 1,
		function() return d().debuffSize end, function(v) d().debuffSize = v end))
	reg(sizeSlider(panel, 16, -128, "Buff size", 10, 64, 1,
		function() return d().buffSize end, function(v) d().buffSize = v end))

	reg(W.check(panel, 298, -76, "Highlight auras from me",
		function() return d().highlightMine end, function(v) d().highlightMine = v; touch() end))
	reg(W.colorSwatch(panel, 480, -80, function() return d().hlColor end, function(c) d().hlColor = c; touch() end))
	-- Row width slider: value shows how many base-size debuffs fit per row (incl. the gap).
	local function countFits(rw)
		local w, gap = d().debuffSize, d().gapX or 0
		return math.max(1, 1 + math.floor((rw - w) / (w + gap)))
	end
	local rwVal
	local rw = W.slider(panel, 300, -112, "Row width (wrap)", 80, 420, 5,
		function() return d().rowWidth end, function(v) d().rowWidth = v; touch() end)
	if rw.Low then rw.Low:SetText("Thin") end
	if rw.High then rw.High:SetText("Wide") end
	rwVal = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	rwVal:SetPoint("LEFT", rw, "RIGHT", 8, 0)
	local function rwSync() rw.sync(); rwVal:SetText("~" .. countFits(d().rowWidth) .. " auras") end
	rwSync()
	reg({ sync = rwSync })
	derivedRefresh = rwSync

	-- ---- divider ----
	local div = panel:CreateTexture(nil, "ARTWORK")
	div:SetColorTexture(1, 1, 1, 0.15)
	div:SetPoint("TOPLEFT", 16, -184); div:SetSize(544, 1)

	-- ---- categories (all gated by "Sort auras by category") ----
	local ch = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ch:SetPoint("TOPLEFT", 16, -198)
	ch:SetText("Categories  |cff888888(sort order, and size % of the sizes above)|r")

	reg(W.check(panel, 16, -220, "Sort auras by category",
		function() return d().sortByCategory end,
		function(v) d().sortByCategory = v; updateEnable(); touch() end))

	local catRadios = {}
	local function catRow(y, cat, label, pctField)
		local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		lbl:SetPoint("TOPLEFT", 16, y - 3); lbl:SetWidth(190); lbl:SetJustifyH("LEFT"); lbl:SetText(label)
		gate(function(on) lbl:SetAlpha(on and 1 or 0.35) end)
		local btns = {}
		local function refreshRadios()
			local v = d()[ORDER_FIELD[cat]]
			for _, b in ipairs(btns) do b:SetChecked(b.value == v) end
		end
		for i, opt in ipairs(ORDER_OPTS) do
			local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
			cb:SetPoint("TOPLEFT", 210 + (i - 1) * 50, y); cb:SetSize(22, 22)
			local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("LEFT", cb, "RIGHT", 1, 0); fs:SetText(opt.text)
			cb.value = opt.value
			cb:SetScript("OnClick", function(self)
				M.SetCatOrder(cat, self.value)
				for _, r in ipairs(catRadios) do r() end
				touch()
			end)
			btns[#btns + 1] = cb
			gate(function(on) cb:SetEnabled(on); cb:SetAlpha(on and 1 or 0.35); fs:SetAlpha(on and 1 or 0.35) end)
		end
		refreshRadios()
		catRadios[#catRadios + 1] = refreshRadios
		syncers[#syncers + 1] = refreshRadios
		local st = stepper(panel, 380, y,
			function() return d()[pctField] end,
			function(v) d()[pctField] = math.max(50, math.min(200, v)) end,
			function(v) return v .. "%" end, 5)
		reg(st); gate(st.setEnabled)
	end
	catRow(-246, "raid",  "Important raid auras", "catRaidPct")
	catRow(-272, "class", "Class auras (" .. (className or "?") .. ")", "catClassPct")
	catRow(-298, "other", "Everything else", "catOtherPct")

	-- ---- reset buttons (bottom), with a divider above them ----
	local div2 = panel:CreateTexture(nil, "ARTWORK")
	div2:SetColorTexture(1, 1, 1, 0.15)
	div2:SetPoint("TOPLEFT", 16, -478); div2:SetSize(544, 1)

	local resetU = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetU:SetSize(180, 22); resetU:SetPoint("TOPLEFT", 16, -492); resetU:SetText("Reset to Addon Defaults")
	resetU:SetScript("OnClick", function()
		if M.ResetDefaults then M.ResetDefaults() end
		for _, s in ipairs(syncers) do s() end
		updateEnable()
	end)
	local resetB = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetB:SetSize(190, 22); resetB:SetPoint("LEFT", resetU, "RIGHT", 10, 0); resetB:SetText("Reset to Blizzard Defaults")
	resetB:SetScript("OnClick", function()
		if M.BlizzardSizes then M.BlizzardSizes() end
		for _, s in ipairs(syncers) do s() end
	end)

	-- ---- editable raid-aura membership checklist (defaults shown first) ----
	local ff = ns.modules and ns.modules.ff
	local hdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hdr:SetPoint("TOPLEFT", 16, -330)
	hdr:SetText("Important Raid Auras  |cff888888(check to include)|r")
	gate(function(on) hdr:SetAlpha(on and 1 or 0.4) end)

	if not ff or not ff.SPELLS then
		local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		note:SetPoint("TOPLEFT", 16, -352)
		note:SetText("Enable FF Tracker to edit the raid-aura list.")
		updateEnable()
		return
	end

	local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -352); scroll:SetSize(540, 118)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(520, 10); scroll:SetScrollChild(content)

	local rank = {}
	for i, k in ipairs(M.DEFAULT_RAID or {}) do rank[k] = i end
	local debuffs = {}
	for _, sp in ipairs(ff.SPELLS) do if sp.auraType == "HARMFUL" then debuffs[#debuffs + 1] = sp end end
	table.sort(debuffs, function(a, b)
		local ra, rb = rank[a.key], rank[b.key]
		if ra and rb then return ra < rb end
		if ra then return true end
		if rb then return false end
		return a.name < b.name
	end)

	local COLS, COLW, ROWH = 2, 262, 22
	for idx, sp in ipairs(debuffs) do
		local col = (idx - 1) % COLS
		local rowN = math.floor((idx - 1) / COLS)
		local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
		cb:SetPoint("TOPLEFT", col * COLW, -(rowN * ROWH)); cb:SetSize(20, 20)
		cb:SetChecked(d().raidMembers[sp.key] and true or false)
		cb:SetScript("OnClick", function(self)
			d().raidMembers[sp.key] = self:GetChecked() and true or nil
			touch()
		end)
		syncers[#syncers + 1] = function() cb:SetChecked(d().raidMembers[sp.key] and true or false) end

		local nm = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		nm:SetPoint("LEFT", cb, "RIGHT", 4, 0); nm:SetWidth(COLW - 30); nm:SetJustifyH("LEFT"); nm:SetText(sp.name)
		if sp.color then nm:SetTextColor(sp.color[1], sp.color[2], sp.color[3]) end
		gate(function(on) cb:SetEnabled(on); cb:SetAlpha(on and 1 or 0.4); nm:SetAlpha(on and 1 or 0.4) end)
	end
	content:SetHeight(math.max(10, math.ceil(#debuffs / COLS) * ROWH))

	updateEnable()
end
