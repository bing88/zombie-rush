--[[
	EffectsController.lua (ModuleScript)

	Purely cosmetic: turns each server WeaponFired broadcast into a bullet
	tracer, muzzle flash, fire sound, and — on a confirmed hit — a hit
	spark, hit sound, and a floating "-N" damage number. Runs for every
	player's shots (not just the local player's) so shooting is visible
	and audible to everyone in a match, not just the shooter.

	None of this affects gameplay — it's reacting to what the server has
	already decided happened, using the origin/endpoint/damage it computed.

	Sound IDs below (rbxasset://sounds/...) are Roblox's own bundled
	client sounds — the same ones Roblox's default scripts use internally.
	They're guaranteed to be present with no catalog/ownership dependency,
	which makes them a safe placeholder. Swap SoundId below for real SFX
	asset IDs whenever real audio is ready (see plan Phase 8 — Polish).
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)

local EffectsController = {}

local TRACER_LIFETIME = 0.05
local FLASH_LIFETIME = 0.06
local DAMAGE_NUMBER_LIFETIME = 0.8

local FIRE_SOUND_ID = "rbxasset://sounds/switch.wav" -- placeholder "click"; swap for a real gunshot SFX later
local HIT_SOUND_ID = "rbxasset://sounds/electronicpingshort.wav" -- placeholder hit-confirm "ping"

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

function EffectsController.Init()
	Remotes.WeaponFired.OnClientEvent:Connect(function(
		_shooter: Player,
		origin: Vector3,
		endPoint: Vector3,
		hitZombie: boolean,
		damageDealt: number
	)
		spawnTracer(origin, endPoint)
		spawnBurst(origin, Color3.fromRGB(255, 220, 120), 0.5) -- muzzle flash
		playSoundAt(origin, FIRE_SOUND_ID, 0.5)

		if hitZombie then
			spawnBurst(endPoint, Color3.fromRGB(255, 60, 60), 0.4) -- hit spark
			playSoundAt(endPoint, HIT_SOUND_ID, 0.6)
			spawnDamageNumber(endPoint, damageDealt)
		end
	end)
end

return EffectsController
