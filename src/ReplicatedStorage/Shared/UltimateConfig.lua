--[[
	UltimateConfig.lua

	The charge-and-spend ultimate ability (plan section 20). Shared so the
	HUD can label the button and show the duration without hardcoding
	either.

	ONE ULTIMATE, NOT A ROSTER. The plan lists five candidates
	(Bombardment, Berserk, Freeze, Turret, Black Hole); this implements
	Berserk only. Berserk is the one that needs no new world entities, no
	new targeting UI and no new zombie state — it's a timed multiplier,
	so it rides the exact damage/fire-rate plumbing that coin upgrades,
	Robux perks and run-drafted cards already flow through (see
	WeaponService's getDamageMultiplier and its fire-gap check). The other
	four each need their own spawned object or zombie status effect, which
	is a much larger change than the decision they add. The module is
	shaped as a single named ability rather than a table of one so that
	growing it into a roster later is an obvious, additive change.

	The interesting decision the plan wants — "use it now, or save it for
	the boss?" — exists with one ability, because the cost is the same
	either way: charge spent now is charge not available in two waves.
]]

local UltimateConfig = {}

UltimateConfig.Id = "Berserk"
UltimateConfig.Name = "BERSERK"
UltimateConfig.Description = "+100% fire rate, +50% damage"
UltimateConfig.Color = Color3.fromRGB(255, 72, 200)

--[[
	Seconds the buff lasts once spent.

	8s is deliberately shorter than a wave: the plan describes powerups
	and ultimates as "short periods where the player feels extremely
	powerful" (section 18), and a window long enough to cover a whole
	wave would flatten the decision into "press it as it fills".
]]
UltimateConfig.DurationSeconds = 8

-- Fractional bonuses while active, same convention as ComboConfig's
-- tiers: 1.0 = +100% rate of fire, 0.5 = +50% damage.
UltimateConfig.FireRate = 1.0
UltimateConfig.Damage = 0.5

--[[
	Charge earned per kill, as a fraction of a full meter, BEFORE the
	combo tier's ChargeMultiplier is applied.

	0.02 means 50 kills to fill at a cold streak and as few as 20 while
	GODLIKE — roughly one ultimate every wave or two early on, more often
	for a player who keeps a streak alive. Charge comes from kills rather
	than damage dealt so that a Tank soaking a whole magazine doesn't
	charge the meter faster than clearing a pack of Normals, which would
	quietly reward shooting the tankiest thing in the room.
]]
UltimateConfig.ChargePerKill = 0.02

return UltimateConfig
