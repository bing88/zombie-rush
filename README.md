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
| Remotes | `ReplicatedStorage/Remotes/init.lua` | FireWeapon, ZombieHPChanged, PlayerHPChanged, PlayerDied. |
| Shooting (server-authoritative) | `ServerScriptService/Services/WeaponService.server.lua` | Validates fire rate + ammo, raycasts, applies damage, headshot multiplier. Client cannot control damage or bypass spread. |
| Zombie spawn + AI | `ServerScriptService/Services/ZombieService.server.lua` | Trickle-spawns zombies (max 8 concurrent), direct-chase AI (no PathfindingService — see "Open Decisions" in the plan doc). Builds a placeholder procedural rig since no art exists yet. |
| Player HP/death/respawn | `ServerScriptService/Services/PlayerService.server.lua` | Uses Roblox's default `LoadCharacter` respawn flow. |
| Client input | `StarterPlayer/StarterPlayerScripts/Controllers/WeaponController.lua` | Hold left mouse to fire (full-auto gated by weapon fire rate). Local ammo/reload state is **prediction only** for UI responsiveness — the server keeps its own authoritative copy and silently drops anything it disagrees with. |
| Client UI | `StarterPlayer/StarterPlayerScripts/Controllers/UIController.lua` | HP bar, ammo counter, death overlay. Nothing else. |
| Bootstrap | `StarterPlayer/StarterPlayerScripts/ClientMain.client.lua` | Wires controllers together. |

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
4. Add a Baseplate to Workspace if the place is empty (Tier 0 doesn't need
   anything fancier).
5. Press **Play** (Studio Play, not just Run — you need a Player object for
   `Players.PlayerAdded` to fire).
6. Hold left mouse to shoot. Zombies spawn every 3 seconds near
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
