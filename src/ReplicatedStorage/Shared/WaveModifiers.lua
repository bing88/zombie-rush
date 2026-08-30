--[[
	WaveModifiers.lua

	Random per-wave modifiers, picked by WaveService once per regular
	wave (1-9; the boss wave has enough going on already and skips this)
	purely for replay variety — same 9 waves, different feel each run.

	Applied server-side only: HP/Speed/Damage multipliers get baked into
	the stats ZombieService spawns each zombie with (see
	ZombieService.SpawnZombie's optional multiplier params); nothing
	client-trusted here.
]]

export type WaveModifier = {
	Name: string,
	Description: string,
	HPMultiplier: number,
	SpeedMultiplier: number,
	DamageMultiplier: number,
	CoinMultiplier: number,
}

local WaveModifiers: { WaveModifier } = {
	{
		Name = "Normal",
		Description = "No modifier this wave.",
		HPMultiplier = 1,
		SpeedMultiplier = 1,
		DamageMultiplier = 1,
		CoinMultiplier = 1,
	},
	{
		Name = "Swarm",
		Description = "Faster zombies, less HP.",
		HPMultiplier = 0.75,
		SpeedMultiplier = 1.35,
		DamageMultiplier = 1,
		CoinMultiplier = 1,
	},
	{
		Name = "Juggernaut",
		Description = "Slower zombies, much more HP.",
		HPMultiplier = 1.6,
		SpeedMultiplier = 0.8,
		DamageMultiplier = 1,
		CoinMultiplier = 1.1,
	},
	{
		Name = "Payday",
		Description = "Double coin rewards this wave.",
		HPMultiplier = 1,
		SpeedMultiplier = 1,
		DamageMultiplier = 1,
		CoinMultiplier = 2,
	},
	{
		Name = "Bloodbath",
		Description = "Zombies hit much harder.",
		HPMultiplier = 1,
		SpeedMultiplier = 1,
		DamageMultiplier = 1.6,
		CoinMultiplier = 1.2,
	},
}

return WaveModifiers
