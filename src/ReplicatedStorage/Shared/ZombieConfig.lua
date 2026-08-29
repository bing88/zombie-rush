--[[
	ZombieConfig.lua
	Tier 0: exactly ONE zombie type (Normal). Fast/Tank arrive in Tier 1.
]]

export type ZombieStats = {
	MaxHP: number,
	WalkSpeed: number,
	AttackDamage: number,
	AttackRange: number,
	AttackCooldown: number,
}

local ZombieConfig: { [string]: ZombieStats } = {
	Normal = {
		MaxHP = 100,
		WalkSpeed = 12,
		AttackDamage = 10,
		AttackRange = 5,
		AttackCooldown = 1.0,
	},
}

return ZombieConfig
