--[[
	ZombieConfig.lua
	Tier 1: three regular types (Normal/Fast/Tank) plus a Boss that spawns
	after wave 10. Per the reconciled plan's open decision #2, only
	Tank/Boss use PathfindingService (UsesPathfinding = true) — Normal/Fast
	stay on cheap direct-chase to keep server cost down with up to 4 players
	and many concurrent zombies.

	Boss also carries an "enrage" phase 2: once its HP drops to
	EnrageHPFraction, ZombieService swaps in the Enrage* stats and gives it
	a visual tell (see ZombieService.lua) — a simple 2-phase boss per the
	Tier 1 checklist ("can be simple — 2 phases, not 4").
]]

export type ZombieStats = {
	MaxHP: number,
	WalkSpeed: number,
	AttackDamage: number,
	AttackRange: number,
	AttackCooldown: number,
	CoinReward: number,
	UsesPathfinding: boolean,
	Scale: number, -- visual size multiplier for the placeholder rig
	Color: Color3,
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
		UsesPathfinding = false,
		Scale = 1,
		Color = Color3.fromRGB(90, 120, 70),
	},
	Fast = {
		MaxHP = 60,
		WalkSpeed = 13,
		AttackDamage = 6,
		AttackRange = 4,
		AttackCooldown = 0.8,
		CoinReward = 7,
		UsesPathfinding = false,
		Scale = 0.85,
		Color = Color3.fromRGB(205, 190, 60),
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
	},
	Boss = {
		MaxHP = 3000,
		WalkSpeed = 5,
		AttackDamage = 25,
		AttackRange = 8,
		AttackCooldown = 1.2,
		CoinReward = 200, -- split further with a flat victory bonus (see WaveConfig.VictoryBonusCoins)
		UsesPathfinding = true,
		Scale = 2.5,
		Color = Color3.fromRGB(140, 20, 20),
		EnrageHPFraction = 0.5,
		EnrageWalkSpeed = 9,
		EnrageAttackDamage = 40,
		EnrageAttackCooldown = 0.6,
	},
}

return ZombieConfig
