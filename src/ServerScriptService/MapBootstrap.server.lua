--[[
	MapBootstrap.server.lua

	Tier 0 has no real map yet (that's later in the roadmap). This just
	guarantees there's ground to stand on and a SpawnLocation, so the
	project works immediately after a fresh Rojo sync without needing to
	manually build anything in Studio first.

	Runs before ZombieService/PlayerService via script ordering — Roblox
	runs sibling Scripts in the order they're loaded, but since this only
	creates static, parented-immediately instances, load order doesn't
	actually matter here.
]]

local Workspace = game:GetService("Workspace")

local function ensureBaseplate()
	if Workspace:FindFirstChild("Baseplate") then
		return
	end

	local baseplate = Instance.new("Part")
	baseplate.Name = "Baseplate"
	baseplate.Anchored = true
	baseplate.Size = Vector3.new(200, 4, 200)
	baseplate.Position = Vector3.new(0, -2, 0)
	baseplate.Color = Color3.fromRGB(60, 60, 65)
	baseplate.Material = Enum.Material.Concrete
	baseplate.Parent = Workspace
end

local function ensureSpawn()
	if Workspace:FindFirstChildOfClass("SpawnLocation") then
		return
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlayerSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.Position = Vector3.new(0, 0.5, 0)
	spawn.Transparency = 1
	spawn.CanCollide = true
	spawn.Duration = 0 -- no forcefield after spawning
	spawn.Parent = Workspace
end

ensureBaseplate()
ensureSpawn()
