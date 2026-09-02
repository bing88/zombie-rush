--[[
	RunUpgradeConfig.lua

	The card pool for the between-wave 3-choice draft (see
	RunUpgradeService on the server, RunDraftController on the client).

	WHY THIS EXISTS, AND HOW IT DIFFERS FROM UpgradeConfig:

	UpgradeConfig is PERMANENT, ACCOUNT-WIDE progression — coins buy a
	weapon level, that level is saved to the DataStore, and it applies to
	every future run identically. It's a power curve, not a decision:
	there's exactly one ladder per weapon and the only question is
	whether you can afford the next rung yet.

	These are RUN-SCOPED and CHOSEN. Nothing here is bought, nothing is
	saved, and everything is wiped when the run ends
	(RunUpgradeService.ResetAll). Each break between waves offers three
	random cards from this pool and the player keeps one. That single
	change is what turns "survive the wave" into an actual reward moment,
	and what makes two runs with the same weapons and the same account
	upgrades play differently.

	BUILDS ARE EMERGENT, NOT AUTHORED. There are no explicit "crit
	build"/"explosive build" trees here. Stacking is what specializes a
	run: five Gunslingers is a fundamentally different weapon than five
	Hollow Points, and Demolitionist plus Bloodthirst plays nothing like
	Marksman plus Speed Loader. MaxStacks is the balance lever — it caps
	how far any single axis can be pushed, and forces a run that keeps
	drafting to eventually branch into a second axis.

	STAT CONTRACT: each card adds `Amount` to a running total for its
	`Stat`, and consumers read that total through RunUpgradeService's
	GetScale/GetTimeScale/GetTotal. Which of those three a stat uses is
	fixed per stat and documented below — get it wrong and a "+15% fire
	rate" card would make the gun slower, so the mapping lives here as
	the single source of truth rather than being re-decided at each call
	site.

	  GetScale     (1 + total)  Damage, HeadshotDamage, Magazine,
	                            MoveSpeed, CoinGain
	                            -> bigger is better, so bonuses ADD
	  GetTimeScale (1/(1+total) FireRate, ReloadSpeed
	                            -> these scale a DURATION (shot delay,
	                            reload seconds) where SMALLER is better.
	                            1/(1+total) rather than (1 - total)
	                            because subtracting can reach zero or go
	                            negative once stacked (4 x 25% reload =
	                            an instant, then infinite, reload),
	                            whereas dividing approaches zero without
	                            ever touching it. "25% faster" therefore
	                            means 1/1.25 = 0.8x the time, which is
	                            genuinely 25% more actions per second.
	  GetTotal     (raw sum)    MaxHealth, HealPerKill, ExplodeOnKill
	                            -> flat values, used directly

	Adding a card needs nothing but a new entry here as long as it reuses
	an existing Stat. A brand new Stat additionally needs one read at
	whichever service owns that number (see RunUpgradeService's header
	for the current list of consumers).
]]

export type RunUpgradeCard = {
	Id: string,
	Name: string,
	Description: string,
	Stat: string,
	Amount: number,
	MaxStacks: number,
}

local RunUpgradeConfig = {}

--[[
	How many cards a draft offers. Three is the doc-recommended number
	and is deliberately fewer than the pool size, so an offer is a real
	choice between alternatives rather than a formality.
]]
RunUpgradeConfig.OfferCount = 3

local Cards: { RunUpgradeCard } = {
	{
		Id = "Gunslinger",
		Name = "GUNSLINGER",
		Description = "+15% fire rate",
		Stat = "FireRate",
		Amount = 0.15,
		MaxStacks = 5,
	},
	{
		Id = "HollowPoint",
		Name = "HOLLOW POINT",
		Description = "+20% weapon damage",
		Stat = "Damage",
		Amount = 0.2,
		MaxStacks = 5,
	},
	{
		Id = "Marksman",
		Name = "MARKSMAN",
		Description = "+35% headshot damage",
		Stat = "HeadshotDamage",
		Amount = 0.35,
		MaxStacks = 4,
	},
	{
		Id = "ExtendedMag",
		Name = "EXTENDED MAG",
		Description = "+30% magazine size",
		Stat = "Magazine",
		Amount = 0.3,
		MaxStacks = 4,
	},
	{
		Id = "SpeedLoader",
		Name = "SPEED LOADER",
		Description = "Reload 25% faster",
		Stat = "ReloadSpeed",
		Amount = 0.25,
		MaxStacks = 4,
	},
	{
		Id = "Survivor",
		Name = "SURVIVOR",
		Description = "+25 max health",
		Stat = "MaxHealth",
		Amount = 25,
		MaxStacks = 4,
	},
	{
		Id = "Adrenaline",
		Name = "ADRENALINE",
		Description = "+12% move speed",
		Stat = "MoveSpeed",
		Amount = 0.12,
		MaxStacks = 3,
	},
	{
		Id = "Bloodthirst",
		Name = "BLOODTHIRST",
		Description = "Heal 3 HP per kill",
		Stat = "HealPerKill",
		Amount = 3,
		MaxStacks = 3,
	},
	{
		-- Reuses the exploding-projectile splash WeaponService already
		-- has for the (currently unused) ExplodeOnImpact weapon field,
		-- so this needs no new damage system — see
		-- RunUpgradeConfig.GetKillExplosion below for the scaling.
		Id = "Demolitionist",
		Name = "DEMOLITIONIST",
		Description = "Kills detonate, damaging nearby zombies",
		Stat = "ExplodeOnKill",
		Amount = 1,
		MaxStacks = 3,
	},
	{
		Id = "Scavenger",
		Name = "SCAVENGER",
		Description = "+25% coins from kills",
		Stat = "CoinGain",
		Amount = 0.25,
		MaxStacks = 4,
	},
}

RunUpgradeConfig.Cards = Cards

local cardsById: { [string]: RunUpgradeCard } = {}
for _, card in Cards do
	cardsById[card.Id] = card
end

function RunUpgradeConfig.GetCard(id: string): RunUpgradeCard?
	return cardsById[id]
end

--[[
	Blast radius/damage for a Demolitionist kill at the given stack
	count. Kept here beside the card itself rather than in WeaponService
	so the card's whole behavior is described in one place.

	Radius grows faster than damage on purpose: the fantasy being sold is
	chain-clearing a horde, not single-target burst (weapon damage cards
	already cover that). Returns nothing meaningful at 0 stacks — callers
	check the stack count first.
]]
function RunUpgradeConfig.GetKillExplosion(stacks: number): (number, number)
	local radius = 8 + (stacks - 1) * 4 -- 8 / 12 / 16 studs
	local damage = 40 + (stacks - 1) * 20 -- 40 / 60 / 80 at the center
	return radius, damage
end

return RunUpgradeConfig
