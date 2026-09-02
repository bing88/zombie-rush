--[[
	ComboConfig.lua

	The kill-streak / combo ladder (plan section 19: "Reward aggressive
	play"). Shared rather than server-only because the HUD renders tier
	names and colours from this same table — the client must never keep
	its own copy of the thresholds or the two would drift.

	TIER VALUES ARE ABSOLUTE, NOT CUMULATIVE. A player at 60 kills is on
	the UNSTOPPABLE tier and gets exactly its FireRate/Damage, not the sum
	of every tier below it. Summing read nicer on paper but made the
	numbers impossible to reason about at a glance (is +10% and +10% and
	+20% a 40% or a 45.2% increase?), and the whole point of the streak
	HUD is that the player can see what they currently have.

	The plan's ladder rewards 50 kills with a POWERUP and 100 kills with
	ULTIMATE CHARGE. Powerups (plan section 18) don't exist yet, so the
	50-kill rung is a straight stat rung for now. The 100-kill rung is
	implemented as it's written: see ChargeMultiplier, which is how the
	combo feeds the ultimate rather than granting a flat lump of charge.

	WHY ChargeMultiplier RATHER THAN A ONE-OFF GRANT AT 100: a lump sum
	at exactly 100 kills would be invisible for the entire climb and then
	arrive as a single unexplained jump — and any player whose streak
	decayed at 97 would get nothing at all for the whole run of kills.
	Scaling the per-kill charge by tier instead means aggression pays
	continuously and the ultimate meter visibly fills faster the hotter
	the streak is, which is the behaviour the section is asking for.
]]

local ComboConfig = {}

--[[
	Seconds without a kill before the streak drops to zero.

	4s is tuned to be forgiving between clusters of zombies in the same
	wave but unsurvivable across a wave boundary — the between-wave break
	is 15s (WaveConfig.BetweenWaveBreakSeconds), so a streak never
	carries over into the next wave. Streaks are meant to be built and
	lost inside a fight, not banked.
]]
ComboConfig.DecaySeconds = 4

export type ComboTier = {
	Kills: number, -- streak length at which this tier takes over
	Name: string,
	Color: Color3,
	FireRate: number, -- fractional bonus, e.g. 0.1 = +10% rate of fire
	Damage: number, -- fractional bonus, e.g. 0.2 = +20% damage
	ChargeMultiplier: number, -- scales ultimate charge earned per kill
}

--[[
	Ascending by Kills — GetTier relies on that ordering, and the HUD
	walks the list to find the next rung to show as a goal.
]]
local tiers: { ComboTier } = {
	{
		Kills = 10,
		Name = "HOT",
		Color = Color3.fromRGB(255, 176, 64),
		FireRate = 0.1,
		Damage = 0,
		ChargeMultiplier = 1.25,
	},
	{
		Kills = 25,
		Name = "BLAZING",
		Color = Color3.fromRGB(255, 122, 40),
		FireRate = 0.1,
		Damage = 0.1,
		ChargeMultiplier = 1.5,
	},
	{
		Kills = 50,
		Name = "UNSTOPPABLE",
		Color = Color3.fromRGB(255, 64, 48),
		FireRate = 0.2,
		Damage = 0.2,
		ChargeMultiplier = 1.75,
	},
	{
		Kills = 100,
		Name = "GODLIKE",
		Color = Color3.fromRGB(255, 72, 200),
		FireRate = 0.3,
		Damage = 0.35,
		ChargeMultiplier = 2.5,
	},
}

ComboConfig.Tiers = tiers

--[[
	The tier a streak of `count` kills sits on, or nil below the first
	rung. nil (rather than a neutral zero-bonus tier) is deliberate: it's
	what tells the HUD to hide the streak readout entirely, so a single
	kill doesn't put a permanent "1x" on screen.
]]
function ComboConfig.GetTier(count: number): ComboTier?
	local current: ComboTier? = nil
	for _, tier in tiers do
		if count >= tier.Kills then
			current = tier
		else
			break -- ascending, so nothing further can match
		end
	end
	return current
end

--[[
	The next rung up, for the "NEXT AT 25" goal line in the HUD. nil once
	the top tier is reached.
]]
function ComboConfig.GetNextTier(count: number): ComboTier?
	for _, tier in tiers do
		if count < tier.Kills then
			return tier
		end
	end
	return nil
end

return ComboConfig
