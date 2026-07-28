--[[--------------------------------------------------------------------------
	Assfish Aquarium - Core / Lib_Util

	Tiny presentation helpers shared by more than one module (icon cropping, the
	raid-target marker atlas), collected here so the magic numbers live in ONE place.
----------------------------------------------------------------------------]]

local ns = AssfishAquarium
local core = ns.core

-- The shared window backdrop used by every module window (dark parchment + tooltip border).
-- Apply with frame:SetBackdrop(core.WINDOW_BACKDROP); frame:SetBackdropColor(0, 0, 0, 0.85).
core.WINDOW_BACKDROP = {
	bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Trim the built-in transparent border off a WoW icon texture.
function core.CropIcon(tex)
	tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end

-- Point a texture at raid-target marker `index` (1=Star .. 8=Skull) in the shared atlas.
-- (Blizzard's SetRaidTargetIconTexture only sets the texcoords, not the texture file, so
-- we set both here.)
local RAID_MARKERS = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
function core.SetRaidMarker(tex, index)
	tex:SetTexture(RAID_MARKERS)
	local c, r = (index - 1) % 4, math.floor((index - 1) / 4)
	tex:SetTexCoord(c * 0.25, c * 0.25 + 0.25, r * 0.25, r * 0.25 + 0.25)
end
