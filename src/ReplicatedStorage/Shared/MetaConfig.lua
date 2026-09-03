--[[
	MetaConfig.lua

	The ONLY thing that persists across runs now (plan sections 21-22).

	Weapons, upgrade levels and cash all became run-scoped — see
	RunLoadoutService — which fixed a real problem: coins used to persist,
	so a player with a few runs banked could buy every weapon and max its
	upgrades during wave 1 and never feel the difficulty curve again.
	Power came from a savings account rather than from the run.

	But stripping persistence entirely removes the reason to start
	another run at all. So this layer exists, with one rule that keeps it
	from recreating the problem it replaced:

	  META PROGRESSION WIDENS OPTIONS. IT NEVER RAISES POWER.

	Levelling up unlocks which weapons are ALLOWED TO APPEAR in the run
	shop. It never grants a weapon, cash, damage, health, or a discount.
	A max-level veteran and a brand-new player both start every run with
	a Pistol and zero cash, and both have to earn everything they use —
	the veteran just has a longer menu to earn it from. That's why this
	can't trivialise early waves the way persistent coins did, no matter
	how high it goes.

	It also means the meta layer can grow (more weapons, later a
	cosmetics or loadout-slot track) without ever needing a balance pass
	on the waves themselves.

	XP comes from WAVES CLEARED, not kills or coins. Waves cleared is the
	one number that can't be farmed: you can't grind it in a safe corner
	of wave 3, and it's already what the leaderboard ranks people by, so
	the meta track and the leaderboard reward the same thing.
]]

local MetaConfig = {}

--[[
	XP per wave cleared in a run.

	Deliberately calibrated so ONE decent run (reaching about wave 10)
	is enough for level 2 and therefore the Shotgun. A meta gate that
	takes five runs to open its first door reads as the game withholding
	content; one that opens on the first good run reads as a reward.
]]
MetaConfig.XPPerWave = 12

--[[
	Total XP required to have reached each level. Index = level, so
	level 1 is the starting state at 0 XP.

	Gaps widen because later levels gate content that doesn't exist yet
	(there are three weapons today) — the curve is here so adding a
	fourth weapon is a one-line Unlocks change rather than a rebalance.
]]
local levelThresholds = { 0, 120, 320, 640, 1100, 1750, 2600, 3700, 5100, 6800 }

MetaConfig.LevelThresholds = levelThresholds
MetaConfig.MaxLevel = #levelThresholds

--[[
	Meta level at which each weapon becomes PURCHASABLE in the run shop.
	It still has to be bought with run cash, every single run.

	Pistol is level 1 because it's the free starting weapon and the game
	would be unplayable without it. AssaultRifle is also level 1 on
	purpose: a brand-new player must have a real spending decision in
	their first run ("rifle now, or pistol upgrades?"), and gating every
	alternative behind the meta track would leave them with cash and
	nothing to spend it on.
]]
local weaponUnlockLevel: { [string]: number } = {
	Pistol = 1,
	AssaultRifle = 1,
	Shotgun = 2,
}

MetaConfig.WeaponUnlockLevel = weaponUnlockLevel

function MetaConfig.GetLevel(totalXP: number): number
	local level = 1
	for candidate, threshold in levelThresholds do
		if totalXP >= threshold then
			level = candidate
		else
			break -- ascending, nothing further can match
		end
	end
	return level
end

--[[
	Level plus how far into it the player is, for the HUD's progress bar.
	xpForNext is nil at max level, which is what tells the UI to render
	"MAX" instead of a fraction.
]]
function MetaConfig.GetProgress(totalXP: number): (number, number, number?)
	local level = MetaConfig.GetLevel(totalXP)
	local currentThreshold = levelThresholds[level] or 0
	local nextThreshold = levelThresholds[level + 1]
	if not nextThreshold then
		return level, 0, nil
	end
	return level, totalXP - currentThreshold, nextThreshold - currentThreshold
end

--[[
	Whether a weapon is allowed to appear in the run shop at all.

	An unconfigured weapon defaults to AVAILABLE rather than locked, so
	adding a weapon to WeaponConfig without touching this file makes it
	buyable instead of silently invisible — a missing entry should fail
	toward "the content works" rather than toward "the content is gone
	and nothing says why".
]]
function MetaConfig.IsWeaponAvailable(metaLevel: number, weaponName: string): boolean
	local required = weaponUnlockLevel[weaponName]
	if not required then
		return true
	end
	return metaLevel >= required
end

function MetaConfig.GetWeaponRequiredLevel(weaponName: string): number
	return weaponUnlockLevel[weaponName] or 1
end

--[[
	XP earned for a finished run. wavesCleared is the number fully
	survived, so a run wiped out during wave 7 scores 6.
]]
function MetaConfig.GetRunXP(wavesCleared: number): number
	return math.max(math.floor(wavesCleared), 0) * MetaConfig.XPPerWave
end

return MetaConfig
