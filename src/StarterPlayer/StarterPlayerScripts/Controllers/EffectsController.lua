--[[
	EffectsController.lua (ModuleScript)

	Purely cosmetic: draws a bullet tracer and small flash/spark effects
	whenever the server reports a shot via WeaponFired. Runs for every
	player's shots (not just the local player's) so shooting is visible to
	everyone in a match, not just the shooter.

	None of this affects gameplay — it's reacting to what the server has
	already decided happened, using the origin/endpoint it computed.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)

local EffectsController = {}

local TRACER_LIFETIME = 0.05
local FLASH_LIFETIME = 0.06

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

function EffectsController.Init()
	Remotes.WeaponFired.OnClientEvent:Connect(
		function(_shooter: Player, origin: Vector3, endPoint: Vector3, hitZombie: boolean)
			spawnTracer(origin, endPoint)
			spawnBurst(origin, Color3.fromRGB(255, 220, 120), 0.5) -- muzzle flash
			if hitZombie then
				spawnBurst(endPoint, Color3.fromRGB(255, 60, 60), 0.4) -- hit spark
			end
		end
	)
end

return EffectsController
