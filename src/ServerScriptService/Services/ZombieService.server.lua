--[[
	ZombieService.server.lua

	Tier 0 scope: no wave system yet (that's Phase 2 / Tier 1). Just an
	endless trickle-spawn of one zombie type so you can test "does shooting
	a zombie feel good" in isolation.

	AI is intentionally cheap: direct chase toward the nearest player,
	no PathfindingService. Per the reconciled plan's open decisions list,
	PathfindingService should be reserved for Tank/Elite/Boss in Tier 1+;
	Normal/Fast zombies stay on direct-chase to keep server cost low.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ZombieConfig = require(ReplicatedStorage.Shared.ZombieConfig)

local ZOMBIE_TAG = "Zombie"
local MAX_CONCURRENT_ZOMBIES = 8
local SPAWN_INTERVAL_SECONDS = 3
local DEFAULT_SPAWN_POSITION = Vector3.new(0, 5, 20)

local activeZombieCount = 0

--[[
	Builds a minimal procedural zombie rig. Replace this with a real rigged
	model (Head/Torso/Humanoid from an artist) once you're past Tier 0 —
	this function is a placeholder so gameplay can be tested before art exists.
]]
local function createZombieModel(statsName: string): Model
	local stats = ZombieConfig[statsName]

	local model = Instance.new("Model")
	model.Name = statsName .. "Zombie"

	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Size = Vector3.new(2, 2, 1)
	rootPart.Transparency = 1
	rootPart.CanCollide = false
	rootPart.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Color = Color3.fromRGB(90, 120, 70)
	torso.Parent = model
	local torsoWeld = Instance.new("WeldConstraint")
	torsoWeld.Part0 = rootPart
	torsoWeld.Part1 = torso
	torsoWeld.Parent = torso
	torso.CFrame = rootPart.CFrame

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.2, 1.2)
	head.Color = Color3.fromRGB(120, 150, 100)
	head.Parent = model
	head.CFrame = rootPart.CFrame * CFrame.new(0, 1.6, 0)
	local headWeld = Instance.new("WeldConstraint")
	headWeld.Part0 = rootPart
	headWeld.Part1 = head
	headWeld.Parent = head

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = stats.MaxHP
	humanoid.Health = stats.MaxHP
	humanoid.WalkSpeed = stats.WalkSpeed
	humanoid.Parent = model

	model.PrimaryPart = rootPart

	CollectionService:AddTag(model, ZOMBIE_TAG)

	return model
end

local function getSpawnPosition(): Vector3
	local spawnsFolder = Workspace:FindFirstChild("ZombieSpawns")
	if spawnsFolder then
		local points = spawnsFolder:GetChildren()
		if #points > 0 then
			local chosen = points[math.random(1, #points)]
			if chosen:IsA("BasePart") then
				return chosen.Position
			end
		end
	end
	return DEFAULT_SPAWN_POSITION
end

local function findNearestPlayerRoot(fromPosition: Vector3): BasePart?
	local nearestRoot: BasePart? = nil
	local nearestDistance = math.huge

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if humanoid and humanoid.Health > 0 and root then
				local distance = (root.Position - fromPosition).Magnitude
				if distance < nearestDistance then
					nearestDistance = distance
					nearestRoot = root
				end
			end
		end
	end

	return nearestRoot
end

local function runZombieAI(model: Model, statsName: string)
	local stats = ZombieConfig[statsName]
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local rootPart = model.PrimaryPart :: BasePart

	local lastAttackTime = 0
	local aiConnection: RBXScriptConnection

	local function cleanup()
		if aiConnection then
			aiConnection:Disconnect()
		end
		activeZombieCount -= 1
	end

	humanoid.Died:Connect(function()
		cleanup()
		CollectionService:RemoveTag(model, ZOMBIE_TAG)
		task.delay(2, function()
			model:Destroy()
		end)
	end)

	aiConnection = RunService.Heartbeat:Connect(function()
		if not model.Parent or humanoid.Health <= 0 then
			return
		end

		local targetRoot = findNearestPlayerRoot(rootPart.Position)
		if not targetRoot then
			humanoid:MoveTo(rootPart.Position) -- idle in place
			return
		end

		local distance = (targetRoot.Position - rootPart.Position).Magnitude

		if distance > stats.AttackRange then
			humanoid:MoveTo(targetRoot.Position)
		else
			humanoid:MoveTo(rootPart.Position) -- stop to attack

			local now = os.clock()
			if now - lastAttackTime >= stats.AttackCooldown then
				lastAttackTime = now
				local targetHumanoid = targetRoot.Parent
					and targetRoot.Parent:FindFirstChildOfClass("Humanoid")
				if targetHumanoid and targetHumanoid.Health > 0 then
					targetHumanoid:TakeDamage(stats.AttackDamage)
				end
			end
		end
	end)
end

local function spawnZombie()
	if activeZombieCount >= MAX_CONCURRENT_ZOMBIES then
		return
	end

	local statsName = "Normal" -- Tier 0: only zombie type that exists
	local model = createZombieModel(statsName)
	model.Parent = Workspace

	local spawnPosition = getSpawnPosition()
	model:PivotTo(CFrame.new(spawnPosition))

	activeZombieCount += 1
	runZombieAI(model, statsName)
end

task.spawn(function()
	while true do
		task.wait(SPAWN_INTERVAL_SECONDS)
		spawnZombie()
	end
end)
