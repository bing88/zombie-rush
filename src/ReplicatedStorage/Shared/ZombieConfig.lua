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
		WalkSpeed = 6, -- halved from 12: original speed felt too aggressive for Tier 0 testing
		AttackDamage = 10,
		AttackRange = 5,
		AttackCooldown = 1.0,
	},
}

return ZombieConfig
