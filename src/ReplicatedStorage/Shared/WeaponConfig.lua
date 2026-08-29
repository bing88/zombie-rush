--[[
	WeaponConfig.lua
	Tier 0: exactly ONE weapon. Add more here once Tier 0's gate passes
	(see reconciled MVP doc, section 1, Tier 1 adds Pistol/AR/Shotgun).

	Kept data-driven from day one so Tier 1 doesn't require an architecture
	change, just more entries in this table.
]]

export type WeaponStats = {
	Damage: number,
	FireRate: number, -- seconds between shots
	MagazineSize: number,
	ReloadTime: number,
	Range: number,
	Spread: number, -- degrees of random cone spread
	HeadshotMultiplier: number,
}

local WeaponConfig: { [string]: WeaponStats } = {
	AssaultRifle = {
		Damage = 25,
		FireRate = 0.12,
		MagazineSize = 30,
		ReloadTime = 2.0,
		Range = 10000, -- effectively unlimited for any realistic Tier 0/1 map size
		Spread = 2,
		HeadshotMultiplier = 2,
	},
}

return WeaponConfig
