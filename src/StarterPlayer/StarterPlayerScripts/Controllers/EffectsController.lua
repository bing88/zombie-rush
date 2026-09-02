--[[
	EffectsController.lua (ModuleScript)

	Purely cosmetic: turns each server WeaponFired broadcast into a bullet
	tracer, muzzle flash, fire sound, and — on a confirmed hit — a hit
	spark, hit sound, and a floating "-N" damage number. Runs for every
	player's shots (not just the local player's) so shooting is visible
	and audible to everyone in a match, not just the shooter.

	Tier 1: WeaponFired now carries a per-pellet "hits" array (shotgun
	fires up to 8 pellets per trigger pull) instead of a single endpoint —
	this loops over all of them, drawing one tracer per pellet but only
	one muzzle flash/fire sound per trigger pull.

	None of this affects gameplay — it's reacting to what the server has
	already decided happened, using the origin/endpoint/damage it computed.

	Fire sound: each real Weapons Kit asset ships its own "Fired" Sound
	as a descendant of the weapon model (see
	https://create.roblox.com/docs/resources/weapons-kit#weapon-model) —
	WeaponModelFactory never strips Sounds, so it's still sitting on the
	shooter's actual equipped Tool, already correctly 3D-positioned via
	the Handle. This plays *that* sound directly (same instance every
	client already has via normal replication) instead of a generic
	placeholder, falling back to the placeholder only for a weapon that
	doesn't have one.

	Hit sound ID below (rbxasset://sounds/...) is one of Roblox's own
	bundled client sounds — guaranteed to be present with no catalog/
	ownership dependency, which makes it a safe placeholder until real
	hit SFX exists (see plan Phase 8 — Polish).

	Weapons Kit specialized options (see
	https://create.roblox.com/docs/resources/weapons-kit#specialized-
	options): everything below that touches a "tool" argument looks for
	the REAL asset's own self-contained descendants first — Bolt/
	BoltMotor/BoltMotorStart/BoltMotorTarget (+ optional BoltOpenSound/
	BoltCloseSound), CasingEjectPoint, and a MuzzleFlash Beam — since
	those live directly on the weapon model per the kit's docs. What we
	deliberately never have is the kit's separate WeaponsSystem/Assets
	library (Shots/Casings/HitMarks templates) — see
	WeaponModelFactory's header for why that whole framework folder is
	never imported — so muzzle particles, the spent-casing shape itself,
	the tracer/trail look, and hit-mark decals are all our own
	procedural substitutes rather than the kit's original art, built
	from scratch below. Every one of these gracefully no-ops if the
	expected descendant isn't found (e.g. the placeholder Tool, or a
	real asset that simply doesn't have a Bolt) — nothing here can error
	or visually break a weapon that lacks the optional structure.

	Exploding projectiles (WeaponExploded) reuses spawnExplosion — the
	exact same blast VFX/sound already built for an Exploder zombie's
	own detonation — since visually "a blast is a blast" regardless of
	what caused it.

	Charging weapon / Bow weapon (the kit's other two specialized
	options) are NOT implemented anywhere in this file — see
	WeaponConfig's ChargeRate doc comment for why (no current weapon
	needs either, so there's nothing real to wire up or test yet).
]]

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local UltimateConfig = require(ReplicatedStorage.Shared.UltimateConfig)

local EffectsController = {}

local localPlayer = Players.LocalPlayer

local TRACER_LIFETIME = 0.05
local FLASH_LIFETIME = 0.06
local DAMAGE_NUMBER_LIFETIME = 0.8
local EXPLOSION_LIFETIME = 0.35

local FIRE_SOUND_ID = "rbxasset://sounds/switch.wav" -- placeholder "click"; only used if a weapon has no real "Fired" sound
local HIT_SOUND_ID = "rbxasset://sounds/electronicpingshort.wav" -- placeholder hit-confirm "ping"
-- Headshots get their own, deliberately meatier confirm sound layered
-- UNDER the normal hit ping rather than replacing it, so a headshot
-- reads as "hit, plus something extra" instead of a different event.
local HEADSHOT_SOUND_ID = "rbxasset://sounds/metal.ogg"
local EXPLOSION_SOUND_ID = "rbxasset://sounds/impact_water.mp3" -- placeholder "boom" -- only bundled sound with any real low-end weight
local HIT_TAKEN_SOUND_ID = "rbxassetid://79348298352567" -- Official OOF Sound Effect (https://create.roblox.com/store/asset/79348298352567), played locally when the local player takes damage

-- Ejected casings + environment hit marks are physically-simulated/
-- long-lived (unlike the flash/tracer/spark, which are already gone
-- within a fraction of a second) — capped so a long session doesn't
-- slowly accumulate parts forever; oldest gets force-cleaned once over
-- the cap, well before Debris would've gotten to it naturally.
local MAX_ACTIVE_CASINGS = 40
local MAX_ACTIVE_HIT_MARKS = 40
local activeCasings: { BasePart } = {}
local activeHitMarks: { BasePart } = {}

local CASING_LIFETIME = 4
local HIT_MARK_OPAQUE_TIME = 4 -- matches the kit's own BulletHole decal behavior (opaque for 4s, then fades)
local HIT_MARK_FADE_TIME = 1
local MUZZLE_FLASH_BEAM_TIME = 0.03 -- kit's own default MuzzleFlashTime

local DAMAGE_NUMBER_COLOR = Color3.fromRGB(255, 70, 70)
local HEADSHOT_NUMBER_COLOR = Color3.fromRGB(255, 205, 70) -- gold, matching the kill hitmarker's own gold

local localHitmarkerCallback: ((boolean, boolean) -> ())? = nil

--[[
	Procedural muzzle-particle template (see spawnMuzzleParticles) —
	built once and :Clone()'d per shot rather than per-frame, since a
	brand new ParticleEmitter has to be created either way (Emit()'d
	particles die with their emitter, so it can't just be a single
	shared/reused instance across simultaneous shooters). Never itself
	parented anywhere; only ever cloned.
]]
local muzzleParticleTemplate = Instance.new("ParticleEmitter")
muzzleParticleTemplate.Name = "MuzzleParticlesFX"
muzzleParticleTemplate.Color = ColorSequence.new(Color3.fromRGB(255, 210, 140), Color3.fromRGB(90, 90, 90))
muzzleParticleTemplate.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.15),
	NumberSequenceKeypoint.new(1, 0.55),
})
muzzleParticleTemplate.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.15),
	NumberSequenceKeypoint.new(1, 1),
})
muzzleParticleTemplate.Lifetime = NumberRange.new(0.12, 0.28)
muzzleParticleTemplate.Speed = NumberRange.new(5, 10)
muzzleParticleTemplate.SpreadAngle = Vector2.new(20, 20)
muzzleParticleTemplate.Rate = 0 -- never continuous; only ever :Emit()'d on demand below
muzzleParticleTemplate.Enabled = false

--[[
	Blood impact template, cloned per zombie hit by spawnBloodImpact —
	same clone-per-use reasoning as muzzleParticleTemplate above.

	Previously a hit on a zombie and a hit on a wall produced the SAME
	generic red neon spark, so shots didn't read as landing on flesh at
	all. Particles are given real Speed + Acceleration (gravity) so the
	spray arcs and falls instead of puffing symmetrically outward like
	smoke, which is what separates "blood" from "spark" visually.
]]
local bloodParticleTemplate = Instance.new("ParticleEmitter")
bloodParticleTemplate.Name = "BloodImpactFX"
bloodParticleTemplate.Color = ColorSequence.new(Color3.fromRGB(140, 12, 12), Color3.fromRGB(70, 4, 4))
bloodParticleTemplate.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.28),
	NumberSequenceKeypoint.new(1, 0.08),
})
bloodParticleTemplate.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.1),
	NumberSequenceKeypoint.new(0.7, 0.3),
	NumberSequenceKeypoint.new(1, 1),
})
bloodParticleTemplate.Lifetime = NumberRange.new(0.25, 0.5)
bloodParticleTemplate.Speed = NumberRange.new(8, 16)
bloodParticleTemplate.SpreadAngle = Vector2.new(28, 28)
bloodParticleTemplate.Acceleration = Vector3.new(0, -60, 0)
bloodParticleTemplate.Drag = 2
bloodParticleTemplate.LightEmission = 0
bloodParticleTemplate.Rate = 0
bloodParticleTemplate.Enabled = false

--[[
	Keeps a rolling window of at most `cap` cosmetic instances, force-
	destroying the oldest the moment a new one would push it over the
	cap — see MAX_ACTIVE_CASINGS/MAX_ACTIVE_HIT_MARKS above.
]]
local function trackCapped(list: { BasePart }, instance: BasePart, cap: number)
	table.insert(list, instance)
	if #list > cap then
		local oldest = table.remove(list, 1)
		if oldest and oldest.Parent then
			oldest:Destroy()
		end
	end
end

--[[
	"Particle trails" (see the kit's docs) — real projectile flight
	would need reworking every weapon into a travel-time bullet, which
	risks the game's whole hitscan feel; instead this keeps the existing
	instant beam but has it visibly FADE OUT (tween Transparency to 1)
	rather than just vanish the moment Debris ticks over, so it reads
	as a dissipating trail left behind rather than a flickering static
	line — the cheapest version of "a trail behind the shot" that
	doesn't touch gameplay/hit-timing at all.
]]
local function spawnTracer(origin: Vector3, endPoint: Vector3)
	local distance = (endPoint - origin).Magnitude
	if distance < 0.1 then
		return
	end

	local tracer = Instance.new("Part")
	tracer.Name = "Tracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(255, 240, 150)
	tracer.Size = Vector3.new(0.08, 0.08, distance)
	tracer.CFrame = CFrame.new(origin, endPoint) * CFrame.new(0, 0, -distance / 2)
	tracer.Parent = workspace

	TweenService:Create(tracer, TweenInfo.new(TRACER_LIFETIME, Enum.EasingStyle.Quad), { Transparency = 1 }):Play()
	Debris:AddItem(tracer, TRACER_LIFETIME)
end

local function spawnBurst(position: Vector3, color: Color3, size: number)
	local burst = Instance.new("Part")
	burst.Name = "EffectBurst"
	burst.Shape = Enum.PartType.Ball
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.Material = Enum.Material.Neon
	burst.Color = color
	burst.Size = Vector3.new(size, size, size)
	burst.Position = position
	burst.Parent = workspace

	Debris:AddItem(burst, FLASH_LIFETIME)
end

--[[
	Client-side raycast purely for a plausible-looking INSTANT tracer
	endpoint — this is never used for damage or hit registration, which
	stays entirely server-side (see WeaponService). If this local guess
	turns out visually wrong (e.g. it grazed something the server didn't
	register, due to the same replication lag that motivated this in the
	first place), the only consequence is a cosmetic tracer landing a
	few studs off for one 0.05s-lived beam — never a gameplay effect.
]]
local function localPredictedEndpoint(origin: Vector3, direction: Vector3, range: number): Vector3
	local character = localPlayer.Character
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = character and { character } or {}

	local result = workspace:Raycast(origin, direction.Unit * range, raycastParams)
	if result then
		return result.Position
	end
	return origin + direction.Unit * range
end

--[[
	Plays a positional (3D) sound at a world position. Uses a short-lived
	invisible anchored part as the sound's emitter so volume falls off
	with distance — useful in multiplayer so a shot across the map isn't
	as loud as one right next to you. Lives longer than the sound clip
	itself so playback isn't cut off by early cleanup.
]]
local function playSoundAt(position: Vector3, soundId: string, volume: number)
	local emitter = Instance.new("Part")
	emitter.Name = "SoundEmitter"
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.Transparency = 1
	emitter.Size = Vector3.new(0.1, 0.1, 0.1)
	emitter.Position = position
	emitter.Parent = workspace

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.RollOffMinDistance = 5
	sound.RollOffMaxDistance = 150
	sound.Parent = emitter
	sound:Play()

	Debris:AddItem(emitter, 2) -- safety buffer well past any short clip's length
end

--[[
	Restarts (rather than just Play()s) so rapid automatic fire retriggers
	the sound from the beginning every shot instead of Play() silently
	no-oping on a Sound that's still playing out its previous shot.
]]
local function restartSound(sound: Sound)
	sound.TimePosition = 0
	sound:Play()
end

--[[
	Finds the exact Tool that fired (the shooter's currently equipped
	one, verified by name in case of a rare desync) so its own bundled
	"Fired" Sound (see module doc comment) can be played instead of a
	generic placeholder.
]]
local function findFiredSound(shooter: Player, weaponName: string): Sound?
	local character = shooter.Character
	if not character then
		return nil
	end
	local tool = character:FindFirstChildOfClass("Tool")
	if not tool or tool.Name ~= weaponName then
		return nil
	end
	local sound = tool:FindFirstChild("Fired", true)
	if sound and sound:IsA("Sound") then
		return sound
	end
	return nil
end

--[[
	Finds whichever Tool a given player currently has equipped (Backpack
	Tools are unequipped/not in the Character, so this only ever returns
	a Tool while one is actually out) — the shared lookup every
	specialized-option helper below needs, since all of them read
	weapon-model-specific descendants off the actual equipped Tool.
]]
local function findEquippedTool(player: Player): Tool?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Tool") :: Tool?
end

--[[
	"Muzzle particles" (see the kit's docs) — a quick smoke/spark puff
	from the Muzzle attachment on every shot. The kit's own version
	reads a ShotEffect's particle template out of its separate
	WeaponsSystem/Assets library, which we never imported (see this
	file's header) — so this is our own procedural stand-in, cloned from
	muzzleParticleTemplate above and :Emit()'d once. Cheap even at high
	fire rates since Rate stays 0 (no continuous emission, ever).
]]
local function spawnMuzzleParticles(muzzleAttachment: Attachment)
	local emitter = muzzleParticleTemplate:Clone()
	emitter.Parent = muzzleAttachment
	emitter:Emit(math.random(10, 16))
	Debris:AddItem(emitter, 1) -- outlives the longest possible particle Lifetime (0.28s) with margin
end

local CASING_COLOR = Color3.fromRGB(198, 162, 64)

--[[
	"Ejected bullet casings" (see the kit's docs). Prefers the real
	asset's own documented CasingEjectPoint attachment (its ORIENTATION,
	per the docs, decides eject direction) when present; otherwise falls
	back to a heuristic pop-out-the-right-side offset off the Handle, so
	every weapon gets a casing even the placeholder/undocumented ones.
	The casing shape/material itself is entirely ours — the kit's own
	casing template lives in its separate Assets/Effects/Casings
	library, which (like the ShotEffect library) was never imported.
]]
local function spawnCasingEject(tool: Tool?)
	if not tool then
		return
	end
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end

	local ejectPoint = handle:FindFirstChild("CasingEjectPoint", true) :: Attachment?
	local originCFrame: CFrame
	local ejectDirection: Vector3
	if ejectPoint and ejectPoint:IsA("Attachment") then
		originCFrame = ejectPoint.WorldCFrame
		ejectDirection = originCFrame.LookVector
	else
		originCFrame = handle.CFrame * CFrame.new(handle.Size.X * 0.5, handle.Size.Y * 0.15, 0)
		ejectDirection = handle.CFrame.RightVector
	end

	local casing = Instance.new("Part")
	casing.Name = "SpentCasing"
	casing.Size = Vector3.new(0.06, 0.06, 0.16)
	casing.Color = CASING_COLOR
	casing.Material = Enum.Material.Metal
	casing.CanCollide = true
	casing.CanQuery = false
	casing.CastShadow = false
	casing.CFrame = originCFrame
	casing.Parent = workspace

	-- CasingEjectSpeedMin/Max defaults per the kit's own docs (15-18 studs/s).
	local speed = math.random(15, 18)
	casing.AssemblyLinearVelocity = ejectDirection * speed + Vector3.new(0, math.random(2, 5), 0)
	casing.AssemblyAngularVelocity = Vector3.new(math.random(-25, 25), math.random(-25, 25), math.random(-25, 25))

	trackCapped(activeCasings, casing, MAX_ACTIVE_CASINGS)
	Debris:AddItem(casing, CASING_LIFETIME)
end

--[[
	"Bolt animations and sounds" (see the kit's docs). Looks for the
	real asset's own BoltMotor/BoltMotorStart/BoltMotorTarget — all
	self-contained on the weapon model itself, not part of the separate
	Assets library, so an asset that ships them works with ZERO extra
	art from us. Tweens the motor's C0 from its resting pose out to the
	"open" pose (derived from the two attachments' relative offset) and
	back, playing BoltOpenSound/BoltCloseSound if present. Silently does
	nothing for any weapon without this structure (most won't have one)
	— see WeaponModelFactory's ensureHandle for why a Bolt part's own
	Motor6D survives Tool-building without also getting a rigid
	WeldConstraint fighting it.
]]
local function cycleBoltAnimation(tool: Tool?)
	if not tool then
		return
	end
	local boltMotor = tool:FindFirstChild("BoltMotor", true) :: Motor6D?
	local boltStart = tool:FindFirstChild("BoltMotorStart", true) :: Attachment?
	local boltTarget = tool:FindFirstChild("BoltMotorTarget", true) :: Attachment?
	if not (boltMotor and boltMotor:IsA("Motor6D") and boltStart and boltTarget) then
		return
	end

	local restC0 = boltMotor.C0
	local openOffset = boltStart.WorldCFrame:ToObjectSpace(boltTarget.WorldCFrame)

	local openSound = tool:FindFirstChild("BoltOpenSound", true) :: Sound?
	local closeSound = tool:FindFirstChild("BoltCloseSound", true) :: Sound?

	-- ActionOpenTime/ActionCloseTime defaults per the kit's own docs.
	local openTween = TweenService:Create(boltMotor, TweenInfo.new(0.025, Enum.EasingStyle.Sine), { C0 = restC0 * openOffset })
	openTween:Play()
	if openSound then
		restartSound(openSound)
	end

	openTween.Completed:Once(function()
		if boltMotor.Parent then
			TweenService:Create(boltMotor, TweenInfo.new(0.075, Enum.EasingStyle.Sine), { C0 = restC0 }):Play()
		end
		if closeSound then
			restartSound(closeSound)
		end
	end)
end

--[[
	Bundles the three "fires every shot, needs the actual Tool"
	specialized options together — called once for the local shooter's
	own instant shot (see SpawnLocalWeaponFireExtras) and once for every
	OTHER player's shot via the WeaponFired broadcast (mirroring the
	existing "skip for local, they already got it instantly" pattern
	used by the muzzle flash/tracer below).
]]
local function spawnWeaponFireExtras(tool: Tool?)
	if not tool then
		return
	end
	local handle = tool:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("Attachment") then
		spawnMuzzleParticles(muzzle)
	end
	spawnCasingEject(tool)
	cycleBoltAnimation(tool)
end

--[[
	"Muzzle flashes" (see the kit's docs). Prefers the real asset's own
	documented MuzzleFlash Beam (self-contained on the weapon model,
	between its MuzzleFlash0/MuzzleFlash1 attachments) if present —
	briefly toggling Enabled with a randomized width, exactly matching
	the kit's own MuzzleFlashTime/MuzzleFlashSize0-1 behavior — else
	falls back to the existing procedural neon-ball burst. Either way,
	also pops a real dynamic PointLight for a moment so the flash
	actually casts a bit of light on nearby surfaces/the character,
	which neither the beam nor a flat neon ball do on their own.
]]
local function flashRealMuzzleBeam(tool: Tool?): boolean
	if not tool then
		return false
	end
	local beam = tool:FindFirstChild("MuzzleFlash", true) :: Beam?
	if not beam or not beam:IsA("Beam") then
		return false
	end
	-- MuzzleFlashSize0/1 default to 1 per the kit's docs; randomized a
	-- little for some shot-to-shot visual variety.
	beam.Width0 = math.random(85, 115) / 100
	beam.Width1 = math.random(85, 115) / 100
	beam.Enabled = true
	task.delay(MUZZLE_FLASH_BEAM_TIME, function()
		if beam.Parent then
			beam.Enabled = false
		end
	end)
	return true
end

local function spawnMuzzleFlashLight(position: Vector3)
	local lightHolder = Instance.new("Part")
	lightHolder.Name = "MuzzleFlashLight"
	lightHolder.Anchored = true
	lightHolder.CanCollide = false
	lightHolder.CanQuery = false
	lightHolder.Transparency = 1
	lightHolder.Size = Vector3.new(0.1, 0.1, 0.1)
	lightHolder.Position = position
	lightHolder.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 200, 120)
	light.Brightness = 6
	light.Range = 12
	light.Shadows = false
	light.Parent = lightHolder

	Debris:AddItem(lightHolder, 0.08)
end

local function spawnMuzzleFlash(tool: Tool?, position: Vector3)
	local usedRealBeam = flashRealMuzzleBeam(tool)
	if not usedRealBeam then
		spawnBurst(position, Color3.fromRGB(255, 220, 120), 0.4 + math.random() * 0.25)
	end
	spawnMuzzleFlashLight(position)
end

local HIT_MARK_COLOR = Color3.fromRGB(25, 22, 20)

--[[
	"Hit marks" (see the kit's docs) — a fading scorch/bullet-hole mark
	where a shot hit plain environment geometry (see WeaponService's
	resolvePellet, which only ever sends `normal` for that case, never
	for a zombie/player hit). No image asset needed: a small flat part,
	oriented flush against the surface facing outward along the hit
	normal (AlignHitMarkToNormal-style, per the kit's docs), opaque for
	HIT_MARK_OPAQUE_TIME then fading over HIT_MARK_FADE_TIME — matching
	the kit's own BulletHole decal timing.
]]
local function spawnHitMark(position: Vector3, normal: Vector3?)
	if not normal or normal.Magnitude < 0.1 then
		return
	end

	local mark = Instance.new("Part")
	mark.Name = "HitMark"
	mark.Size = Vector3.new(0.3, 0.3, 0.02)
	mark.Anchored = true
	mark.CanCollide = false
	mark.CanQuery = false
	mark.CastShadow = false
	mark.Material = Enum.Material.SmoothPlastic
	mark.Color = HIT_MARK_COLOR
	mark.CFrame = CFrame.lookAt(position + normal * 0.03, position + normal * 0.03 + normal)
	mark.Parent = workspace

	trackCapped(activeHitMarks, mark, MAX_ACTIVE_HIT_MARKS)

	task.delay(HIT_MARK_OPAQUE_TIME, function()
		if mark.Parent then
			TweenService:Create(mark, TweenInfo.new(HIT_MARK_FADE_TIME), { Transparency = 1 }):Play()
		end
	end)
	Debris:AddItem(mark, HIT_MARK_OPAQUE_TIME + HIT_MARK_FADE_TIME + 0.1)
end

--[[
	Blood spray at a confirmed zombie hit (see bloodParticleTemplate).
	Emits back along the shot's own travel direction where known, so the
	spray kicks out of the entry side rather than always straight up;
	headshots emit noticeably more of it, which is half of what sells a
	headshot as landing somewhere that matters.

	Parented to a throwaway anchor part rather than the zombie itself:
	the zombie may be destroyed within ~2 seconds of dying (see
	ZombieService's onDeath), which would take an attached emitter's
	still-airborne particles with it mid-flight.
]]
local function spawnBloodImpact(position: Vector3, isHeadshot: boolean)
	local anchor = Instance.new("Part")
	anchor.Name = "BloodImpactAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Position = position
	anchor.Parent = workspace

	local emitter = bloodParticleTemplate:Clone()
	emitter.Parent = anchor
	emitter:Emit(isHeadshot and 26 or 12)

	Debris:AddItem(anchor, 1) -- comfortably past the template's own 0.5s max Lifetime
end

--[[
	Floating "-N" combat text that rises and fades at the hit location.
	BillboardGui always faces the camera automatically, so this reads
	correctly from any angle without extra math.

	Headshots get the gold treatment — bigger text, gold instead of red,
	and a "HEADSHOT" caption above the number (doc-recommended crit
	feedback) — since a headshot already does 1.5-2x damage and had no
	on-screen distinction from a body shot whatsoever before this.
]]
local function spawnDamageNumber(position: Vector3, damage: number, isHeadshot: boolean)
	local anchor = Instance.new("Part")
	anchor.Name = "DamageNumberAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Position = position + Vector3.new(0, 1, 0)
	anchor.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.Size = UDim2.fromOffset(120, isHeadshot and 56 or 40)
	billboard.AlwaysOnTop = true
	billboard.Adornee = anchor
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	-- Headshots reserve the top strip of the billboard for the caption
	-- below, so the number sits under it instead of overlapping it.
	label.Size = isHeadshot and UDim2.new(1, 0, 0.62, 0) or UDim2.fromScale(1, 1)
	label.Position = isHeadshot and UDim2.new(0, 0, 0.38, 0) or UDim2.fromScale(0, 0)
	label.Font = Enum.Font.GothamBold
	label.TextSize = isHeadshot and 30 or 22
	label.TextColor3 = isHeadshot and HEADSHOT_NUMBER_COLOR or DAMAGE_NUMBER_COLOR
	label.TextStrokeTransparency = 0.3
	label.Text = "-" .. tostring(math.floor(damage + 0.5))
	label.Parent = billboard

	local caption: TextLabel? = nil
	if isHeadshot then
		caption = Instance.new("TextLabel")
		caption.Name = "HeadshotCaption"
		caption.BackgroundTransparency = 1
		caption.Size = UDim2.new(1, 0, 0.38, 0)
		caption.Font = Enum.Font.GothamBlack
		caption.TextSize = 14
		caption.TextColor3 = HEADSHOT_NUMBER_COLOR
		caption.TextStrokeTransparency = 0.3
		caption.Text = "HEADSHOT"
		caption.Parent = billboard
	end

	TweenService:Create(
		anchor,
		TweenInfo.new(DAMAGE_NUMBER_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = anchor.Position + Vector3.new(0, 2.5, 0) }
	):Play()

	local fade = TweenInfo.new(DAMAGE_NUMBER_LIFETIME)
	TweenService:Create(label, fade, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	if caption then
		TweenService:Create(caption, fade, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
	end

	Debris:AddItem(anchor, DAMAGE_NUMBER_LIFETIME + 0.1)
end

--[[
	Green tracer for a Ranged zombie's attack — same drawing code as the
	player's own tracer but a distinct color, so it's readable at a
	glance which shots are incoming vs. outgoing.
]]
local function spawnRangedAttackTracer(origin: Vector3, endPoint: Vector3)
	local distance = (endPoint - origin).Magnitude
	if distance < 0.1 then
		return
	end

	local tracer = Instance.new("Part")
	tracer.Name = "ZombieRangedTracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(120, 220, 90)
	tracer.Size = Vector3.new(0.12, 0.12, distance)
	tracer.CFrame = CFrame.new(origin, endPoint) * CFrame.new(0, 0, -distance / 2)
	tracer.Parent = workspace

	Debris:AddItem(tracer, 0.12) -- slightly longer than the player's own tracer so an incoming shot reads clearly
end

--[[
	Expanding ring + burst for an Exploder zombie's detonation. Purely
	visual — the actual damage was already applied server-side before
	this remote fired.
]]
local function spawnExplosion(position: Vector3, radius: number)
	spawnBurst(position, Color3.fromRGB(255, 140, 40), 3)
	playSoundAt(position, EXPLOSION_SOUND_ID, 0.8)

	local ring = Instance.new("Part")
	ring.Name = "ExplosionRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 160, 60)
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.2, 1, 1)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace

	TweenService:Create(ring, TweenInfo.new(EXPLOSION_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()

	Debris:AddItem(ring, EXPLOSION_LIFETIME + 0.1)
end

--[[
	Berserk aura: a coloured outline plus a light on whoever just spent
	their ultimate, for its duration (plan section 20).

	Shown for EVERY player, including other people's activations, which
	is why it's driven by a broadcast remote rather than done locally by
	the activating client — in a co-op fight, a teammate going berserk
	is worth seeing.

	A Highlight rather than particles or a material swap: it reads
	through walls and through other players, it needs no attachment
	points on a rig whose structure varies (toolbox zombie models and
	R15 players both pass through here), and it costs one instance that
	Debris removes on a timer. Nothing here touches physics or joints,
	which is what makes it safe to hang off a live character — see
	WeaponViewController's header for what happens when client-side
	cosmetics do touch a character's joints.
]]
local function spawnBerserkAura(activatingPlayer: Player, durationSeconds: number)
	local character = activatingPlayer and activatingPlayer.Character
	if not character then
		return
	end

	-- Replace rather than stack, so a re-activation can't leave two
	-- highlights fighting over the same character.
	local existing = character:FindFirstChild("BerserkAura")
	if existing then
		existing:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "BerserkAura"
	highlight.FillColor = UltimateConfig.Color
	highlight.FillTransparency = 0.65
	highlight.OutlineColor = UltimateConfig.Color
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = character
	highlight.Parent = character
	Debris:AddItem(highlight, durationSeconds)

	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		local light = Instance.new("PointLight")
		light.Name = "BerserkLight"
		light.Color = UltimateConfig.Color
		light.Brightness = 4
		light.Range = 14
		light.Parent = torso
		Debris:AddItem(light, durationSeconds)
	end
end

type HitResult = {
	EndPosition: Vector3,
	Hit: boolean,
	Damage: number,
	Killed: boolean,
	SurfaceNormal: Vector3?,
	SurfaceMaterial: Enum.Material?,
	Headshot: boolean?, -- only ever set for a zombie hit, see WeaponService's resolvePellet
}

function EffectsController.Init()
	Remotes.WeaponFired.OnClientEvent:Connect(function(
		shooter: Player,
		weaponName: string,
		origin: Vector3,
		hits: { HitResult }
	)
		-- The local shooter already saw their own instant muzzle flash
		-- the moment they fired (see SpawnLocalMuzzleFlash, called
		-- directly from WeaponController with zero network round-trip).
		-- Drawing it AGAIN here, once this broadcast finally arrives
		-- back after a full client->server->client round trip, is
		-- exactly the "still trailing" symptom — the origin value was
		-- already fixed to be accurate, but accuracy doesn't fix
		-- LATENCY: by the time this event lands, the player has kept
		-- moving, so a flash appearing only now unavoidably reads as
		-- behind wherever they currently are. Skipping it here for the
		-- local player (everyone else still sees it exactly as before)
		-- is what actually removes the trailing feel, since their own
		-- flash never waited on the network at all.
		if shooter ~= localPlayer then
			local shooterTool = findEquippedTool(shooter)
			spawnMuzzleFlash(shooterTool, origin) -- muzzle flash (+ dynamic light)
			spawnWeaponFireExtras(shooterTool) -- muzzle particles + ejected casing + bolt cycle
		end

		local firedSound = findFiredSound(shooter, weaponName)
		if firedSound then
			restartSound(firedSound)
		else
			playSoundAt(origin, FIRE_SOUND_ID, 0.5)
		end

		for _, hit in hits do
			-- Skip drawing the beam itself for the local player's own
			-- shots — SpawnLocalTracer (below) already drew one
			-- instantly, with zero network wait. Everyone else's shots
			-- still draw their tracer here exactly as before; this was
			-- never laggy for anyone watching someone ELSE shoot, only
			-- for the shooter watching their own gun.
			if shooter ~= localPlayer then
				spawnTracer(origin, hit.EndPosition)
			end
			if hit.Hit then
				local isHeadshot = hit.Headshot == true

				spawnBloodImpact(hit.EndPosition, isHeadshot)
				playSoundAt(hit.EndPosition, HIT_SOUND_ID, 0.6)
				if isHeadshot then
					-- Layered under the normal ping above, not instead
					-- of it (see HEADSHOT_SOUND_ID).
					playSoundAt(hit.EndPosition, HEADSHOT_SOUND_ID, 0.75)
				end
				spawnDamageNumber(hit.EndPosition, hit.Damage, isHeadshot)

				if shooter == localPlayer and localHitmarkerCallback then
					localHitmarkerCallback(hit.Killed == true, isHeadshot)
				end
			elseif hit.SurfaceNormal then
				-- Missed a zombie but still hit plain geometry — "hit
				-- marks" (see the kit's docs), shown for everyone's
				-- shots (not skipped for the local player) since this
				-- is about where the bullet landed on the wall, not
				-- about the shooter's own perceived position.
				spawnHitMark(hit.EndPosition, hit.SurfaceNormal)
			end
		end
	end)

	Remotes.ZombieRangedAttack.OnClientEvent:Connect(function(_zombieName: string, origin: Vector3, targetPosition: Vector3)
		spawnRangedAttackTracer(origin, targetPosition)
	end)

	Remotes.ZombieExploded.OnClientEvent:Connect(function(position: Vector3, radius: number)
		spawnExplosion(position, radius)
	end)

	-- "Exploding projectiles" (see the kit's docs) — an ExplodeOnImpact
	-- weapon's shot detonating; reuses the exact same blast VFX/sound
	-- as an Exploder zombie's own detonation (see spawnExplosion above).
	Remotes.WeaponExploded.OnClientEvent:Connect(function(position: Vector3, radius: number)
		spawnExplosion(position, radius)
	end)

	Remotes.UltimateActivated.OnClientEvent:Connect(function(activatingPlayer: Player, durationSeconds: number)
		spawnBerserkAura(activatingPlayer, durationSeconds)
	end)
end

--[[
	Instant, zero-latency muzzle flash for the local player's own shot —
	called directly from WeaponController the moment a shot is fired
	client-side, using the shooter's own current muzzle position, rather
	than waiting for the server's WeaponFired echo (which is skipped for
	the local player specifically to avoid a duplicate/second flash —
	see the Init() handler above). This is the actual fix for "the flash
	trails behind while moving": it's not a timing/network-bound effect
	for the shooter at all anymore, just an immediate local visual.
]]
function EffectsController.SpawnLocalMuzzleFlash(origin: Vector3)
	spawnMuzzleFlash(findEquippedTool(localPlayer), origin)
end

--[[
	Instant local counterpart to spawnWeaponFireExtras (muzzle particles
	+ ejected casing + bolt cycle) for the local player's own shot —
	same zero-network-wait reasoning as SpawnLocalMuzzleFlash/
	SpawnLocalTracer above. Call this alongside those two right when the
	local shot fires (see ClientMain's OnLocalFire wiring).
]]
function EffectsController.SpawnLocalWeaponFireExtras()
	spawnWeaponFireExtras(findEquippedTool(localPlayer))
end

--[[
	Instant local tracer beam for the local player's own shot — the
	previous muzzle-flash-only fix left the tracer (a full beam, far
	more visually obvious than the small flash) still exclusively
	server-broadcast-driven, so it still visibly trailed a moving
	shooter even after that fix. Uses its own local raycast purely to
	pick a plausible endpoint (see localPredictedEndpoint's doc comment
	— this never touches damage/hit registration, which stays entirely
	server-side). One tracer per trigger pull regardless of pellet count
	— for the shotgun this shows a single clean line instead of a full
	8-pellet spread for your OWN shots specifically (other players still
	see the real per-pellet spread when watching you fire), a reasonable
	simplification given the beam itself is barely visible for its
	0.05s lifetime anyway.
]]
function EffectsController.SpawnLocalTracer(origin: Vector3, direction: Vector3, range: number)
	local endPoint = localPredictedEndpoint(origin, direction, range)
	spawnTracer(origin, endPoint)
end

--[[
	Called once per confirmed hit that the LOCAL player scored (not other
	players' shots). killed and headshot distinguish a regular hitmarker
	from a kill-confirm and a headshot one for whatever UI wants to
	react (see UIController.ShowHitmarker).
]]
function EffectsController.OnLocalHitmarker(callback: (boolean, boolean) -> ())
	localHitmarkerCallback = callback
end

--[[
	The classic "oof" — plays only for the local player, right when their
	own HP drops (see ClientMain's PlayerHPChanged handler, which already
	distinguishes a decrease/damage from an increase/heal so this never
	fires on a heal or revive). Parented under SoundService rather than a
	BasePart so it's non-positional — personal damage feedback at a
	consistent volume, not a 3D world sound anyone else hears.
]]
function EffectsController.PlayLocalHitSound()
	local sound = Instance.new("Sound")
	sound.SoundId = HIT_TAKEN_SOUND_ID
	sound.Volume = 0.65
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3) -- safety buffer well past the clip's length
end

return EffectsController
