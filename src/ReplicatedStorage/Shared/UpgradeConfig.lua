--[[
	UpgradeConfig.lua
	Tier 1: basic weapon upgrades, levels 1-3 only (per the reconciled MVP
	doc — "not full 10-level curve"). Each level is a flat damage
	multiplier applied server-side in WeaponService; nothing client-side
	is trusted with this.
]]

export type UpgradeLevel = {
	Cost: number,
	DamageMultiplier: number,
}

export type WeaponUpgrades = {
	Levels: { [number]: UpgradeLevel },
}

local UpgradeConfig = {}

UpgradeConfig.MaxLevel = 3

local weapons: { [string]: WeaponUpgrades } = {
	Pistol = {
		Levels = {
			[1] = { Cost = 80, DamageMultiplier = 1.2 },
			[2] = { Cost = 160, DamageMultiplier = 1.45 },
			[3] = { Cost = 280, DamageMultiplier = 1.75 },
		},
	},
	AssaultRifle = {
		Levels = {
			[1] = { Cost = 120, DamageMultiplier = 1.2 },
			[2] = { Cost = 220, DamageMultiplier = 1.45 },
			[3] = { Cost = 350, DamageMultiplier = 1.75 },
		},
	},
	Shotgun = {
		Levels = {
			[1] = { Cost = 150, DamageMultiplier = 1.2 },
			[2] = { Cost = 260, DamageMultiplier = 1.45 },
			[3] = { Cost = 400, DamageMultiplier = 1.75 },
		},
	},
}

UpgradeConfig.Weapons = weapons

return UpgradeConfig
