--[[
	ZombieConfig.lua
	Tier 1: Normal/Fast/Tank/Boss (melee) plus two new attack styles —
	Ranged (stops at distance, periodic ranged damage + a visual) and
	Explode (fragile, self-detonates in an AOE on reaching a player or
	on death). AttackType drives which branch of ZombieService's AI runs
	the attack; Melee is the default/existing behavior.

	UsesPathfinding is now true for every type — the loaded subway map
	has real multi-level geometry (walls, stairs, platforms) a straight-
	line MoveTo has no way to route around, unlike the old open-box
	procedural arena this was originally tuned for ("keep server cost
	down with many concurrent zombies" no longer holds once basic
	navigation requires it). Kept as a per-type toggle rather than
	removed, in case a future very-cheap/very-numerous enemy type wants
	to opt back out of the pathfinding cost.
]]

export type ZombieStats = {
	MaxHP: number,
	WalkSpeed: number,
	AttackDamage: number,
	AttackRange: number,
	AttackCooldown: number,
	CoinReward: number,
	UsesPathfinding: boolean,
	Scale: number,
	Color: Color3,
	AttackType: string, -- "Melee" | "Ranged" | "Explode"
	ExplosionRadius: number?, -- Explode only
	ExplosionDamage: number?, -- Explode only
	EnrageHPFraction: number?, -- Boss only: HP fraction that triggers phase 2
	EnrageWalkSpeed: number?,
	EnrageAttackDamage: number?,
	EnrageAttackCooldown: number?,
}

local ZombieConfig: { [string]: ZombieStats } = {
	Normal = {
		MaxHP = 100,
		WalkSpeed = 6,
		AttackDamage = 10,
		AttackRange = 5,
		AttackCooldown = 1.0,
		CoinReward = 5,
		UsesPathfinding = true,
		Scale = 1,
		Color = Color3.fromRGB(90, 120, 70),
		AttackType = "Melee",
	},
	Fast = {
		MaxHP = 60,
		WalkSpeed = 13,
		AttackDamage = 6,
		AttackRange = 4,
		AttackCooldown = 0.8,
		CoinReward = 7,
		UsesPathfinding = true,
		Scale = 0.85,
		Color = Color3.fromRGB(205, 190, 60),
		AttackType = "Melee",
	},
	Tank = {
		MaxHP = 400,
		WalkSpeed = 4,
		AttackDamage = 20,
		AttackRange = 6,
		AttackCooldown = 1.4,
		CoinReward = 15,
		UsesPathfinding = true,
		Scale = 1.6,
		Color = Color3.fromRGB(80, 70, 90),
		AttackType = "Melee",
	},
	Ranged = {
		MaxHP = 50,
		WalkSpeed = 5,
		AttackDamage = 8,
		AttackRange = 28, -- stops well back and fires rather than closing to melee
		AttackCooldown = 2.2,
		CoinReward = 10,
		UsesPathfinding = true,
		Scale = 0.95,
		Color = Color3.fromRGB(120, 180, 90),
		AttackType = "Ranged",
	},
	Exploder = {
		MaxHP = 40, -- fragile on purpose: meant to be shot down before it reaches you
		WalkSpeed = 7,
		AttackDamage = 0, -- unused; see ExplosionDamage
		AttackRange = 4, -- detonation trigger distance
		AttackCooldown = 0,
		CoinReward = 12,
		UsesPathfinding = true,
		Scale = 1.1,
		Color = Color3.fromRGB(200, 120, 30),
		AttackType = "Explode",
		ExplosionRadius = 10,
		ExplosionDamage = 35,
	},
	Boss = {
		MaxHP = 3000,
		WalkSpeed = 5,
		AttackDamage = 25,
		AttackRange = 8,
		AttackCooldown = 1.2,
		CoinReward = 200, -- plus a flat bonus to everyone each time a boss wave is cleared (see WaveConfig.BossClearBonusCoins)
		UsesPathfinding = true,
		Scale = 2.5,
		Color = Color3.fromRGB(140, 20, 20),
		AttackType = "Melee",
		EnrageHPFraction = 0.5,
		EnrageWalkSpeed = 9,
		EnrageAttackDamage = 40,
		EnrageAttackCooldown = 0.6,
	},
}

return ZombieConfig
