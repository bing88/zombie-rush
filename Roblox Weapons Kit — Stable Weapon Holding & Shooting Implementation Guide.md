# Roblox Weapons Kit — Stable Weapon Holding & Shooting Implementation Guide

## 1. Goal

Build a third-person shooting system based on the official Roblox Weapons Kit with the following behavior:

```text
                    R15 Character
                         │
             ┌───────────┴───────────┐
             │                       │
        Movement System         Weapon System
             │                       │
       ┌─────┼─────┐           ┌─────┼─────┐
       │     │     │           │     │     │
      Idle  Walk  Sprint      Aim   Fire  Reload
             │
             ▼
      Weapon Hold Animation
             │
             ▼
        IK Hand Control
             │
             ▼
      Stable Weapon Pose
```

The desired result:

```text
Idle + Rifle
      ↓
Walk + Rifle
      ↓
Sprint + Rifle
      ↓
Walk + Shoot
      ↓
Sprint + Shoot
```

The hands should remain visually attached to the weapon instead of shaking or being pulled away by the normal walking animation.

---

# 2. Recommended Architecture

Do NOT modify the Weapons Kit's core weapon logic unnecessarily.

Keep:

```text
Weapons Kit
├── Weapon firing
├── Ammo
├── Reload
├── Projectile
├── Damage
├── Recoil
└── Camera
```

Add a separate:

```text
Weapon Character Controller
├── Weapon pose
├── Walk pose
├── Sprint pose
├── IK
├── Aim
└── Animation blending
```

Final architecture:

```text
ServerScriptService
│
├── WeaponsSystem
│   ├── Libraries
│   ├── WeaponTypes
│   ├── Assets
│   └── ...
│
└── WeaponCharacterSystem
    ├── WeaponAnimationController
    └── WeaponIKController
```

Roblox's Weapons Kit uses a unified `WeaponsSystem` folder, and placing it in `ServerScriptService` makes it the shared system folder for prefab weapons.

---

# 3. Weapon Structure

Start with the official Auto Rifle or another rifle from the Weapons Kit.

The basic weapon structure is approximately:

```text
Auto Rifle
│
├── Configuration
│   ├── AmmoCapacity
│   ├── FireMode
│   ├── ShotCooldown
│   ├── RecoilMin
│   ├── RecoilMax
│   ├── TotalRecoilMax
│   └── ...
│
├── Model
│   ├── PrimaryPart
│   ├── TipAttachment
│   └── HandleAttachment
│
├── Handle
│
└── WeaponsSystem
```

The official Weapons Kit uses `HandleAttachment` to determine where the Tool handle is welded to the character. `TipAttachment` determines where projectiles originate.

---

# 4. Add Weapon Grip Attachments

Add two new Attachments to the weapon.

```text
Rifle
└── Model
    ├── Body
    │
    ├── TipAttachment
    ├── HandleAttachment
    │
    ├── RightGrip
    └── LeftGrip
```

Recommended locations:

```text
                Barrel
====================================>

          ┌──────────────────┐
          │      Rifle       │
          └──────────────────┘
             ▲            ▲
             │            │
          LeftGrip    RightGrip
```

## RightGrip

This is the primary hand position.

Usually:

```text
RightGrip
    ↓
Trigger / pistol grip
```

## LeftGrip

This should be placed underneath the rifle's handguard.

For example:

```text
               Barrel
================================>

       Left Hand       Right Hand
           ↓               ↓
      [ LeftGrip ]    [ RightGrip ]
           │               │
           └──── Rifle ────┘
```

The exact CFrame should be adjusted visually in Studio.

---

# 5. Why Two Grip Attachments Are Important

Do not calculate the left hand position manually every frame.

Bad approach:

```lua
RunService.RenderStepped:Connect(function()
    character.LeftHand.CFrame = rifle.CFrame * offset
end)
```

This can fight against Roblox's animation system.

Instead:

```text
Weapon
 │
 ├── RightGrip
 │
 └── LeftGrip
       │
       ▼
     IKControl
       │
       ▼
   Left Hand
```

Roblox's `IKControl` is specifically designed for procedural poses such as placing a character's hand on a gun grip.

---

# 6. Animation Strategy

Create the following animations:

```text
WeaponAnimations
│
├── RifleHold
├── RifleWalk
├── RifleSprint
├── RifleAim
├── RifleFire
└── RifleReload
```

Minimum implementation:

```text
RifleHold
RifleWalk
RifleSprint
RifleReload
```

You can add shooting/recoil animation later.

---

# 7. Animation Priority

This is one of the most important parts.

Use:

```text
Normal movement animations
Priority = Movement

Weapon animations
Priority = Action

Reload
Priority = Action2
```

Roblox's animation priority order is:

```text
Action4
Action3
Action2
Action
Movement
Idle
Core
```

Higher-priority animations override lower-priority animations when they affect the same joints.

Therefore:

```text
Default Walk
Priority = Movement
        │
        │ lower priority
        ▼

RifleWalk
Priority = Action
        │
        ▼

Left / Right Arm
```

This prevents the normal walking animation from swinging the weapon arms.

---

# 8. Create RifleHold Animation

Open Roblox Animation Editor.

Create:

```text
RifleHold
```

Pose the character:

```text
                  Head
                   O
                  /|\
                 / |
                /  |
         Left Hand  Right Hand
              \       /
               \     /
                RIFLE
```

The important thing is:

```text
Left hand → LeftGrip
Right hand → RightGrip
```

Do not exaggerate arm movement.

The weapon should feel like it is part of the upper body.

---

# 9. Create RifleWalk Animation

Duplicate `RifleHold`.

Create:

```text
RifleWalk
```

Only animate:

```text
Legs
Lower body
Small torso movement
```

Keep the weapon arms relatively stable.

Bad:

```text
Left arm
   ↙
Rifle
   ↘
Right arm
```

Good:

```text
Left arm ───── Rifle ───── Right arm
                    │
                 stable
```

The legs should create the walking motion.

The arms should maintain the weapon pose.

---

# 10. Create RifleSprint Animation

Create:

```text
RifleSprint
```

The character can lean forward:

```text
      O
     /|
    / |
   /  |──── Rifle
  /   |
 /    |
```

But the arms should remain connected to the weapon.

Avoid:

```text
Sprint animation
     ↓
Arm swing
     ↓
Weapon swing
     ↓
IK correction
     ↓
Shaking
```

Instead:

```text
Sprint animation
     ↓
Lower body movement
     ↓
Weapon hold pose
     ↓
IK correction
     ↓
Stable weapon
```

---

# 11. Create the Left-Hand IK

R15 body parts:

```text
LeftUpperArm
     │
     ▼
LeftLowerArm
     │
     ▼
LeftHand
```

Create an `IKControl` under the Humanoid.

Example:

```lua
local function createLeftHandIK(character, weapon)
    local humanoid = character:WaitForChild("Humanoid")

    local leftHand = character:WaitForChild("LeftHand")
    local leftUpperArm = character:WaitForChild("LeftUpperArm")

    local weaponModel = weapon:WaitForChild("Model")
    local leftGrip = weaponModel:WaitForChild("LeftGrip")

    local ik = Instance.new("IKControl")

    ik.Name = "WeaponLeftHandIK"
    ik.Type = Enum.IKControlType.Transform

    ik.ChainRoot = leftUpperArm
    ik.EndEffector = leftHand
    ik.Target = leftGrip

    ik.Weight = 1
    ik.SmoothTime = 0.03
    ik.Priority = 10

    ik.Parent = humanoid

    return ik
end
```

`IKControl` requires `Type`, `ChainRoot`, `EndEffector`, and `Target` to be configured correctly.

---

# 12. Why Use Transform

For the support hand:

```lua
ik.Type = Enum.IKControlType.Transform
```

This aligns both position and rotation.

Roblox defines `Transform` as a full 6-DoF constraint that aligns the EndEffector CFrame with the Target CFrame.

This is useful for:

```text
LeftHand
    ↓
LeftGrip
```

because you want the hand orientation to match the rifle grip.

---

# 13. IK Smoothing

Use:

```lua
ik.SmoothTime = 0.03
```

or:

```lua
ik.SmoothTime = 0.05
```

Roblox's `SmoothTime` controls how quickly the IK EndEffector reaches its target.

Recommended starting values:

```text
0.00
│
├── Extremely responsive
├── Can look harsh
└── Can expose jitter
     
0.03
│
└── Recommended for weapon hand

0.05
│
└── Slightly smoother

0.10+
│
└── Noticeable hand lag
```

For a shooter:

```lua
ik.SmoothTime = 0.03
```

is a good starting point.

---

# 14. IK Weight

Use:

```lua
ik.Weight = 1
```

when the weapon is equipped.

When unequipping:

```lua
ik.Enabled = false
```

Do not rely only on:

```lua
ik.Weight = 0
```

because Roblox notes that other factors such as smoothing can still influence the pose when weight is zero. Disable the IK when it should not be active.

---

# 15. Weapon State Machine

Create a simple state machine:

```text
WeaponState

Idle
Walk
Sprint
Aim
Fire
Reload
```

Example:

```lua
local WeaponState = {
    Idle = "Idle",
    Walk = "Walk",
    Sprint = "Sprint",
    Aim = "Aim",
    Fire = "Fire",
    Reload = "Reload",
}
```

Current state:

```lua
local currentState = WeaponState.Idle
```

---

# 16. Detect Movement

Example:

```lua
local humanoid = character:WaitForChild("Humanoid")

local function getMovementState()
    local moving = humanoid.MoveDirection.Magnitude > 0.05

    if not moving then
        return WeaponState.Idle
    end

    if humanoid.WalkSpeed >= 20 then
        return WeaponState.Sprint
    end

    return WeaponState.Walk
end
```

Your actual sprint speed can be different.

For example:

```text
WalkSpeed = 8
SprintSpeed = 20
```

---

# 17. Animation Controller

Create:

```text
WeaponAnimationController
```

Example:

```lua
local animator = humanoid:WaitForChild("Animator")

local tracks = {}

local function loadAnimation(name, animationId)
    local animation = Instance.new("Animation")

    animation.Name = name
    animation.AnimationId = animationId

    local track = animator:LoadAnimation(animation)

    tracks[name] = track

    return track
end
```

Load:

```lua
loadAnimation("RifleHold", "rbxassetid://...")
loadAnimation("RifleWalk", "rbxassetid://...")
loadAnimation("RifleSprint", "rbxassetid://...")
loadAnimation("RifleAim", "rbxassetid://...")
loadAnimation("RifleReload", "rbxassetid://...")
```

---

# 18. Play Weapon Animations

Create a helper:

```lua
local currentTrack

local function playWeaponAnimation(name)
    local newTrack = tracks[name]

    if not newTrack then
        return
    end

    if currentTrack == newTrack then
        return
    end

    if currentTrack then
        currentTrack:Stop(0.15)
    end

    currentTrack = newTrack
    currentTrack:Play(0.15)
end
```

This prevents constantly restarting animations.

---

# 19. Update Walk / Sprint

Use:

```lua
local RunService = game:GetService("RunService")

RunService.RenderStepped:Connect(function()
    if not weaponEquipped then
        return
    end

    local state = getMovementState()

    if state == WeaponState.Idle then
        playWeaponAnimation("RifleHold")

    elseif state == WeaponState.Walk then
        playWeaponAnimation("RifleWalk")

    elseif state == WeaponState.Sprint then
        playWeaponAnimation("RifleSprint")
    end
end)
```

However, do not actually use this exact version in production if the animation is restarted frequently.

Instead, only change animation when the state changes:

```lua
local previousState

local function updateWeaponAnimation()
    local state = getMovementState()

    if state == previousState then
        return
    end

    previousState = state

    if state == WeaponState.Idle then
        playWeaponAnimation("RifleHold")

    elseif state == WeaponState.Walk then
        playWeaponAnimation("RifleWalk")

    elseif state == WeaponState.Sprint then
        playWeaponAnimation("RifleSprint")
    end
end
```

---

# 20. Do NOT Stop the IK When Walking

This is critical.

The IK should remain active:

```text
Idle
  ↓
IK ON

Walk
  ↓
IK ON

Sprint
  ↓
IK ON

Shoot
  ↓
IK ON

Reload
  ↓
IK OFF or reduced
```

The weapon grip moves with the weapon.

The IK follows the grip.

Therefore:

```text
Character movement
       ↓
Weapon movement
       ↓
LeftGrip movement
       ↓
IK
       ↓
LeftHand follows
```

Roblox's IK system continuously updates toward a target that moves through the world.

---

# 21. Shooting

The official Weapons Kit already supports:

```text
Semiautomatic
Automatic
Burst
```

For an assault rifle:

```text
FireMode = Automatic
```

and:

```text
ShotCooldown = 0.1
```

means the weapon can fire continuously while the player holds the fire input.

Do not build another firing loop just to solve the animation problem.

Keep:

```text
Weapons Kit
      │
      └── Fire
           ├── Projectile
           ├── Damage
           ├── Ammo
           └── Recoil
```

and let your new system handle:

```text
Character
      │
      ├── Hold pose
      ├── Walk pose
      ├── Sprint pose
      └── IK
```

---

# 22. Shooting While Walking

Desired behavior:

```text
Player
 │
 ├── MoveDirection != 0
 │
 ├── Walk animation
 │
 ├── RifleHold / RifleWalk
 │
 ├── LeftHand IK
 │
 └── Weapon fires
```

The important part is:

```text
Walk animation
     +
Weapon animation
     +
IK
```

rather than:

```text
Walk animation
     +
Weapon CFrame manipulation
```

---

# 23. Shooting While Sprinting

You have two design options.

## Option A — Allow shooting while sprinting

```text
Sprint
  +
Fire
```

Use:

```text
RifleSprint
+
IK
+
Weapon Fire
```

## Option B — Automatically leave sprint when shooting

This is more common in shooters.

```text
Sprint
   │
   │ fire
   ▼
Walk / Combat stance
   │
   ▼
Shoot
```

Implementation:

```lua
if isSprinting and isFiring then
    setSprint(false)
end
```

For a Zombie Rush-style game, Option B will usually feel better.

---

# 24. Shooting Animation

Do not make a large shooting animation.

Use a very small recoil animation:

```text
Frame 0
Normal

Frame 1
Rifle moves backward slightly

Frame 2
Return

Frame 3
Normal
```

Example:

```text
Normal

       O
      /|────── Rifle
     / |
```

Recoil:

```text
       O
      /|─── Rifle
     / |
       ↑
    slight recoil
```

Keep the movement small.

The official Weapons Kit already provides camera/weapon recoil configuration such as `RecoilMin`, `RecoilMax`, `RecoilDecay`, `RecoilDelayTime`, and `TotalRecoilMax`.

---

# 25. Avoid Double Recoil

Do not do:

```text
Weapons Kit recoil
+
Large animation recoil
+
CFrame recoil
+
IK movement
```

This causes:

```text
              ┌── Weapon Kit recoil
              │
Shoot ────────┼── Animation recoil
              │
              ├── CFrame recoil
              │
              └── IK correction
                       ↓
                    SHAKE
```

Instead:

```text
Shoot
 │
 ├── Weapons Kit → camera recoil
 │
 ├── Weapon → tiny visual recoil
 │
 └── IK → maintain hand position
```

---

# 26. Reload

When reloading:

```text
IK
 ↓
Weight = 0
 ↓
Reload animation
```

For example:

```lua
local function startReload()
    leftHandIK.Weight = 0

    local reloadTrack = tracks.RifleReload
    reloadTrack:Play(0.1)

    reloadTrack.Stopped:Connect(function()
        leftHandIK.Weight = 1
    end)
end
```

Alternatively:

```lua
leftHandIK.Enabled = false
```

during reload.

This allows the left hand to move naturally to the magazine.

---

# 27. Aim Down Sights

The Weapons Kit already supports:

```text
AimTrack
AimZoomTrack
```

with default rifle animation names such as:

```text
RifleAim
RifleAimDownSights
```

These are configured through the weapon's Configuration folder.

For ADS:

```text
Right Hand
     ↓
Rifle
     ↑
Left Hand IK
```

Keep IK enabled.

The weapon moves.

The left hand follows.

---

# 28. IK Priority

If you eventually add:

```text
LeftHandIK
RightHandIK
AimIK
LookIK
FootIK
```

use different priorities.

For example:

```lua
leftHandIK.Priority = 10
rightHandIK.Priority = 10
aimIK.Priority = 20
```

Roblox solves higher-priority IK controls later, meaning they can override lower-priority controls.

Possible hierarchy:

```text
Foot IK
Priority 1

Weapon Hand IK
Priority 10

Aim IK
Priority 20
```

---

# 29. Right-Hand IK — Should You Use It?

Initially:

**No.**

Use the normal weapon weld for the primary hand:

```text
RightHand
    ↓
Weapon Handle
```

and IK only for:

```text
LeftHand
    ↓
LeftGrip
```

Architecture:

```text
RightHand
    │
    ▼
HandleAttachment
    │
    ▼
Rifle

LeftHand
    │
    ▼
IKControl
    │
    ▼
LeftGrip
```

This is simpler and generally more stable.

Once this works, you can introduce full two-hand IK if necessary.

---

# 30. Recommended Final Hierarchy

Your character:

```text
Character
│
├── Humanoid
│   │
│   ├── Animator
│   ├── WeaponLeftHandIK
│   └── WeaponRightHandIK (optional)
│
├── HumanoidRootPart
│
├── UpperTorso
│
├── LeftUpperArm
├── LeftLowerArm
├── LeftHand
│
├── RightUpperArm
├── RightLowerArm
└── RightHand
```

Weapon:

```text
Auto Rifle
│
├── Configuration
│
├── Model
│   │
│   ├── PrimaryPart
│   ├── HandleAttachment
│   ├── TipAttachment
│   ├── LeftGrip
│   └── RightGrip
│
└── Handle
```

---

# 31. Complete IK Module

Create:

```text
ReplicatedStorage
└── WeaponModules
    └── WeaponIK.lua
```

Implementation:

```lua
local WeaponIK = {}

function WeaponIK.Create(character, weapon)
    local humanoid = character:WaitForChild("Humanoid")

    local leftUpperArm = character:WaitForChild("LeftUpperArm")
    local leftHand = character:WaitForChild("LeftHand")

    local weaponModel = weapon:WaitForChild("Model")
    local leftGrip = weaponModel:WaitForChild("LeftGrip")

    local ik = Instance.new("IKControl")

    ik.Name = "WeaponLeftHandIK"
    ik.Type = Enum.IKControlType.Transform

    ik.ChainRoot = leftUpperArm
    ik.EndEffector = leftHand
    ik.Target = leftGrip

    ik.Weight = 1
    ik.SmoothTime = 0.03
    ik.Priority = 10
    ik.Enabled = true

    ik.Parent = humanoid

    return ik
end

function WeaponIK.Enable(ik)
    ik.Enabled = true
    ik.Weight = 1
end

function WeaponIK.Disable(ik)
    ik.Enabled = false
end

function WeaponIK.BlendOut(ik)
    ik.Weight = 0
end

function WeaponIK.BlendIn(ik)
    ik.Enabled = true
    ik.Weight = 1
end

function WeaponIK.Destroy(ik)
    if ik then
        ik:Destroy()
    end
end

return WeaponIK
```

---

# 32. Weapon Character Controller

Create:

```text
StarterPlayer
└── StarterPlayerScripts
    └── WeaponCharacterController.client.lua
```

Basic implementation:

```lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local WeaponIK = require(
    game.ReplicatedStorage.WeaponModules.WeaponIK
)

local character
local humanoid
local currentWeapon
local leftHandIK

local function setupCharacter(newCharacter)

    character = newCharacter

    humanoid = character:WaitForChild("Humanoid")

end

local function equipWeapon(weapon)

    currentWeapon = weapon

    leftHandIK = WeaponIK.Create(
        character,
        weapon
    )

end

local function unequipWeapon()

    if leftHandIK then
        WeaponIK.Destroy(leftHandIK)
        leftHandIK = nil
    end

    currentWeapon = nil

end

player.CharacterAdded:Connect(setupCharacter)

if player.Character then
    setupCharacter(player.Character)
end
```

---

# 33. Animation State Controller

Add:

```lua
local currentState = nil

local function getState()

    if humanoid.MoveDirection.Magnitude < 0.05 then
        return "Idle"
    end

    if humanoid.WalkSpeed >= 20 then
        return "Sprint"
    end

    return "Walk"
end
```

Then:

```lua
local function updateState()

    if not currentWeapon then
        return
    end

    local newState = getState()

    if newState == currentState then
        return
    end

    currentState = newState

    if newState == "Idle" then
        playWeaponAnimation("RifleHold")

    elseif newState == "Walk" then
        playWeaponAnimation("RifleWalk")

    elseif newState == "Sprint" then
        playWeaponAnimation("RifleSprint")
    end

end
```

Update:

```lua
RunService.RenderStepped:Connect(function()

    if not character or not humanoid then
        return
    end

    updateState()

end)
```

---

# 34. Important: Do Not Constantly Restart Animations

Never do:

```lua
RunService.RenderStepped:Connect(function()

    playWeaponAnimation("RifleWalk")

end)
```

This causes:

```text
Play
Stop
Play
Stop
Play
Stop
```

which produces visual jitter.

Always use:

```lua
if newState ~= currentState then
    playAnimation()
end
```

---

# 35. Weapon Animation Layer

Final animation layers:

```text
                    Character
                       │
                       ▼
                Default Animator
                       │
             ┌─────────┴─────────┐
             │                   │
        Movement             Weapon
        Priority 1            Priority 2
             │                   │
          Legs                Arms
             │                   │
             └─────────┬─────────┘
                       ▼
                    IKControl
                       │
                       ▼
                Final character pose
```

This is the most important architectural principle.

---

# 36. Recommended Values

Start with:

```text
Weapon IK
────────────────────────
Type            Transform
Weight          1
SmoothTime      0.03
Priority        10
```

Animation:

```text
RifleHold
Priority        Action
Looped          Yes

RifleWalk
Priority        Action
Looped          Yes

RifleSprint
Priority        Action
Looped          Yes

RifleReload
Priority        Action2
Looped          No
```

Weapon:

```text
FireMode        Automatic
ShotCooldown    0.1
```

Recoil:

```text
RecoilMin       Small
RecoilMax       Small
RecoilDecay     ~0.825
TotalRecoilMax  ~2
```

The Weapons Kit's default rifle-related configuration includes values around these ranges, but tune them according to your game's feel.

---

# 37. Debugging Hand Shaking

If the hand is shaking, check these in order.

## Problem 1 — Walk animation controls the arms

Check:

```text
Walk Animation
Priority = Movement
```

and:

```text
Weapon Animation
Priority = Action
```

---

## Problem 2 — IK target is moving unexpectedly

Check:

```text
LeftGrip
```

Make sure it is attached to the weapon model and isn't being independently moved.

---

## Problem 3 — Multiple scripts modify the hand

Search your project for:

```text
CFrame =
Motor6D
Transform =
LeftHand
LeftLowerArm
LeftUpperArm
IKControl
```

You should avoid having several systems simultaneously controlling the same arm.

---

## Problem 4 — IK SmoothTime is too high

Try:

```lua
ik.SmoothTime = 0
```

If that is stable but harsh:

```lua
ik.SmoothTime = 0.02
```

Then:

```lua
ik.SmoothTime = 0.03
```

---

## Problem 5 — Animation and IK are fighting

Temporarily disable IK:

```lua
ik.Enabled = false
```

If the animation looks stable:

```text
Animation = OK
IK = Problem
```

If it still shakes:

```text
Animation = Problem
```

---

# 38. Testing Checklist

Test these cases separately.

### Test 1 — Idle

```text
Equip rifle
↓
Stand still
↓
Both hands stable
```

### Test 2 — Walk

```text
Walk
↓
Hands remain on rifle
↓
No arm swinging
```

### Test 3 — Sprint

```text
Sprint
↓
Weapon stays attached
↓
No hand separation
```

### Test 4 — Shoot

```text
Idle
↓
Shoot
↓
Small recoil
↓
No shaking
```

### Test 5 — Walk + Shoot

```text
Walk
+
Shoot
↓
No shaking
```

### Test 6 — Sprint + Shoot

```text
Sprint
+
Shoot
↓
Either:
    Sprint continues
OR
    Sprint transitions to combat walk
```

### Test 7 — Reload

```text
Shoot
↓
Reload
↓
Left hand releases grip
↓
Reload animation
↓
Left hand returns
↓
IK enabled
```

### Test 8 — Aim

```text
Aim
↓
Weapon moves into ADS
↓
Left hand follows
↓
No snapping
```

---

# 39. Recommended Development Order

Do NOT implement everything at once.

Follow this order:

```text
Phase 1
│
├── Import official Auto Rifle
├── Verify firing
└── Verify reload
        ↓
Phase 2
│
├── Add RightGrip
├── Add LeftGrip
└── Position grips
        ↓
Phase 3
│
├── Create RifleHold
└── Set priority = Action
        ↓
Phase 4
│
├── Create LeftHand IK
└── Verify stable hand
        ↓
Phase 5
│
├── Create RifleWalk
└── Test walking
        ↓
Phase 6
│
├── Create RifleSprint
└── Test sprinting
        ↓
Phase 7
│
├── Shooting
├── Recoil
└── Walk + Shoot
        ↓
Phase 8
│
├── ADS
├── Reload
└── Animation blending
        ↓
Phase 9
│
└── Multiplayer testing
```

---

# 40. Final Architecture

The finished system should look like:

```text
                         PLAYER
                           │
                           ▼
                     R15 CHARACTER
                           │
              ┌────────────┴────────────┐
              │                         │
              ▼                         ▼
       Movement System            Weapons Kit
              │                         │
       ┌──────┼──────┐            ┌─────┼─────┐
       │      │      │            │     │     │
      Idle   Walk  Sprint        Fire  Reload Aim
       │      │      │            │     │     │
       └──────┼──────┘            └─────┼─────┘
              │                         │
              ▼                         ▼
       Weapon Animations          Weapon Model
              │                         │
              │                    ┌────┴────┐
              │                    │         │
              │                RightGrip  LeftGrip
              │                    │         │
              ▼                    │         ▼
          Arm Pose                 │      IKControl
              │                    │         │
              └────────────────────┴─────────┘
                           │
                           ▼
                    FINAL CHARACTER POSE
                           │
                           ▼
                     RENDER / REPLICATE
```

---

# 41. Key Rules

## Rule 1

**Do not manually CFrame the player's hands every frame.**

Use:

```text
Animation + IK
```

---

## Rule 2

**Do not let the normal walk animation control the weapon arms.**

Use:

```text
Movement → legs/body
Weapon Animation → arms
```

---

## Rule 3

**Use the weapon itself as the IK target.**

```text
LeftHand
    ↓
IK
    ↓
LeftGrip
    ↓
Rifle
```

---

## Rule 4

**Keep IK enabled during movement.**

```text
Idle   → IK ON
Walk   → IK ON
Sprint → IK ON
Shoot  → IK ON
```

---

## Rule 5

**Do not stack multiple recoil systems.**

Prefer:

```text
Weapons Kit
    ↓
Camera recoil

Small weapon animation
    ↓
Visual recoil

IK
    ↓
Hand stability
```

---

# 42. Expected Result

After completing the implementation:

```text
                    IDLE

                       O
                      /|────── Rifle
                     / |
                    /  \
                   /    \

                    ↓

                    WALK

                       O
                      /|────── Rifle
                     / |
                    /  \
                   /    \
                legs moving


                    ↓

                   SPRINT

                      O
                     /|────── Rifle
                    / |
                   /  |
                  /   |
             body leaning


                    ↓

                WALK + SHOOT

                       O
                      /|────── Rifle
                     / |
                    /  \
                   /    \

                  ↑
              small recoil


                    ↓

                BOTH HANDS

              Left Hand ───────┐
                               │
                           ┌───┴───┐
                           │ Rifle │
                           └───┬───┘
                               │
              Right Hand ──────┘
```

The important visual property is:

```text
          HAND
            │
            │
            ▼
         GRIP
            │
            ▼
         WEAPON
```

The weapon becomes the stable reference point, and the IK system continuously solves the support hand toward that reference. Roblox explicitly supports this use case for `IKControl`, including holding guns and aiming in third-person shooters.

---

# 43. References

* Roblox Weapons Kit:
  https://create.roblox.com/docs/resources/weapons-kit

* Roblox IKControl:
  https://create.roblox.com/docs/reference/engine/classes/IKControl

* Roblox Animation Priority:
  https://create.roblox.com/docs/reference/engine/enums/AnimationPriority

* Roblox Animation Editor:
  https://create.roblox.com/docs/animation/editor
