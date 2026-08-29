# Zombie Shooter — Tier 0 Prototype

This is the **Tier 0** scope from the reconciled MVP plan: one player, one map
(a baseplate is fine), one zombie type, one weapon. No waves, no coins, no
XP, no UI beyond HP/ammo. The only question this build exists to answer is:

> **Does shooting a zombie feel good, repeatedly, for a few minutes?**

Don't add anything not listed below until that question has a clear "yes"
from you and 2-3 other testers (see Gate 0 in the reconciled plan doc).

---

## What's included

| System | File(s) | Notes |
|---|---|---|
| Weapon config | `ReplicatedStorage/Shared/WeaponConfig.lua` | One weapon: AssaultRifle. Data-driven so Tier 1 just adds entries. |
| Zombie config | `ReplicatedStorage/Shared/ZombieConfig.lua` | One type: Normal. |
| Weapon model | `ReplicatedStorage/Shared/WeaponModelFactory.lua` | Builds a placeholder Tool (Handle + Muzzle attachment) so the gun is visible in-hand and raycasts originate from the barrel, not the torso. Swap for real rigged art later without touching any other script. |
| Remotes | `ReplicatedStorage/Remotes/init.lua` | FireWeapon, ReloadWeapon, AmmoUpdated, WeaponFired, ZombieHPChanged, PlayerHPChanged, PlayerDied. |
| Shooting (server-authoritative) | `ServerScriptService/Services/WeaponService.server.lua` | Validates fire rate + ammo + reload state, raycasts from the equipped Tool's muzzle, applies damage, headshot multiplier, handles manual + auto reload, broadcasts `WeaponFired` (origin, endpoint, hit result, damage dealt) to all clients for tracer/flash/sound/damage-number effects. Client cannot control damage, ammo, or bypass spread. |
| Zombie spawn + AI | `ServerScriptService/Services/ZombieService.server.lua` | Trickle-spawns zombies (max 8 concurrent), direct-chase AI (no PathfindingService — see "Open Decisions" in the plan doc). Builds a placeholder procedural rig since no art exists yet. |
| Player HP/death/respawn/weapon | `ServerScriptService/Services/PlayerService.server.lua` | Uses Roblox's default `LoadCharacter` respawn flow. Auto-equips the AssaultRifle Tool on every spawn. |
| Client input | `StarterPlayer/StarterPlayerScripts/Controllers/WeaponController.lua` | Fires wherever the camera is currently pointing (`camera.CFrame.LookVector`) — whether that's manual aim or `CameraController`'s auto-aim lock; there's only ever one aim direction, never a separate hidden override. Triggers on the dedicated Fire button being held, or on `CameraController.IsLocked()` being true. `R` or the on-screen Reload button to reload. Local ammo/reload state is **prediction only** — `SyncFromServer()` overwrites it with the server's authoritative value whenever `AmmoUpdated` arrives. **Must `Init()` after `CameraController`** — see comment in `ClientMain`. |
| Client auto-aim (detection) | `StarterPlayer/StarterPlayerScripts/Controllers/AutoAimController.lua` | Pure detection utility — given the camera's position/look direction, finds the best zombie target within an 8° cone and 50 studs. Returns just the target part; doesn't touch the camera. Not a trust boundary — the server independently raycasts and validates every shot regardless of where the direction came from. |
| Client weapon view | `StarterPlayer/StarterPlayerScripts/Controllers/WeaponViewController.lua` | Placeholder reload "animation" — tweens the equipped Tool's `Grip` CFrame to fake a dip-and-return motion, since no real animation asset exists yet. Local-only; doesn't replicate to other clients. |
| Client UI | `StarterPlayer/StarterPlayerScripts/Controllers/UIController.lua` | HP bar, ammo counter (shows "RELOADING..." mid-reload), crosshair, Reload button, circular Fire button (bottom-right), death overlay. |
| Client effects | `StarterPlayer/StarterPlayerScripts/Controllers/EffectsController.lua` | Purely cosmetic — turns each server `WeaponFired` broadcast into a bullet tracer, muzzle flash, fire sound, and (on a hit) a hit spark, hit sound, and a floating "-N" damage number. Runs for every player's shots, not just your own. Sounds use Roblox's own bundled `rbxasset://sounds/...` clips as placeholders — swap for real SFX later (see plan Phase 8). |
| Client camera/facing/lock-on | `StarterPlayer/StarterPlayerScripts/Controllers/CameraController.lua` | Disables `Humanoid.AutoRotate` and locks character yaw to camera yaw every frame. Sets the over-the-shoulder camera offset and handles the first-person toggle (`V`). Also **actually bends the camera's look direction** toward an `AutoAimController` target when one qualifies (smooth lerp, not instant), so the crosshair visually settles on it. Exposes `IsLocked()`. Snaps back to normal look the instant a target leaves range — a deliberate genre-appropriate tradeoff, not a bug (see comment in the file for why). |
| Bootstrap (client) | `StarterPlayer/StarterPlayerScripts/ClientMain.client.lua` | Wires controllers together. |
| Bootstrap (map) | `ServerScriptService/MapBootstrap.server.lua` | Creates a baseplate + SpawnLocation on server start if they don't already exist, so the place is playable immediately after a fresh sync. |

### Controls

- **Fire:** hold the on-screen **FIRE** button (bottom-right circle) — works via mouse click or touch hold on any platform. Screen-tap-anywhere no longer fires.
- **Auto-aim/auto-fire:** if a zombie is within ~50 studs and close to your crosshair (within an 8° cone), the camera itself smoothly turns to lock onto it (not just a silent fire-direction swap) and fires automatically — no button needed. The Fire button is for anything outside that assist range/cone. Releasing lock snaps the camera back instantly, which is intentional (see `CameraController.lua`).
- **Reload:** press `R` (desktop) or tap the **RELOAD** button (works on any platform)
- **Toggle first-person / third-person:** press `V`

---

## What's intentionally stubbed / missing (do not add yet)

- No waves, no wave UI
- No coins, no XP, no progression
- No weapon switching (one weapon only)
- No multiplayer testing beyond "more than one Player object exists" — full
  server-authority hardening happens in Phase 3 / Tier 1
- No DataStore
- No real zombie/weapon art — `createZombieModel()` in ZombieService builds a
  procedural placeholder rig (colored blocks) specifically so you can test
  gameplay before any art pipeline exists
- No map polish — a Baseplate works fine; optionally add a `ZombieSpawns`
  folder in Workspace containing Parts to control spawn locations, otherwise
  zombies spawn at a fixed default position

---

## Setup

1. Install [Rojo](https://rojo.space/) (VS Code extension + the `rojo` CLI,
   or the standalone plugin) if you haven't already.
2. From this folder, run:
   ```bash
   rojo serve
   ```
3. In Roblox Studio, open the Rojo plugin and click **Connect**.
   `MapBootstrap.server.lua` creates a baseplate + SpawnLocation
   automatically the first time the server runs — you don't need to build
   anything in Studio manually. If you start from a template that already
   has terrain/parts you want instead, just delete or edit the
   `MapBootstrap.server.lua` logic.
4. Press **Play** (Studio Play, not just Run — you need a Player object for
   `Players.PlayerAdded` to fire).
5. Hold left mouse to shoot. Zombies spawn every 3 seconds near
   `(0, 5, 20)` unless you've added a `ZombieSpawns` folder.

---

## When you're ready to move past Tier 0

Check it against **Gate 0** from the reconciled plan doc:

> You + 2-3 others voluntarily keep playing past 2 minutes without prompting.

If yes → move to Tier 1: add Fast/Tank zombies, Pistol/Shotgun, a wave
system, coins, and basic anti-cheat hardening beyond what's here. Say the
word and I'll scaffold Tier 1 on top of this same project structure.

If no → don't add more systems. Iterate on gun feel first: recoil, hit
feedback (sound/particles), fire rate, damage numbers, zombie reaction to
being hit. More content will not fix a shooting mechanic that isn't fun yet.
