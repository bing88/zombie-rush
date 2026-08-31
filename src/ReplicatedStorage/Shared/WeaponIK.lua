--[[
	WeaponIK.lua (ModuleScript)

	Thin wrapper around Roblox's IKControl for weapon-holding poses, per
	"Roblox Weapons Kit — Stable Weapon Holding & Shooting Implementation
	Guide.md" sections 11-14 and 31.

	IMPORTANT — this is NOT the same thing WeaponViewController's own
	header comment says was already tried and failed ("three different
	techniques ... including IKControl ... with zero visible effect").
	That earlier attempt fed a computed pose back into Tool.Grip, which
	Roblox only ever reads ONCE at equip time to build a frozen Weld —
	no technique that writes to Grip afterward can work, IKControl
	included. This module never touches Tool.Grip or that Weld at all.
	Instead it drives IKControl.ChainRoot/EndEffector directly on the
	character's own arm parts (e.g. RightUpperArm -> RightHand), which
	makes Roblox's engine-level IK solver bend the actual arm bones.
	Since the weapon's equip weld is still rigidly attached to the hand,
	wherever the (now IK-posed) hand ends up is where the weapon ends up
	too — no separate weapon positioning code needed at all.

	Generalized (unlike the guide's own left-hand-specific example) so
	one module can drive both the support hand (target = a fixed
	Attachment on the weapon, e.g. LeftGrip) and the primary/aim hand
	(target = a script-driven Attachment moved every frame to track the
	camera) — see WeaponViewController for both use sites.

	Defaults to Enum.IKControlType.Position when controlType isn't
	passed. An earlier version of this project avoided Transform mode
	entirely: it demands the EndEffector's FULL rotation match the
	Target's, which (before WeaponModelFactory's
	HANDLE_ATTACHMENT_ROTATION_CORRECTION existed) required blindly
	guessing how RightHand's local axes related to a natural gripping
	pose — an undocumented, per-rig detail real developers report
	needing to hand-tune empirically with live visual feedback (e.g. a
	documented case needing `CFrame.Angles(math.pi/2, 0, math.pi)` for
	RightHand specifically — not a universal constant). Guessing that
	blind produced an upside-down weapon and visible shake fighting the
	walk animation here too.

	WeaponViewController's right-hand IK briefly tried
	Enum.IKControlType.Transform once Tool.Grip's own rotation was
	fixed to a verified net no-op (Handle's world rotation measured
	exactly equal to RightHand's, every frame — see
	WeaponModelFactory), on the theory that the "must guess RightHand's
	local axes" problem above no longer applied since we could now
	solve directly for RightHand's needed WORLD orientation instead of
	a guessed local constant. Live testing disproved the theory: the
	commanded and actual rotations diverged by tens of degrees every
	frame, plus the walking shake came right back. Root cause turned
	out structural rather than a Grip issue at all — the chain from
	RightUpperArm to RightHand spans THREE full 3-DoF Motor6Ds
	(shoulder, elbow, wrist), 9 rotational degrees of freedom for a
	single 6-DoF (or, in Position mode, 3-DoF) target — badly
	underdetermined regardless of whether the target rotation itself
	is "correct." Roblox's own developers confirm on the DevForum that
	reliably taming this needs actual HingeConstraint/
	BallSocketConstraint physics constraints added to the rig's joints
	in Studio (a GUI workflow, not scriptable from here) — a Pole alone
	is reportedly "often insufficient." So Transform was reverted;
	Position remains the only mode used by this project (both hands),
	accepted as the stable-but-imprecise option: it reliably reaches
	the intended position with zero shake, but leaves the exact
	elbow/wrist rotation — and therefore the barrel's exact tilt — as
	whatever Roblox's solver happens to pick.
]]

local WeaponIK = {}

export type IKHandle = IKControl

--[[
	chainRoot/endEffector: BaseParts on the character's OWN rig (e.g.
	RightUpperArm/RightHand for R15, or Torso/"Right Arm" for R6) — see
	WeaponViewController's rig-aware part resolution.

	target: the Instance IKControl should continuously solve the
	endEffector toward — an Attachment (most common), BasePart, or
	Model. Roblox re-reads this target's live position every solve, so
	a target that's itself moving (attached to a moving weapon, or one
	a script repositions every frame) is exactly the intended use case.

	controlType: defaults to Position (see header) — pass
	Enum.IKControlType.Transform explicitly only once a correct
	per-rig rotation compensation has actually been verified visually
	in Studio.
]]
function WeaponIK.Create(
	humanoid: Humanoid,
	chainRoot: BasePart,
	endEffector: BasePart,
	target: Instance,
	name: string?,
	controlType: Enum.IKControlType?
): IKHandle
	local ik = Instance.new("IKControl")
	ik.Name = name or "WeaponIK"
	ik.Type = controlType or Enum.IKControlType.Position
	ik.ChainRoot = chainRoot
	ik.EndEffector = endEffector
	ik.Target = target
	ik.SmoothTime = 0.05 -- Roblox's own documented default; slightly gentler than the guide's 0.03 given this game fights an active walk animation with no dedicated weapon-hold animation underneath it
	ik.Priority = 10
	ik.Weight = 1
	ik.Enabled = true
	ik.Parent = humanoid
	return ik
end

--[[
	Full re-enable, per guide section 14: "do not rely only on Weight",
	since smoothing can still let a disabled control influence the pose
	on the frames right after re-enabling if Weight alone was toggled.
]]
function WeaponIK.Enable(ik: IKHandle?)
	if not ik then
		return
	end
	ik.Enabled = true
	ik.Weight = 1
end

--[[ Fully off — used instead of Weight=0 alone, per guide section 14. ]]
function WeaponIK.Disable(ik: IKHandle?)
	if not ik then
		return
	end
	ik.Enabled = false
end

function WeaponIK.SetWeight(ik: IKHandle?, weight: number)
	if not ik then
		return
	end
	ik.Weight = weight
end

function WeaponIK.Destroy(ik: IKHandle?)
	if ik then
		ik:Destroy()
	end
end

return WeaponIK
