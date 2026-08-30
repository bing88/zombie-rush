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
]]

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)

local EffectsController = {}

local localPlayer = Players.LocalPlayer

local TRACER_LIFETIME = 0.05
local FLASH_LIFETIME = 0.06
local DAMAGE_NUMBER_LIFETIME = 0.8
local EXPLOSION_LIFETIME = 0.35

local FIRE_SOUND_ID = "rbxasset://sounds/switch.wav" -- placeholder "click"; only used if a weapon has no real "Fired" sound
local HIT_SOUND_ID = "rbxasset://sounds/electronicpingshort.wav" -- placeholder hit-confirm "ping"
local EXPLOSION_SOUND_ID = "rbxasset://sounds/impact_water.mp3" -- placeholder "boom" -- only bundled sound with any real low-end weight
local HIT_TAKEN_SOUND_ID = "rbxassetid://79348298352567" -- Official OOF Sound Effect (https://create.roblox.com/store/asset/79348298352567), played locally when the local player takes damage

local localHitmarkerCallback: ((boolean) -> ())? = nil

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
	Floating "-N" combat text that rises and fades at the hit location.
	BillboardGui always faces the camera automatically, so this reads
	correctly from any angle without extra math.
]]
local function spawnDamageNumber(position: Vector3, damage: number)
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
	billboard.Size = UDim2.fromOffset(120, 40)
	billboard.AlwaysOnTop = true
	billboard.Adornee = anchor
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 22
	label.TextColor3 = Color3.fromRGB(255, 70, 70)
	label.TextStrokeTransparency = 0.3
	label.Text = "-" .. tostring(math.floor(damage + 0.5))
	label.Parent = billboard

	TweenService:Create(
		anchor,
		TweenInfo.new(DAMAGE_NUMBER_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = anchor.Position + Vector3.new(0, 2.5, 0) }
	):Play()

	TweenService:Create(label, TweenInfo.new(DAMAGE_NUMBER_LIFETIME), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()

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

type HitResult = {
	EndPosition: Vector3,
	Hit: boolean,
	Damage: number,
	Killed: boolean,
}

function EffectsController.Init()
	Remotes.WeaponFired.OnClientEvent:Connect(function(
		shooter: Player,
		weaponName: string,
		origin: Vector3,
		hits: { HitResult }
	)
		spawnBurst(origin, Color3.fromRGB(255, 220, 120), 0.5) -- muzzle flash

		local firedSound = findFiredSound(shooter, weaponName)
		if firedSound then
			restartSound(firedSound)
		else
			playSoundAt(origin, FIRE_SOUND_ID, 0.5)
		end

		for _, hit in hits do
			spawnTracer(origin, hit.EndPosition)
			if hit.Hit then
				spawnBurst(hit.EndPosition, Color3.fromRGB(255, 60, 60), 0.4) -- hit spark
				playSoundAt(hit.EndPosition, HIT_SOUND_ID, 0.6)
				spawnDamageNumber(hit.EndPosition, hit.Damage)

				if shooter == localPlayer and localHitmarkerCallback then
					localHitmarkerCallback(hit.Killed == true)
				end
			end
		end
	end)

	Remotes.ZombieRangedAttack.OnClientEvent:Connect(function(_zombieName: string, origin: Vector3, targetPosition: Vector3)
		spawnRangedAttackTracer(origin, targetPosition)
	end)

	Remotes.ZombieExploded.OnClientEvent:Connect(function(position: Vector3, radius: number)
		spawnExplosion(position, radius)
	end)
end

--[[
	Called once per confirmed hit that the LOCAL player scored (not other
	players' shots). killed distinguishes a regular hitmarker from a
	kill-confirm one for whatever UI wants to react (see UIController).
]]
function EffectsController.OnLocalHitmarker(callback: (boolean) -> ())
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
