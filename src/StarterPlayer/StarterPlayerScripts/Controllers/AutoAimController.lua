--[[
	AutoAimController.lua (ModuleScript)

	Pure detection utility: given the camera's current position and look
	direction, finds the best zombie target within a small cone around the
	crosshair and within range. Returns just the target BasePart (or nil)
	— callers (CameraController) derive whatever direction/position math
	they need from it.

	Per-part targeting: this considers every meaningful body part on each
	zombie and returns whichever one the crosshair is actually closest
	to, rather than a fixed "Head or else HumanoidRootPart". That fixed
	choice was why nudging toward a zombie's head felt like it fought
	back — the assist had no concept of the head as a separate thing to
	aim at once it settled on a part, so it kept correcting back to that
	one point. Now, aiming toward the head makes the head the winning
	candidate and the assist helps you get there instead of undoing it.

	Not a trust boundary. The server independently raycasts using whatever
	direction it's given and re-validates everything (fire rate, ammo,
	spread, and line-of-sight via its own raycast) — see WeaponService.
	This also doesn't check line-of-sight itself, so it can occasionally
	select a target that's actually behind cover; the server will simply
	register that as a miss since its own raycast hits the obstruction
	first.
]]

local CollectionService = game:GetService("CollectionService")

local AutoAimController = {}

local MAX_ASSIST_DISTANCE = 50
local ASSIST_CONE_DEGREES = 8
local ASSIST_CONE_COS = math.cos(math.rad(ASSIST_CONE_DEGREES))

-- Parts worth aiming at, best-first only in the sense that they're all
-- considered equally — the crosshair's actual proximity decides. Covers
-- both R15 (UpperTorso/LowerTorso) and R6 (Torso) rigs, since zombie
-- models come from different sources.
local CANDIDATE_PART_NAMES = {
	"Head",
	"UpperTorso",
	"LowerTorso",
	"Torso",
	"HumanoidRootPart",
	"LeftUpperArm",
	"RightUpperArm",
	"LeftUpperLeg",
	"RightUpperLeg",
}

function AutoAimController.FindTargetPart(cameraPosition: Vector3, cameraLookVector: Vector3): BasePart?
	local bestPart: BasePart? = nil
	local bestDot = ASSIST_CONE_COS -- candidate must beat this (higher cosine = closer to crosshair center)

	local normalizedLook = cameraLookVector.Unit

	for _, zombieModel in CollectionService:GetTagged("Zombie") do
		if zombieModel:IsDescendantOf(workspace) then
			local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				for _, partName in CANDIDATE_PART_NAMES do
					local targetPart = zombieModel:FindFirstChild(partName)
					if targetPart and targetPart:IsA("BasePart") then
						local toTarget = targetPart.Position - cameraPosition
						local distance = toTarget.Magnitude
						if distance > 0.1 and distance <= MAX_ASSIST_DISTANCE then
							local dot = normalizedLook:Dot(toTarget.Unit)
							if dot > bestDot then
								bestDot = dot
								bestPart = targetPart
							end
						end
					end
				end
			end
		end
	end

	return bestPart
end

return AutoAimController
