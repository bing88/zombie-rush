--[[
	UpgradeConfig.lua
	Tier 1: weapon upgrades, levels 1-5. Each level scales both Damage
	AND magazine capacity (MagazineBonus is a flat addition to the
	weapon's base MagazineSize, applied in WeaponService — see
	getMagazineCapacity), so upgrading feels meaningful on two axes
	instead of just raw damage.

	MagazineBonus values are the TOTAL bonus AT that level (not a
	per-level delta) — e.g. Pistol level 3's MagazineBonus of 6 means
	"base + 6" at level 3, not "+6 on top of level 2's bonus".

	Nothing client-side is trusted with any of this; WeaponService reads
	these server-side only.
]]

export type UpgradeLevel = {
	Cost: number,
	DamageMultiplier: number,
	MagazineBonus: number,
}

export type WeaponUpgrades = {
	Levels: { [number]: UpgradeLevel },
}

local UpgradeConfig = {}

UpgradeConfig.MaxLevel = 5

local weapons: { [string]: WeaponUpgrades } = {
	Pistol = {
		Levels = {
			[1] = { Cost = 80, DamageMultiplier = 1.15, MagazineBonus = 2 },
			[2] = { Cost = 150, DamageMultiplier = 1.3, MagazineBonus = 4 },
			[3] = { Cost = 240, DamageMultiplier = 1.5, MagazineBonus = 6 },
			[4] = { Cost = 350, DamageMultiplier = 1.7, MagazineBonus = 8 },
			[5] = { Cost = 500, DamageMultiplier = 2.0, MagazineBonus = 10 },
		},
	},
	AssaultRifle = {
		Levels = {
			[1] = { Cost = 120, DamageMultiplier = 1.15, MagazineBonus = 5 },
			[2] = { Cost = 220, DamageMultiplier = 1.3, MagazineBonus = 10 },
			[3] = { Cost = 340, DamageMultiplier = 1.5, MagazineBonus = 15 },
			[4] = { Cost = 480, DamageMultiplier = 1.7, MagazineBonus = 20 },
			[5] = { Cost = 650, DamageMultiplier = 2.0, MagazineBonus = 25 },
		},
	},
	Shotgun = {
		Levels = {
			[1] = { Cost = 150, DamageMultiplier = 1.15, MagazineBonus = 1 },
			[2] = { Cost = 260, DamageMultiplier = 1.3, MagazineBonus = 2 },
			[3] = { Cost = 400, DamageMultiplier = 1.5, MagazineBonus = 3 },
			[4] = { Cost = 560, DamageMultiplier = 1.7, MagazineBonus = 4 },
			[5] = { Cost = 750, DamageMultiplier = 2.0, MagazineBonus = 5 },
		},
	},
}

UpgradeConfig.Weapons = weapons

return UpgradeConfig
