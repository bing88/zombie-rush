--[[
	CFrameDebug.lua (ModuleScript)

	Tiny shared formatting helper so both the server (WeaponModelFactory,
	when building a real weapon Tool) and the client (WeaponViewController,
	when posing the hands) can print directly-comparable, human-readable
	CFrame dumps into the Studio Output — used to root-cause "weapon
	pointing the wrong way" reports without needing to see Studio live.

	Yaw is measured the same way WeaponViewController's own
	getStabilizedCameraRotation does (atan2(-X, -Z) of LookVector, i.e. 0°
	= facing world -Z), so a printed yaw of e.g. "Handle yaw=90 camera
	yaw=0" directly tells you the Handle is rotated 90° off from the
	camera around the vertical axis — no mental CFrame math required to
	read the logs.
]]

local CFrameDebug = {}

function CFrameDebug.Vector(v: Vector3): string
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

function CFrameDebug.YawDegrees(cf: CFrame): number
	local look = cf.LookVector
	return math.deg(math.atan2(-look.X, -look.Z))
end

--[[
	label is printed first so multi-line Output dumps stay easy to scan
	(e.g. "RightHand", "Handle", "Tool.Grip (local)").
]]
function CFrameDebug.Describe(label: string, cf: CFrame): string
	return string.format(
		"%-22s pos=%s look=%s up=%s right=%s yaw=%.1f",
		label,
		CFrameDebug.Vector(cf.Position),
		CFrameDebug.Vector(cf.LookVector),
		CFrameDebug.Vector(cf.UpVector),
		CFrameDebug.Vector(cf.RightVector),
		CFrameDebug.YawDegrees(cf)
	)
end

return CFrameDebug
