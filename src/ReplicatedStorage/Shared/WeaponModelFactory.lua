--[[
	WeaponModelFactory.lua

	Builds the Tool each player holds. Tier 1 originally built placeholder
	block Tools; now it first tries to load the real weapon model from
	Roblox's official "Weapons Kit" (see WEAPON_ASSET_IDS) and falls back
	to the placeholder if that asset can't be loaded (e.g. Studio without
	"Enable Studio Access to API Services") or doesn't have a usable
	Tool/Handle inside.

	Whichever path is used, the result always has a Handle with a
	"Muzzle" Attachment — that's the one contract WeaponService (server
	raycast origin) and EffectsController (muzzle flash/tracer origin)
	rely on, so nothing downstream needs to know which path produced the
	Tool. A "DefaultGrip" attribute is also always set so
	WeaponViewController's reload tween can return to the *correct* grip
	for whichever Tool this is, instead of a single shared constant.

	The Handle also always gets a "LeftGrip" Attachment — the off-hand's
	IKControl target (see WeaponViewController), so the support hand
	visually rests on the weapon body instead of swinging freely with the
	default walk/idle animation. This is separate from Tool.Grip/
	HandleAttachment (the primary/right-hand relationship, which Roblox's
	own equip weld already handles) and from TipAttachment/Muzzle (where
	shots originate) — three different attachments for three different
	jobs on the same Handle.

	The Weapons Kit ships an entire standalone weapon framework
	(WeaponsSystem folder: its own fire/reload/ammo/recoil/camera/GUI
	scripts) — none of that is imported. Only the visual geometry plus
	its documented TipAttachment/HandleAttachment (for muzzle/grip
	placement) are kept; every Script/LocalScript is stripped since
	WeaponService must remain the sole authority on firing/damage/ammo.
]]

local AssetService = game:GetService("AssetService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CFrameDebug = require(ReplicatedStorage.Shared.CFrameDebug)

local WeaponModelFactory = {}

-- Flip to false once the weapon-holding pose is confirmed correct and
-- these prints are no longer needed. Server-side only, prints once per
-- weapon (template build is cached — see getWeaponTemplate) rather than
-- once per Clone(), so this is cheap to leave on.
WeaponModelFactory.DEBUG_LOGGING = false

-- Exposed so other scripts (e.g. the reload animation) can fall back to
-- this if a Tool has no "DefaultGrip" attribute for some reason.
WeaponModelFactory.DEFAULT_GRIP = CFrame.new(0, -0.15, 0)

local WEAPON_VISUALS: { [string]: { Size: Vector3, Color: Color3, MuzzleZ: number } } = {
	Pistol = { Size = Vector3.new(0.4, 0.4, 1.1), Color = Color3.fromRGB(40, 40, 45), MuzzleZ = -0.55 },
	AssaultRifle = { Size = Vector3.new(0.5, 0.5, 2), Color = Color3.fromRGB(50, 50, 55), MuzzleZ = -1 },
	Shotgun = { Size = Vector3.new(0.6, 0.6, 1.7), Color = Color3.fromRGB(80, 55, 35), MuzzleZ = -0.85 },
}

-- Official Roblox "Weapons Kit" model assets used as the real Tool for
-- each weapon instead of the placeholder block. See
-- https://create.roblox.com/docs/resources/weapons-kit for their
-- documented structure (TipAttachment/HandleAttachment, a visual Model
-- with a PrimaryPart, Configuration values, etc.) — we only borrow the
-- visual geometry + those two attachments for positioning; the kit's own
-- WeaponsSystem scripts/framework are never imported, since WeaponService
-- must remain the sole authority on firing/damage/ammo.
local WEAPON_ASSET_IDS: { [string]: number } = {
	Pistol = 118912302094201,
	AssaultRifle = 96131146947811,
	Shotgun = 104068096273092,
}

--[[
	Builds a minimal procedural placeholder Tool, scaled/colored per
	weapon. Used directly until real art exists, and as a fallback if a
	real asset can't be loaded.
]]
function WeaponModelFactory.CreatePlaceholderTool(weaponName: string): Tool
	local visuals = WEAPON_VISUALS[weaponName]
	assert(visuals, "WeaponModelFactory: no visuals defined for weapon " .. tostring(weaponName))

	local tool = Instance.new("Tool")
	tool.Name = weaponName
	tool.RequiresHandle = true
	tool.CanBeDropped = false -- losing a weapon on the ground would create ownership-sync headaches; out of scope for Tier 1

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = visuals.Size
	handle.Color = visuals.Color
	handle.Material = Enum.Material.Metal
	handle.CanCollide = false
	handle.Parent = tool

	-- By Roblox Tool convention, the Handle's -Z direction is "forward"
	-- (the barrel direction) once equipped in a character's hand.
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.CFrame = CFrame.new(0, 0, visuals.MuzzleZ)
	muzzle.Parent = handle

	-- Support-hand IK target (see WeaponViewController's left-hand
	-- IKControl) — roughly where a foregrip/handguard would sit:
	-- partway toward the muzzle, slightly below center.
	local leftGrip = Instance.new("Attachment")
	leftGrip.Name = "LeftGrip"
	leftGrip.CFrame = CFrame.new(0, -visuals.Size.Y * 0.4, visuals.MuzzleZ * 0.5)
	leftGrip.Parent = handle

	tool.Grip = WeaponModelFactory.DEFAULT_GRIP
	tool:SetAttribute("DefaultGrip", tool.Grip)

	return tool
end

--[[
	Strips everything the asset's own weapon-system scripts would need
	(so they can never fire/reload/deal damage on their own, fighting
	WeaponService's authority) and mutes any always-on particle effects
	that had no script left to trigger them contextually.
]]
local function stripToolScripts(tool: Tool)
	for _, descendant in tool:GetDescendants() do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Fire") or descendant:IsA("Smoke") then
			descendant.Enabled = false
		end
	end
end

--[[
	Roblox's built-in "equip a Tool into the hand" weld only triggers for
	a BasePart literally named "Handle" that is a *direct* child of the
	Tool — and per the Weapons Kit's own docs
	(https://create.roblox.com/docs/resources/weapons-kit#weapon-model),
	its weapon model has *no such part at all*: it's a separate visual
	Model (nested inside the Tool) made of one or more BaseParts that
	are NOT physically joined to each other. Normally the kit's own
	WeaponsSystem scripts reposition those parts by hand every frame;
	since we strip that whole framework, none of that geometry would
	ever move with the equipped Tool — it'd just sit wherever it was
	when cloned (i.e. on the floor near the origin), with only a single
	promoted part (if any) actually gripped.

	This *always* (even if a part named "Handle" already exists — many
	toolbox "Get Model" packages ship one, but pre-Anchored for static
	display, which would otherwise make the whole gun immovable forever
	since Motor6D/weld-driven motion can't budge an Anchored part) welds
	every other BasePart under the Tool onto whichever part becomes
	"Handle" and force-unanchors the whole assembly, so the entire gun
	moves as one rigid unit once Roblox's automatic equip weld grips it.
]]
local function ensureHandle(tool: Tool): BasePart?
	local mainPart = tool:FindFirstChild("Handle")
	if not mainPart or not mainPart:IsA("BasePart") then
		local visualModel = tool:FindFirstChildOfClass("Model")
		mainPart = tool.PrimaryPart or (visualModel and visualModel.PrimaryPart)
	end
	if not mainPart then
		mainPart = tool:FindFirstChildWhichIsA("BasePart", true)
	end
	if not mainPart or not mainPart:IsA("BasePart") then
		return nil
	end

	-- Weld every other BasePart anywhere under the Tool (not just inside
	-- a nested Model — real assets vary) onto mainPart, regardless of
	-- how deeply nested it is, so nothing gets left behind.
	for _, part in tool:GetDescendants() do
		if part:IsA("BasePart") and part ~= mainPart then
			part.Anchored = false
			part.CanCollide = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = mainPart
			weld.Part1 = part
			weld.Parent = part
		end
	end

	mainPart.Anchored = false
	mainPart.CanCollide = false
	mainPart.Name = "Handle"
	mainPart.Parent = tool
	tool.PrimaryPart = mainPart :: BasePart
	return mainPart :: BasePart
end

--[[
	Converts a world-space Attachment into a CFrame relative to the
	Handle, so it survives being re-parented onto the Handle at a
	different point in the hierarchy. Must run before the Tool is ever
	equipped/moved — i.e. while the template is still sitting still.
]]
local function localOffsetOnHandle(handle: BasePart, attachment: Attachment?): CFrame?
	if not attachment then
		return nil
	end
	return handle.CFrame:ToObjectSpace(attachment.WorldCFrame)
end

--[[
	Prefers the Weapons Kit's own documented "TipAttachment" (the exact
	point projectiles should come from, per the kit's docs) for muzzle
	placement; falls back to a simple heuristic off the Handle's size for
	weapon assets that don't define one.
]]
local function ensureMuzzleAttachment(tool: Tool, handle: BasePart)
	local existing = handle:FindFirstChild("Muzzle")
	if existing then
		existing:Destroy()
	end

	local tipAttachment = tool:FindFirstChild("TipAttachment", true) :: Attachment?
	local localCFrame = localOffsetOnHandle(handle, tipAttachment)

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	-- By Roblox Tool convention, the Handle's -Z direction is "forward"
	-- (the barrel direction) once equipped in a character's hand.
	muzzle.CFrame = localCFrame or CFrame.new(0, 0, -handle.Size.Z / 2)
	muzzle.Parent = handle
end

--[[
	Support-hand IK target (see WeaponViewController's left-hand
	IKControl, which bends the character's off-hand toward this
	attachment so it visually rests on the weapon instead of swinging
	freely with the default walk/idle animation). The Weapons Kit's own
	docs don't define a dedicated attachment for this, so this prefers
	one of a couple of plausible community-model names if present and
	otherwise falls back to a heuristic offset: partway from center
	toward the muzzle (-Z, per Tool convention) and slightly below,
	roughly where a foregrip/handguard would be. Not every weapon needs
	to be held two-handed — callers that don't want the extra IK can
	simply ignore this attachment; it costs nothing if unused.
]]
local function ensureLeftGripAttachment(tool: Tool, handle: BasePart)
	local existing = handle:FindFirstChild("LeftGrip")
	if existing then
		existing:Destroy()
	end

	local namedAttachment = (tool:FindFirstChild("LeftGripAttachment", true) or tool:FindFirstChild("SecondaryGripAttachment", true)) :: Attachment?
	local localCFrame = localOffsetOnHandle(handle, namedAttachment)

	local leftGrip = Instance.new("Attachment")
	leftGrip.Name = "LeftGrip"
	leftGrip.CFrame = localCFrame or CFrame.new(0, -handle.Size.Y * 0.4, -handle.Size.Z * 0.3)
	leftGrip.Parent = handle
end

--[[
	Empirically-measured correction — NOT a guess, and now measured
	TWICE against real Studio runs (see WeaponViewController/
	CFrameDebug's Output logs).

	Round 1 (no correction): comparing the equipped Handle's world
	orientation to RightHand's showed an exact, consistent mismatch
	across all three Weapons Kit assets alike: Handle.LookVector always
	equalled RightHand.UpVector, Handle.UpVector equalled RightHand.
	LookVector, Handle.RightVector equalled -RightHand.RightVector.
	Computing that directly (RightHand.CFrame:Inverse() * Handle.CFrame
	from the logged numbers, matrix arithmetic checked by hand) gives a
	fixed rotation matrix M with Right=(-1,0,0), Up=(0,0,-1),
	Look=(0,1,0). Since Handle.CFrame = RightHand.CFrame * Tool.Grip
	holds for ANY hand pose, M IS Grip's rotation at that point.

	A first attempt assumed this meant the Weapons Kit's own
	HandleAttachment doesn't encode "matches the hand's axes 1:1" the
	way computeGripFromHandleAttachment's math assumes, and corrected
	by right-multiplying another copy of M (M is self-inverse: M*M =
	identity, verified by hand) — which DOES make the Grip property's
	own rotation read back as identity (confirmed: the logged
	"Tool.Grip yaw=0.0" after that change).

	Round 2 (that correction applied): despite Grip's rotation now
	being genuinely identity, the ACTUALLY-EQUIPPED Handle was STILL
	misaligned from RightHand — not by M anymore, but by a *different*,
	equally exact mismatch: Handle.RightVector == RightHand.RightVector
	(unchanged this time) while Handle.LookVector == -RightHand.
	LookVector and Handle.UpVector == -RightHand.UpVector (both
	negated). That's a clean 180° flip about the Right/X axis — call it
	M2 (Right=(1,0,0), Up=(0,-1,0), Look=(0,0,1)) — appearing *even
	though Grip.rotation measured as identity going in*. The only
	explanation: Roblox's real tool-equip pipeline applies some fixed
	offset of its own on top of Grip that isn't visible by reading the
	Grip property directly (most likely a built-in "how a fist
	naturally grips a hilt" convention on the character rig's own grip
	attachment) — round 1's fix addressed the asset-side math but not
	this deeper, always-present engine-side offset.

	Since M2 is also self-inverse (a 180° flip squared is identity),
	and the raw (uncorrected) Grip.rotation is ALWAYS M (deterministic,
	asset-geometry-derived), solving RawGrip.rotation * Correction =
	M2 for Correction gives Correction = M:Inverse() * M2 = M * M2
	(M self-inverse) — computed by hand and cross-checked with a second
	method (decomposing via cross products instead of raw matrix
	multiplication) to get identical Right=(-1,0,0), Up=(0,0,1)
	results both ways. This is that Correction: composing it onto the
	raw computed Grip should make the FINAL Grip property read back
	with a ~180° yaw (matching M2, not identity) — if a future debug
	pass shows anything else, the bug is in this file's Lua, not the
	underlying math above.
]]
local HANDLE_ATTACHMENT_ROTATION_CORRECTION = CFrame.fromMatrix(Vector3.zero, Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1))

--[[
	Second, independent correction — layered ON TOP of the one above, not
	a replacement for it — needed once weapon holding switched from the
	live right-hand Position-IK reach to the authored
	Dummy_Pistol_Rifle_Animations.rbxm Idle poses (see WeaponConfig's
	HoldAnimationId and WeaponViewController's playHoldAnimation).

	With only HANDLE_ATTACHMENT_ROTATION_CORRECTION applied, Handle's
	rotation ends up IDENTICAL to RightHand's raw bone rotation (net zero
	extra rotation) — which was exactly right for the old live-IK reach,
	whose target attachment was placed assuming "Handle inherits
	RightHand's rotation directly". But the Idle animation itself poses
	RightHand's own -Z ("look") axis pointing almost straight up (world
	Y≈0.99) with its Y ("up") axis roughly horizontal-forward instead —
	for BOTH the pistol and rifle dummies alike, confirmed by comparing
	several live Play-session ticks (WeaponViewController's debugTick
	logs) of RightHand's actual right/up/look against the camera's at
	that same moment:

		RightHand.Right ~= Camera.Right
		RightHand.Up    ~= Camera.Look
		RightHand.Look  ~= -Camera.Up

	That is a clean, consistent 90° rotation about the hand's own Right
	axis (not a guess) — Right stays put, Look and Up have effectively
	swapped (with a sign flip). Composing this as a pure rotation,
	right-multiplied so it doesn't disturb the position component
	computeGripFromHandleAttachment already worked out, undoes exactly
	that swap: it rotates Grip's Look axis back down from Up and Up back
	up from Look, so the barrel ends up pointing roughly
	horizontal-forward (matching the camera/Torso) instead of at the
	ceiling.

	If a future weapon's authored Idle pose doesn't have this same wrist
	quirk, this will need to become conditional (e.g. only applied when
	WeaponConfig.HoldAnimationId is actually set for that weapon) instead
	of unconditional — right now every weapon (Pistol/AssaultRifle/
	Shotgun) uses an authored Idle animation, so there's no live-IK-only
	case left to protect against.

	The -90° pitch above got the barrel pointing the right direction, but
	left the gun upside-down (confirmed visually) — a roll around the
	barrel's OWN forward axis, orthogonal to the pitch fix above and not
	explained by it. Appended here as a further right-multiply (so it
	rolls around the already-pitch-corrected barrel axis, not the
	original RightHand axis) — a fixed 180° is the only sensible value
	for "upside-down" (self-inverse, so its sign doesn't matter).
]]
local HOLD_ANIMATION_WRIST_ROTATION_CORRECTION = CFrame.Angles(math.rad(-90), 0, 0) * CFrame.Angles(0, 0, math.rad(180))

--[[
	Prefers the Weapons Kit's own documented "HandleAttachment" (the
	point on the weapon where the kit's own scripts weld it into the
	hand, per the kit's docs) to derive a correctly-fitted Tool.Grip —
	Grip describes hand -> Handle, which is the inverse of "where on the
	Handle the hand attachment sits". Returns nil (caller keeps whatever
	Grip the asset shipped with, usually just the Roblox default) if no
	such attachment exists.
]]
local function computeGripFromHandleAttachment(tool: Tool, handle: BasePart): CFrame?
	local handleAttachment = tool:FindFirstChild("HandleAttachment", true) :: Attachment?
	local localCFrame = localOffsetOnHandle(handle, handleAttachment)
	if not localCFrame then
		return nil
	end
	return localCFrame:Inverse() * HANDLE_ATTACHMENT_ROTATION_CORRECTION * HOLD_ANIMATION_WRIST_ROTATION_CORRECTION
end

--[[
	Loads + processes one weapon's real Tool. Everything here (including
	the load itself) runs inside a single pcall in getWeaponTemplate, so
	any failure at any step — missing Tool/Handle, or something more
	obscure about how a Store asset comes back (e.g. Sandboxed/Capability
	writes being restricted, or descendants coming back non-Archivable) —
	falls back to the placeholder cleanly instead of throwing an
	uncaught error that would silently break PlayerService's whole
	weapon-giving loop for every weapon after this one.
]]
local function buildWeaponTemplate(assetId: number, weaponName: string): Tool
	local container = AssetService:LoadAssetAsync(assetId)

	-- LoadAssetAsync sandboxes the returned Model by default (no script
	-- Capabilities), which is irrelevant here since every script gets
	-- stripped below anyway — but un-sandbox regardless in case any
	-- future kept script (mirroring the zombie side) needs to run.
	container.Sandboxed = false

	local tool = container:FindFirstChildWhichIsA("Tool", true)
	if not tool then
		container:Destroy()
		error(("asset %d didn't contain a Tool"):format(assetId))
	end
	tool.Parent = nil -- detach from the throwaway wrapper before destroying it
	container:Destroy()
	tool.Sandboxed = false

	local handle = ensureHandle(tool)
	if not handle then
		tool:Destroy()
		error(("asset %d's Tool has no usable Handle/PrimaryPart"):format(assetId))
	end

	-- Read the kit's own attachments (if any) *before* stripping scripts —
	-- stripping only removes Script/LocalScript/particle instances, so this
	-- ordering doesn't actually matter functionally, but keeps the "read
	-- the asset's intent, then clean it up" steps in a sensible order.
	local handleAttachment = tool:FindFirstChild("HandleAttachment", true) :: Attachment?
	local computedGrip = computeGripFromHandleAttachment(tool, handle)
	ensureMuzzleAttachment(tool, handle)
	ensureLeftGripAttachment(tool, handle)
	stripToolScripts(tool)

	tool.Name = weaponName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	if computedGrip then
		tool.Grip = computedGrip
	end
	tool:SetAttribute("DefaultGrip", tool.Grip)

	if WeaponModelFactory.DEBUG_LOGGING then
		print(("[WeaponDebug][Server] ===== %s (asset %d) ====="):format(weaponName, assetId))
		print(("[WeaponDebug][Server] Handle.Size=%s"):format(tostring(handle.Size)))
		if handleAttachment then
			print("[WeaponDebug][Server] " .. CFrameDebug.Describe("HandleAttachment(local-on-Handle)", handle.CFrame:ToObjectSpace(handleAttachment.WorldCFrame)))
		else
			print("[WeaponDebug][Server] no HandleAttachment on this asset -> Grip left at asset default (not computed)")
		end
		print("[WeaponDebug][Server] " .. CFrameDebug.Describe("Tool.Grip(local)", tool.Grip))
		local muzzle = handle:FindFirstChild("Muzzle")
		if muzzle and muzzle:IsA("Attachment") then
			print("[WeaponDebug][Server] " .. CFrameDebug.Describe("Muzzle(local-on-Handle)", muzzle.CFrame))
		end
		local leftGrip = handle:FindFirstChild("LeftGrip")
		if leftGrip and leftGrip:IsA("Attachment") then
			print("[WeaponDebug][Server] " .. CFrameDebug.Describe("LeftGrip(local-on-Handle)", leftGrip.CFrame))
		end
	end

	-- Store assets sometimes come back with Archivable = false on some
	-- descendants (an anti-duplication default) — if left alone, every
	-- :Clone() of this template (every future grant of this weapon)
	-- would silently return nil, which then errors wherever the caller
	-- assumes a real Tool (e.g. `tool.Parent = backpack`).
	tool.Archivable = true
	for _, descendant in tool:GetDescendants() do
		descendant.Archivable = true
	end

	return tool
end

local weaponTemplates: { [string]: Tool } = {}
local weaponTemplateLoadAttempted: { [string]: boolean } = {}

--[[
	Lazily loads + caches the real Tool for a weapon on first use. Cached
	as a hidden ServerStorage template so every subsequent grant of that
	weapon (spawn, shop purchase) is just a cheap :Clone().

	Returns nil (and warns once per weapon) if anything about loading or
	preparing the asset fails — most commonly because "Allow Loading
	Third Party Assets" is off in Game Settings > Security (required
	since none of these assets are owned by the game's creator — see
	AssetService:LoadAssetAsync's docs) — so callers fall back to the
	placeholder instead of erroring.
]]
local function getWeaponTemplate(weaponName: string): Tool?
	if weaponTemplates[weaponName] then
		return weaponTemplates[weaponName]
	end
	if weaponTemplateLoadAttempted[weaponName] then
		return nil
	end
	weaponTemplateLoadAttempted[weaponName] = true

	local assetId = WEAPON_ASSET_IDS[weaponName]
	if not assetId then
		return nil
	end

	local ok, toolOrError = pcall(buildWeaponTemplate, assetId, weaponName)
	if not ok or not toolOrError then
		warn(("WeaponModelFactory: failed to prepare %s asset %d (%s) — falling back to the placeholder tool. If this isn't a permissions error, check that 'Allow Loading Third Party Assets' is on in Game Settings > Security."):format(weaponName, assetId, tostring(toolOrError)))
		return nil
	end

	local tool = toolOrError :: Tool
	tool.Parent = ServerStorage
	weaponTemplates[weaponName] = tool
	return tool
end

--[[
	Dispatches to the real toolbox weapon asset (with the placeholder
	Tool as a fallback if it fails to load, lacks a usable structure, or
	fails to Clone()).
]]
function WeaponModelFactory.CreateTool(weaponName: string): Tool
	local template = getWeaponTemplate(weaponName)
	if template then
		local clone = template:Clone()
		if clone then
			return clone
		end
		warn(("WeaponModelFactory: %s template failed to Clone() — falling back to the placeholder tool for this grant."):format(weaponName))
	end

	return WeaponModelFactory.CreatePlaceholderTool(weaponName)
end

--[[
	Purely cosmetic flourish for a weapon at max upgrade level — a
	golden glow + faint sparkle on the Handle, applied non-destructively
	(doesn't touch the Handle's own Color/Material) so it works
	regardless of whether the Tool is a real loaded asset or the
	placeholder block. Safe to call more than once (clears any existing
	prestige effect first) so it can be re-applied idempotently.
]]
function WeaponModelFactory.ApplyPrestigeEffect(tool: Tool)
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end

	local existing = handle:FindFirstChild("PrestigeEffect")
	if existing then
		existing:Destroy()
	end

	local effectHolder = Instance.new("Attachment")
	effectHolder.Name = "PrestigeEffect"
	effectHolder.Parent = handle

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 215, 100)
	light.Brightness = 1.5
	light.Range = 6
	light.Parent = effectHolder

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 225, 140))
	sparkle.Size = NumberSequence.new(0.15)
	sparkle.Lifetime = NumberRange.new(0.4, 0.8)
	sparkle.Rate = 4
	sparkle.Speed = NumberRange.new(0.5, 1)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Parent = effectHolder
end

return WeaponModelFactory
