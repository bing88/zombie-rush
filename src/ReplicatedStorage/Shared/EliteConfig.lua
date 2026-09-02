--[[
	EliteConfig.lua

	Elite AFFIXES (plan section 16): modifiers layered on top of an
	existing zombie type at spawn, so "Elite Runner" and "Elite Tank" are
	the same five affixes wearing different base stats rather than ten
	hand-authored new entries in ZombieConfig.

	THIS IS AN AFFIX SYSTEM, NOT NEW ZOMBIE TYPES, for the same reason
	ZombieConfig's own header gives for Runner/Brute/Spitter/Bomber: new
	types are just stats, and stats alone stop producing surprise once
	you've seen each one twice. Five affixes across nine base types is 45
	combinations from five definitions, and — crucially — the affix is
	rolled per SPAWN, so two Tanks in the same wave can behave
	differently. That's the "high waves become unpredictable" the section
	is asking for, and it's what makes wave 40 different from wave 15
	rather than merely bigger (plan section 29).

	ONE AFFIX PER ZOMBIE, though the plan shows them combining. Two
	reasons, both practical: the nameplate and body tint can only
	communicate one thing legibly, and a player who can't read what's
	coming can't make the target-priority decision the affix exists to
	create (section 9). And the multipliers compound — Armored plus
	Regenerating on a Brute is a 1.8x-HP damage sponge that also heals
	through the resistance, which isn't harder so much as tedious.
	Combining is a config change away if it's wanted later: the roll
	returns one affix id, and everything downstream reads a single
	`EliteAffix` attribute.

	WHY THESE FIVE, of the section's eight. Each one had to change how a
	zombie is FOUGHT, not just how long it takes to kill:
	  Armored       shoot it in the head or bring a bigger gun
	  Frenzied      kill it first, it reaches you before the others
	  Regenerating  commit to the kill or don't start it
	  Volatile      don't be standing next to it when it dies
	  Vampiric      don't let it stay in melee with a teammate
	Skipped: Shielded (a worse Armored — directional resistance needs a
	facing check on every pellet and reads to the player as "my bullets
	randomly do nothing"), Invisible (fights the auto-aim assist, which
	would happily lock onto a zombie the player cannot see), and
	Splitting (needs recursive spawning inside the concurrency cap in
	WaveService, and a bug there fills the arena instead of the wave).
]]

local EliteConfig = {}

export type EliteAffix = {
	Id: string,
	Name: string, -- shown on the nameplate above the zombie
	Color: Color3, -- body tint AND nameplate colour, so the two always agree
	HPMultiplier: number,
	SpeedMultiplier: number,
	DamageMultiplier: number,
	CoinMultiplier: number,
	-- Behaviour fields. Each is read by exactly one place in
	-- ZombieService (or WeaponService, for DamageResistance) and is nil
	-- on every affix that doesn't use it.
	DamageResistance: number?, -- fraction of incoming damage ignored
	RegenFractionPerSecond: number?, -- fraction of MaxHP healed per second
	RegenDelaySeconds: number?, -- quiet time after being damaged before regen resumes
	ExplodeRadius: number?, -- detonation on death
	ExplodeDamage: number?,
	Lifesteal: number?, -- fraction of damage dealt healed back to itself
	-- Base types this affix must never roll on, because it would be
	-- redundant or invisible on them.
	ExcludedTypes: { [string]: boolean }?,
}

local affixes: { EliteAffix } = {
	{
		Id = "Armored",
		Name = "ARMORED",
		Color = Color3.fromRGB(120, 140, 170),
		-- Tuned as resistance rather than raw HP so headshots stay the
		-- answer: the multiplier applies to the already-multiplied
		-- headshot damage, so precision keeps its full relative value
		-- instead of being flattened by a bigger health pool.
		HPMultiplier = 1.3,
		SpeedMultiplier = 0.9,
		DamageMultiplier = 1,
		CoinMultiplier = 2,
		DamageResistance = 0.4,
	},
	{
		Id = "Frenzied",
		Name = "FRENZIED",
		Color = Color3.fromRGB(255, 120, 40),
		-- No HP bonus on purpose. This one is meant to be killed FIRST,
		-- which only works if it's killable quickly; a fast zombie that
		-- also soaks damage isn't a priority target, it's just a chase.
		HPMultiplier = 1,
		SpeedMultiplier = 1.6,
		DamageMultiplier = 1.3,
		CoinMultiplier = 2,
		-- Would be unreadable on the two types that already close fast
		-- and die instantly, and actively unfair on Runner (already
		-- faster than the player).
		ExcludedTypes = { Runner = true, Fast = true },
	},
	{
		Id = "Regenerating",
		Name = "REGENERATING",
		Color = Color3.fromRGB(80, 210, 120),
		HPMultiplier = 1.4,
		SpeedMultiplier = 1,
		DamageMultiplier = 1,
		CoinMultiplier = 2.5,
		-- 4%/s after a 3s lull. The DELAY is the whole mechanic: sustained
		-- fire never sees the regen at all, so this punishes exactly one
		-- thing — starting a kill, breaking off, and coming back to it.
		RegenFractionPerSecond = 0.04,
		RegenDelaySeconds = 3,
	},
	{
		Id = "Volatile",
		Name = "VOLATILE",
		Color = Color3.fromRGB(255, 200, 60),
		HPMultiplier = 1.1,
		SpeedMultiplier = 1.1,
		DamageMultiplier = 1,
		CoinMultiplier = 2,
		ExplodeRadius = 14,
		ExplodeDamage = 45,
		-- Exploder and Bomber already detonate on death; the affix would
		-- be a second explosion nobody can distinguish from the first.
		ExcludedTypes = { Exploder = true, Bomber = true },
	},
	{
		Id = "Vampiric",
		Name = "VAMPIRIC",
		Color = Color3.fromRGB(190, 40, 90),
		HPMultiplier = 1.2,
		SpeedMultiplier = 1.05,
		DamageMultiplier = 1,
		CoinMultiplier = 2.5,
		-- Heals itself for 150% of the damage it deals, so leaving one
		-- chewing on a downed teammate actively undoes your damage.
		Lifesteal = 1.5,
		-- Needs to land repeated melee/ranged hits for this to read as
		-- anything; a one-shot self-detonation would heal a corpse.
		ExcludedTypes = { Exploder = true, Bomber = true },
	},
}

EliteConfig.Affixes = affixes

--[[
	Elites start at wave 6 rather than wave 1: the early waves are where
	a new player is still learning what a plain zombie does, and an
	affixed one before that reads as "this game is unfair" rather than
	"this one is special".
]]
EliteConfig.FirstEliteWave = 6

--[[
	Per-spawn chance an affix is rolled, ramping with the wave and
	capped.

	The cap matters more than the ramp: at 100% every zombie is elite,
	which makes elite the new normal and destroys the contrast the whole
	system runs on. 35% means a late wave is roughly a third special —
	enough that every wave has several, few enough that each one is still
	worth reacting to.
]]
EliteConfig.MaxChance = 0.35
EliteConfig.ChanceRampPerWave = 0.015

function EliteConfig.GetChance(waveNumber: number): number
	if waveNumber < EliteConfig.FirstEliteWave then
		return 0
	end
	local wavesIn = waveNumber - EliteConfig.FirstEliteWave + 1
	return math.min(wavesIn * EliteConfig.ChanceRampPerWave, EliteConfig.MaxChance)
end

function EliteConfig.GetAffix(affixId: string): EliteAffix?
	for _, affix in affixes do
		if affix.Id == affixId then
			return affix
		end
	end
	return nil
end

--[[
	Rolls an affix for one spawning zombie of `statsName`, or nil for an
	ordinary one.

	Callers pass the base type so ExcludedTypes can be honoured — see
	each affix for why it excludes what it does. Filtering here rather
	than re-rolling on rejection means an excluded type gets the normal
	elite CHANCE spread over its remaining eligible affixes, instead of
	silently becoming less likely to be elite at all.
]]
function EliteConfig.RollAffix(waveNumber: number, statsName: string): EliteAffix?
	if math.random() >= EliteConfig.GetChance(waveNumber) then
		return nil
	end

	local eligible = {}
	for _, affix in affixes do
		local excluded = affix.ExcludedTypes and affix.ExcludedTypes[statsName]
		if not excluded then
			table.insert(eligible, affix)
		end
	end
	if #eligible == 0 then
		return nil
	end
	return eligible[math.random(1, #eligible)]
end

return EliteConfig
