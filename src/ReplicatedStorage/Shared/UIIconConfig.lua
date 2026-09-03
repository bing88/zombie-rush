--[[
	UIIconConfig.lua

	rbxassetid strings for combat HUD action buttons. Paste IDs after
	uploading the PNGs from docs/ui-icon-design.md (Reload / View / Ult / Fire).

	Empty string = keep the text label stand-in (current default until art
	is uploaded). Weapon and draft-card icons live on WeaponConfig /
	RunUpgradeConfig instead.
]]

local UIIconConfig = {
	Reload = "rbxassetid://107062032602609", -- e.g. "rbxassetid://1234567890"
	View = "rbxassetid://76878389142136",
	Ult = "rbxassetid://122651360419569",
	Fire = "rbxassetid://86911858279919",
}

function UIIconConfig.IsSet(iconId: string?): boolean
	return typeof(iconId) == "string" and iconId ~= ""
end

return UIIconConfig
