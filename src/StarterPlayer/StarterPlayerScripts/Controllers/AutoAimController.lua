--[[
	AutoAimController.lua (ModuleScript)

	Lightweight client-side aim assist: when a zombie is within a small
	cone around the crosshair and within range, this hands back a
	snapped-to-target aim direction and signals that the shot should
	auto-fire without the player needing to hold the fire button.

	This is a convenience layer only, not a trust boundary. The server
	independently raycasts using whatever direction it's given and
	re-validates everything (fire rate, ammo, spread, line of sight via
	the raycast itself) — see WeaponService. A player could reimplement
	this exact math client-side regardless of whether we ship it, so
	baking it in doesn't create a new cheat vector; it just makes normal
	play less finicky. It also doesn't check line-of-sight itself (no
	client raycast here), so it can occasionally auto-fire at a target
	that's actually behind cover — the server will simply register that
	as a miss since its own raycast will hit the obstruction first.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local AutoAimController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local MAX_ASSIST_DISTANCE = 50
local ASSIST_CONE_DEGREES = 8
local ASSIST_CONE_COS = math.cos(math.rad(ASSIST_CONE_DEGREES))

--[[
	Returns (aimDirection, shouldAutoFire). aimDirection is nil when no
	valid target is currently within the assist cone/range — callers
	should fall back to raw camera aim and manual firing in that case.
]]
function AutoAimController.FindTarget(muzzlePosition: Vector3): (Vector3?, boolean)
	if not player.Character then
		return nil, false
	end

	local cameraPosition = camera.CFrame.Position
	local cameraLook = camera.CFrame.LookVector

	local bestDirection: Vector3? = nil
	local bestDot = ASSIST_CONE_COS -- candidate must beat this (higher cosine = closer to crosshair center)

	for _, zombieModel in CollectionService:GetTagged("Zombie") do
		if zombieModel:IsDescendantOf(workspace) then
			local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				local targetPart = zombieModel:FindFirstChild("Head") or zombieModel:FindFirstChild("HumanoidRootPart")
				if targetPart then
					local toTarget = targetPart.Position - cameraPosition
					local distance = toTarget.Magnitude
					if distance > 0.1 and distance <= MAX_ASSIST_DISTANCE then
						local dot = cameraLook.Unit:Dot(toTarget.Unit)
						if dot > bestDot then
							bestDot = dot
							bestDirection = targetPart.Position - muzzlePosition
						end
					end
				end
			end
		end
	end

	if bestDirection and bestDirection.Magnitude > 0.01 then
		return bestDirection.Unit, true
	end

	return nil, false
end

return AutoAimController
