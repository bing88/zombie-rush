--[[
	WeaponConfig.lua
	Tier 1: three weapons. Pistol is the free starter every run begins
	with; AssaultRifle and Shotgun are bought mid-match from the U panel
	with THIS RUN's cash (see ShopService + RunLoadoutService). Nothing
	here persists — a new match always starts pistol-only at level 0.

	Kept data-driven per the Tier 0 comment this replaces — Tier 1 only
	needed more entries here, not an architecture change.
]]

export type WeaponStats = {
	Damage: number, -- per pellet; single-pellet weapons just have one pellet
	FireRate: number, -- seconds between shots
	MagazineSize: number,
	ReloadTime: number,
	Range: number,
	Spread: number, -- degrees of random cone spread, applied per pellet
	HeadshotMultiplier: number,
	Pellets: number, -- >1 for shotgun-style multi-pellet spread
	Price: number, -- coins to unlock in the shop; 0 = free starter weapon

	-- Hotbar / shop row glyph. Empty = text-only slot until art is uploaded
	-- (see docs/ui-icon-design.md — Id matches the weapon key).
	IconId: string,

	-- Optional per-weapon authored Animations, e.g. "rbxassetid://1234567890"
	-- — see WeaponViewController's createIKForTool/playHoldAnimation/
	-- PlayFireAnimation/PlayReloadAnimation. Empty string (the default,
	-- for any of the four below) means "no authored clip yet for this
	-- weapon/slot".
	--
	-- HoldAnimationId (looped, Action priority) is the important one:
	-- if set, it REPLACES both hands' live IK reach entirely for that
	-- weapon, which is stable (no shake) and exactly whatever pose was
	-- authored in Studio — see WeaponIK.lua's header for the full
	-- explanation of why live IK alone couldn't reliably control hand
	-- rotation/barrel tilt. If empty, WeaponViewController falls back
	-- to its live right-hand Position-IK reach instead (also stable,
	-- but leaves the barrel's exact tilt uncontrolled).
	--
	-- FireAnimationId/EquipAnimationId/ReloadAnimationId are all
	-- one-shot, non-looped, and layered ON TOP of whichever hold pose
	-- is active (live IK or HoldAnimationId) — see WeaponViewController.
	-- Each is independently optional; leaving one empty just skips that
	-- specific flourish with no effect on the others.
	HoldAnimationId: string,
	FireAnimationId: string, -- played once per shot (recoil kick)
	EquipAnimationId: string, -- played once when the weapon is drawn
	ReloadAnimationId: string, -- played once per reload, stretched/squashed via AdjustSpeed to exactly match ReloadTime

	-- Optional "exploding projectiles" support (see the official Weapons
	-- Kit docs' https://create.roblox.com/docs/resources/weapons-kit
	-- #exploding-projectiles section). Off (nil/false) for every current
	-- weapon here — Pistol/AssaultRifle/Shotgun are plain bullets, not
	-- grenades/rockets — but WeaponService already checks these three
	-- fields on EVERY hit (see applyExplosionSplash), so a future
	-- explosive weapon (e.g. a Grenade/Rocket Launcher) only needs to
	-- set them here; no other code changes required.
	ExplodeOnImpact: boolean?,
	BlastRadius: number?, -- studs; WeaponService defaults to 8 if ExplodeOnImpact is true but this is omitted
	BlastDamage: number?, -- damage at the center of the blast, falling off linearly to ~15% at the edge; defaults to 100

	-- Optional "charging weapon" support (see the kit's "Charging
	-- weapon"/"Bow weapon" sections). Deliberately NOT wired up to any
	-- live hold-to-charge mechanic yet — no current weapon needs it, and
	-- building/tuning that input flow against a weapon nobody uses would
	-- be untestable dead code. Reserved purely so a future Railgun/
	-- Crossbow-style weapon has an obvious place to put its numbers
	-- instead of inventing a new config shape from scratch. See
	-- README's "Weapons Kit specialized options" section for what's
	-- left to build (client hold-to-charge input + server charge state)
	-- if this is ever actually used.
	ChargeRate: number?,
}

local WeaponConfig: { [string]: WeaponStats } = {
	Pistol = {
		Damage = 18,
		FireRate = 0.25,
		MagazineSize = 12,
		ReloadTime = 1.4,
		Range = 10000,
		Spread = 1.5,
		HeadshotMultiplier = 2,
		Pellets = 1,
		Price = 0,
		IconId = "rbxassetid://135023133887459", -- paste rbxassetid://… from Pistol.png
		-- From src/ServerStorage/MapAssets/Dummy_Pistol_Rifle_Animations.rbxm's
		-- "pistol_animation" dummy's AnimSaves — publish each in Studio's
		-- Animation Editor (see README) and paste the real rbxassetid here.
		HoldAnimationId = "rbxassetid://117481891604262", -- TODO: replace with the dummy's published "Idle"
		FireAnimationId = "rbxassetid://133616950548266",
		EquipAnimationId = "rbxassetid://84579212022532",
		ReloadAnimationId = "rbxassetid://117069107174524",
	},
	AssaultRifle = {
		Damage = 25,
		FireRate = 0.12,
		MagazineSize = 30,
		ReloadTime = 2.0,
		Range = 10000,
		Spread = 2,
		HeadshotMultiplier = 2,
		Pellets = 1,
		Price = 120,
		IconId = "rbxassetid://139869397002241", -- paste rbxassetid://… from AssaultRifle.png
		-- From the same .rbxm's "rifle_animation" dummy's AnimSaves (its
		-- Idle/Fire/Equip/Reload are lowercase-named there).
		HoldAnimationId = "rbxassetid://101513244659838", -- TODO: replace with the dummy's published "idle"
		FireAnimationId = "rbxassetid://92109520836528",
		EquipAnimationId = "rbxassetid://106855502266285",
		ReloadAnimationId = "rbxassetid://137719592080084",
	},
	Shotgun = {
		Damage = 14, -- per pellet; multiple pellets per shot make this hit hard up close and fall off fast at range
		FireRate = 0.45, -- was 0.75; noticeably punchier pump/semi-auto feel
		MagazineSize = 6,
		ReloadTime = 2.4,
		Range = 40,
		Spread = 6,
		HeadshotMultiplier = 1.5,
		Pellets = 8,
		Price = 300,
		IconId = "rbxassetid://133524797480228", -- paste rbxassetid://… from Shotgun.png
		-- No authored dummy rig for the shotgun (yet) — kept on the same
		-- placeholder hold pose as before; falls back to live IK if this
		-- ever goes empty.
		HoldAnimationId = "rbxassetid://101513244659838",
		FireAnimationId = "rbxassetid://92109520836528",
		EquipAnimationId = "rbxassetid://106855502266285",
		ReloadAnimationId = "rbxassetid://137719592080084",
	},
}

-- Not weapon stats — separate fields so callers can safely iterate
-- WeaponConfig by name -> stats without special-casing non-weapon keys.
WeaponConfig.Order = { "Pistol", "AssaultRifle", "Shotgun" }
WeaponConfig.StartingWeapon = "Pistol"

return WeaponConfig
