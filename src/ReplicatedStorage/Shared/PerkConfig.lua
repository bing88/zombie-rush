--[[
	PerkConfig.lua

	Permanent, Robux-purchased stat perks, backed by Roblox GAME PASSES
	(not developer products). Game passes are the right primitive here:
	they're one-time purchases the platform remembers forever, so a perk
	survives rejoins for free with no extra persistence of our own —
	nothing about perk ownership is stored in our DataStore, and there's
	no way for our save data to disagree with what the player actually
	bought. Developer products are consumable/repeatable, which suits
	things like a coin bundle, not a permanent +25% damage.

	>>> YOU MUST CREATE THESE GAME PASSES YOURSELF <<<

	Every GamePassId below is 0, which means "not configured". A perk
	with id 0 is inert: PerkService never queries it, nobody can own it,
	and its multiplier is always the neutral value — so the game runs
	correctly right now with zero passes set up, and each perk switches
	on the moment you paste a real id in.

	To enable one:
	  1. In Roblox Studio / the Creator Dashboard, open your experience's
	     Associated Items and create a Game Pass (name, icon, price).
	  2. Copy its ID from the dashboard URL or item page.
	  3. Paste it into GamePassId below and set PriceText to match the
	     price you set (PriceText is display-only — Roblox charges
	     whatever the dashboard says, not this string, so if the two ever
	     disagree the dashboard wins).

	Balance note: these are deliberately meaningful-but-not-absurd
	(+25% damage, not +300%). Endless mode means any multiplier
	eventually gets outscaled by wave difficulty, so the perks should
	read as a head start and a comfort boost rather than a way to skip
	the game — which also keeps them from wrecking the leaderboard's
	meaning, since wave-reached is the score.
]]

export type Perk = {
	Key: string,
	DisplayName: string,
	Description: string,
	GamePassId: number,
	PriceText: string,
	-- Multiplier applied when owned. Neutral value (1, or 0 for flat
	-- additions) applies when not owned.
	Multiplier: number,
}

local PerkConfig = {}

--[[
	Order here is the order shown in the perks panel. Damage/Health/Speed
	are the three explicitly requested; the rest are recommended
	additions that target different friction points rather than stacking
	more raw power:

	  - CoinDoubler is the single highest-value perk in most games of
	    this shape: it accelerates the ENTIRE existing progression
	    (weapons + the 10 upgrade levels) instead of adding a separate
	    power axis, so it stays useful for the whole life of an account.
	  - FastReload and BigMag buy uptime rather than damage — they feel
	    strong in the moment-to-moment without inflating numbers, and
	    they scale down naturally as waves get harder.
	  - QuickRevive targets the multiplayer failure state specifically,
	    which is where runs actually end.
]]
PerkConfig.Perks = {
	{
		Key = "DamageBoost",
		DisplayName = "Damage Boost",
		Description = "+25% weapon damage, permanently.",
		GamePassId = 0,
		PriceText = "99 R$",
		Multiplier = 1.25,
	},
	{
		Key = "ExtraHealth",
		DisplayName = "Extra Health",
		Description = "+50% max health, permanently.",
		GamePassId = 0,
		PriceText = "99 R$",
		Multiplier = 1.5,
	},
	{
		Key = "SpeedBoost",
		DisplayName = "Swift Feet",
		Description = "+20% movement speed, permanently.",
		GamePassId = 0,
		PriceText = "79 R$",
		Multiplier = 1.2,
	},
	{
		Key = "CoinDoubler",
		DisplayName = "Coin Doubler",
		Description = "Earn 2x coins from every kill and bonus.",
		GamePassId = 0,
		PriceText = "149 R$",
		Multiplier = 2,
	},
	{
		Key = "FastReload",
		DisplayName = "Fast Hands",
		Description = "Reload 35% faster.",
		GamePassId = 0,
		PriceText = "79 R$",
		Multiplier = 0.65, -- multiplies reload TIME, so lower is better
	},
	{
		Key = "BigMag",
		DisplayName = "Extended Mags",
		Description = "+50% magazine capacity on every weapon.",
		GamePassId = 0,
		PriceText = "99 R$",
		Multiplier = 1.5,
	},
	{
		Key = "QuickRevive",
		DisplayName = "Quick Revive",
		Description = "Revive teammates twice as fast, and bleed out slower.",
		GamePassId = 0,
		PriceText = "79 R$",
		Multiplier = 0.5, -- multiplies revive hold time, so lower is better
	},
}

--[[
	Neutral multiplier for a perk that isn't owned. Perks whose
	multiplier reduces something (reload time, revive time) still return
	1 when unowned — 1 means "unchanged" for all of them, since every
	perk is applied multiplicatively.
]]
PerkConfig.NEUTRAL_MULTIPLIER = 1

function PerkConfig.GetPerk(key: string): Perk?
	for _, perk in PerkConfig.Perks do
		if perk.Key == key then
			return perk
		end
	end
	return nil
end

--[[
	True only for perks that are actually purchasable right now. Anything
	still on the placeholder id 0 is hidden from the shop rather than
	shown as a dead button that errors when tapped.
]]
function PerkConfig.IsConfigured(perk: Perk): boolean
	return perk.GamePassId > 0
end

return PerkConfig
