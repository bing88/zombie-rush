--[[
	WaveConfig.lua
	ENDLESS mode: waves never run out. Waves 1-10 are the handcrafted
	curve below (unchanged, so the early game is still deliberately
	paced); wave 11 onward is generated procedurally by GetWave(), which
	keeps scaling counts and introducing the later zombie types forever.
	A boss arrives every BossEveryNWaves waves instead of only once at
	the end, so there's a recurring difficulty spike and a natural
	milestone to survive to. There is no "victory" state anymore — a run
	ends only when the team is wiped, and the score is how deep you got.

	Fully data-driven so balance can be retuned here without touching
	WaveService's state-machine logic.
]]

export type WaveComposition = { [string]: number } -- e.g. { Normal = 6, Fast = 3 }

export type WaveData = {
	Composition: WaveComposition,
	SpawnInterval: number, -- seconds between each zombie spawn within the wave
}

local WaveConfig = {}

WaveConfig.LobbyCountdownSeconds = 20 -- multiplayer party wait: time for others to join the portal before the match starts anyway
WaveConfig.SoloCountdownSeconds = 5 -- solo party: nobody to wait for, so start almost immediately
-- Raised from 8s when the between-wave upgrade draft went in (see
-- RunUpgradeService): the break is now a decision window, not just a
-- pause, and 8 seconds is not long enough to read three cards and
-- choose while also repositioning for the next wave. This doubles as
-- the draft's own deadline — WaveService closes the draft when the
-- countdown ends — so lengthening it further makes runs feel slack,
-- and shortening it makes picks feel rushed.
WaveConfig.BetweenWaveBreakSeconds = 15
WaveConfig.BossIntroSeconds = 6
WaveConfig.EndOfRunSeconds = 15 -- scoreboard/return-to-lobby time after a run ends
WaveConfig.MaxConcurrentZombies = 20 -- safety cap so a slow team can't stack up unlimited active zombies

-- Each new type is introduced alone-ish on its debut wave so players
-- can learn what it does, before it starts appearing alongside
-- everything else.
local Waves: { WaveData } = {
	{ Composition = { Normal = 5 }, SpawnInterval = 2.2 },
	{ Composition = { Normal = 7 }, SpawnInterval = 2.0 },
	{ Composition = { Normal = 6, Fast = 3 }, SpawnInterval = 1.9 },
	{ Composition = { Normal = 7, Fast = 4, Runner = 2 }, SpawnInterval = 1.8 }, -- Runner debut
	{ Composition = { Normal = 6, Fast = 4, Runner = 3, Tank = 1 }, SpawnInterval = 1.7 },
	{ Composition = { Normal = 8, Fast = 5, Runner = 3, Ranged = 2 }, SpawnInterval = 1.6 }, -- Ranged debut
	{ Composition = { Normal = 8, Fast = 6, Tank = 2, Exploder = 2 }, SpawnInterval = 1.5 }, -- Exploder debut
	{ Composition = { Normal = 9, Fast = 7, Runner = 4, Ranged = 3, Spitter = 1 }, SpawnInterval = 1.4 }, -- Spitter debut
	{ Composition = { Normal = 10, Fast = 8, Tank = 3, Exploder = 3, Brute = 1 }, SpawnInterval = 1.3 }, -- Brute debut
	{ Composition = { Normal = 12, Fast = 10, Runner = 6, Tank = 4, Spitter = 2 }, SpawnInterval = 1.2 },
}

WaveConfig.Waves = Waves

-- Every Nth wave is a boss wave (10, 20, 30, ...). Boss HP scales with
-- how many have already appeared — see GetBossHPMultiplier.
WaveConfig.BossEveryNWaves = 10

-- Coins granted to everyone present each time a boss wave is cleared.
-- Replaces the old one-off victory bonus now that runs are endless.
WaveConfig.BossClearBonusCoins = 100

--[[
	Composition/pacing for any wave number, forever.

	Waves 1..#Waves come straight from the handcrafted table above.
	Beyond that they're generated: counts grow steadily with wave
	number, spawn interval keeps tightening toward a floor, and the
	nastier types (Ranged, Exploder) phase in on top of the
	Normal/Fast/Tank baseline. Growth is deliberately linear rather
	than exponential — MaxConcurrentZombies already caps how many can
	be alive at once, so exponential counts would just make late waves
	drag on at the cap rather than actually feel harder.
]]
function WaveConfig.GetWave(waveNumber: number): WaveData
	local handcrafted = Waves[waveNumber]
	if handcrafted then
		return handcrafted
	end

	local beyond = waveNumber - #Waves -- 1, 2, 3, ... past the handcrafted curve

	local composition: WaveComposition = {
		Normal = 12 + math.floor(beyond * 1.5),
		Fast = 10 + beyond,
		Tank = 4 + math.floor(beyond / 3),
	}
	-- Ranged/Exploder only start appearing past the handcrafted curve,
	-- so they read as an escalation rather than arriving all at once.
	if beyond >= 2 then
		composition.Ranged = 2 + math.floor(beyond / 2)
	end
	if beyond >= 4 then
		composition.Exploder = 1 + math.floor(beyond / 3)
	end
	-- The heavier variants phase in later still, each one raising the
	-- ceiling on what a wave can throw at you without simply multiplying
	-- the count of things you already know how to handle.
	if beyond >= 3 then
		composition.Runner = 3 + beyond
	end
	if beyond >= 6 then
		composition.Spitter = 1 + math.floor(beyond / 4)
	end
	if beyond >= 8 then
		composition.Brute = 1 + math.floor(beyond / 6)
	end
	if beyond >= 12 then
		composition.Bomber = 1 + math.floor(beyond / 8)
	end

	return {
		Composition = composition,
		SpawnInterval = math.max(0.5, 1.2 - beyond * 0.03),
	}
end

--[[
	HP multiplier for the boss on a given boss wave — the wave-10 boss
	is unscaled (1x), each subsequent boss is meaningfully tougher.
	Without this, every boss after the first would be trivial against
	fully-upgraded weapons.
]]
function WaveConfig.GetBossHPMultiplier(waveNumber: number): number
	local bossIndex = math.floor(waveNumber / WaveConfig.BossEveryNWaves) -- 1 at wave 10, 2 at wave 20, ...
	return 1 + (bossIndex - 1) * 0.75
end

--[[
	Support pack that spawns alongside the boss. Uses that wave's normal
	composition (same curve as a non-boss wave) so escorts scale with
	depth — wave 10 gets the handcrafted finale mix, wave 20+ gets the
	generated curve. Boss itself is never in this table; WaveService
	spawns it separately.
]]
function WaveConfig.GetBossEscort(waveNumber: number): WaveData
	local base = WaveConfig.GetWave(waveNumber)
	local composition: WaveComposition = {}
	for zombieType, count in base.Composition do
		if zombieType ~= "Boss" and type(count) == "number" and count > 0 then
			composition[zombieType] = count
		end
	end
	return {
		Composition = composition,
		-- Slightly slower than the normal wave so the boss remains readable
		-- while adds keep pressure on.
		SpawnInterval = math.max(0.7, base.SpawnInterval * 1.15),
	}
end

return WaveConfig
