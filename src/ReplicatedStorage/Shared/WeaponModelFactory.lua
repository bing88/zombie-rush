--[[
	WeaponModelFactory.lua

	Builds a placeholder Tool so players have something visible in their
	hands before real weapon art/animations exist. The "Muzzle" Attachment
	gives the server an actual barrel-tip position to raycast from (much
	better than firing from the torso center) and gives the client a fixed
	point to draw muzzle flash / tracer effects from.

	Replace the part-building in CreateAssaultRifleTool with a real rigged
	model once art exists — nothing in WeaponService or EffectsController
	needs to change as long as the Tool has a Handle with a "Muzzle"
	Attachment on it.
]]

local WeaponModelFactory = {}

-- Exposed so other scripts (e.g. the reload animation) can reset back to
-- this exact pose without duplicating the magic numbers.
WeaponModelFactory.DEFAULT_GRIP = CFrame.new(0, -0.15, 0)

function WeaponModelFactory.CreateAssaultRifleTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "AssaultRifle"
	tool.RequiresHandle = true
	tool.CanBeDropped = false -- Tier 0 has one weapon; losing it would soft-lock the player

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 0.5, 2)
	handle.Color = Color3.fromRGB(50, 50, 55)
	handle.Material = Enum.Material.Metal
	handle.CanCollide = false
	handle.Parent = tool

	-- By Roblox Tool convention, the Handle's -Z direction is "forward"
	-- (the barrel direction) once equipped in a character's hand.
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.CFrame = CFrame.new(0, 0, -1)
	muzzle.Parent = handle

	-- Cosmetic-only grip offset so the block doesn't float oddly in-hand.
	-- Safe to retune freely; it doesn't affect gameplay.
	tool.Grip = WeaponModelFactory.DEFAULT_GRIP

	return tool
end

return WeaponModelFactory
