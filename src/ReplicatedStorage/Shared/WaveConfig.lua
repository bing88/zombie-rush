--[[
	WaveConfig.lua
	Tier 1: 10 waves of scaling difficulty (per the reconciled MVP doc,
	section 1), then a boss. Fully data-driven so balance can be retuned
	here without touching WaveService's state-machine logic.
]]

export type WaveComposition = { [string]: number } -- e.g. { Normal = 6, Fast = 3 }

export type WaveData = {
	Composition: WaveComposition,
	SpawnInterval: number, -- seconds between each zombie spawn within the wave
}

local WaveConfig = {}

WaveConfig.LobbyCountdownSeconds = 20 -- time between the first player joining and the match starting
WaveConfig.BetweenWaveBreakSeconds = 8
WaveConfig.BossIntroSeconds = 6
WaveConfig.VictorySeconds = 15
WaveConfig.VictoryBonusCoins = 100 -- flat bonus to every player present when the boss dies
WaveConfig.MaxConcurrentZombies = 20 -- safety cap so a slow team can't stack up unlimited active zombies

local Waves: { WaveData } = {
	{ Composition = { Normal = 5 }, SpawnInterval = 2.2 },
	{ Composition = { Normal = 7 }, SpawnInterval = 2.0 },
	{ Composition = { Normal = 6, Fast = 3 }, SpawnInterval = 1.9 },
	{ Composition = { Normal = 8, Fast = 4 }, SpawnInterval = 1.8 },
	{ Composition = { Normal = 6, Fast = 4, Tank = 1 }, SpawnInterval = 1.7 },
	{ Composition = { Normal = 8, Fast = 6, Tank = 1 }, SpawnInterval = 1.6 },
	{ Composition = { Normal = 8, Fast = 6, Tank = 2 }, SpawnInterval = 1.5 },
	{ Composition = { Normal = 10, Fast = 8, Tank = 2 }, SpawnInterval = 1.4 },
	{ Composition = { Normal = 10, Fast = 8, Tank = 3 }, SpawnInterval = 1.3 },
	{ Composition = { Normal = 12, Fast = 10, Tank = 4 }, SpawnInterval = 1.2 },
}

WaveConfig.Waves = Waves

return WaveConfig
