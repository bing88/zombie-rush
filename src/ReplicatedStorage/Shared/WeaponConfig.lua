--[[
	WeaponConfig.lua
	Tier 1: three weapons. Pistol is the free starter every player owns;
	AssaultRifle and Shotgun are unlocked from the shop in the lobby (see
	ShopService + the Stall_Buy* parts in MapBootstrap).

	Kept data-driven per the Tier 0 comment this replaces — Tier 1 only
	needed more entries here, not an architecture change.
]]

export type WeaponStats = {
	Damage: number, -- per pellet; single-pellet weapons just have one pellet
	FireRate: number, -- seconds between shots
	MagazineSize: number,
	ReloadTime: number,
	Range: number,
	Spread: number, -- degrees of random cone spread, applied per pellet
	HeadshotMultiplier: number,
	Pellets: number, -- >1 for shotgun-style multi-pellet spread
	Price: number, -- coins to unlock in the shop; 0 = free starter weapon
}

local WeaponConfig: { [string]: WeaponStats } = {
	Pistol = {
		Damage = 18,
		FireRate = 0.25,
		MagazineSize = 12,
		ReloadTime = 1.4,
		Range = 10000,
		Spread = 1.5,
		HeadshotMultiplier = 2,
		Pellets = 1,
		Price = 0,
	},
	AssaultRifle = {
		Damage = 25,
		FireRate = 0.12,
		MagazineSize = 30,
		ReloadTime = 2.0,
		Range = 10000,
		Spread = 2,
		HeadshotMultiplier = 2,
		Pellets = 1,
		Price = 150,
	},
	Shotgun = {
		Damage = 14, -- per pellet; multiple pellets per shot make this hit hard up close and fall off fast at range
		FireRate = 0.75,
		MagazineSize = 6,
		ReloadTime = 2.4,
		Range = 40,
		Spread = 6,
		HeadshotMultiplier = 1.5,
		Pellets = 8,
		Price = 300,
	},
}

-- Not weapon stats — separate fields so callers can safely iterate
-- WeaponConfig by name -> stats without special-casing non-weapon keys.
WeaponConfig.Order = { "Pistol", "AssaultRifle", "Shotgun" }
WeaponConfig.StartingWeapon = "Pistol"

return WeaponConfig
