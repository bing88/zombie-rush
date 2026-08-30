# Zombie Shooter — Tier 1

Tier 1 is the full MVP scope from the reconciled plan: 1–4 player co-op, 3
zombie types, 3 weapons, 10 waves + a boss, coins + basic weapon upgrades,
DataStore persistence, and a lobby → match → lobby loop. It's built directly
on top of the Tier 0 prototype (see `zombie-shooter-mvp-plan.md`).

---

## What's included

| System | File(s) | Notes |
|---|---|---|
| Weapon config | `ReplicatedStorage/Shared/WeaponConfig.lua` | Pistol (free starter), AssaultRifle, Shotgun. Data-driven — add a 4th weapon by adding one entry here + one visual entry in `WeaponModelFactory`. |
| Zombie config | `ReplicatedStorage/Shared/ZombieConfig.lua` | Normal, Fast, Tank, Ranged, Exploder, Boss (2-phase enrage at 50% HP). `AttackType` field drives which AI branch ZombieService uses (Melee/Ranged/Explode). |
| Wave config | `ReplicatedStorage/Shared/WaveConfig.lua` | 10 hand-tuned waves + lobby/break/boss/victory timings. Balance lives entirely here. |
| Wave modifiers | `ReplicatedStorage/Shared/WaveModifiers.lua` | 5 random per-wave modifiers (Swarm/Juggernaut/Payday/Bloodbath/Normal), one picked randomly for each regular wave (not the boss wave). Scales HP/speed/damage/coin multipliers. |
| Upgrade config | `ReplicatedStorage/Shared/UpgradeConfig.lua` | 5 upgrade levels per weapon — damage multiplier AND magazine capacity bonus scale together (see `MagazineBonus`). |
| Weapon model | `ReplicatedStorage/Shared/WeaponModelFactory.lua` | `CreateTool(weaponName)` loads the real model from Roblox's official [Weapons Kit](https://create.roblox.com/docs/resources/weapons-kit) per weapon (Pistol `118912302094201`, AssaultRifle (Auto Rifle) `96131146947811`, Shotgun `104068096273092`) via `AssetService:LoadAssetAsync` (requires "Allow Loading Third Party Assets" — see Setup below). None of the kit's own `WeaponsSystem` framework (fire/reload/ammo/recoil/camera/GUI scripts) is imported — only the visual geometry, using the kit's documented `TipAttachment`/`HandleAttachment` to correctly place the `Muzzle` attachment and derive `Tool.Grip`. Falls back to a placeholder Tool (Handle + Muzzle attachment) if the asset can't load or has no usable Tool/Handle inside. |
| Remotes | `ReplicatedStorage/Remotes/init.lua` | All client/server events. No "switch weapon" remote — that rides on Roblox's default Backpack hotbar. |
| Shooting (server-authoritative) | `ServerScriptService/Services/WeaponService.server.lua` | Validates fire rate, ammo, reload, and that the client is only ever firing the Tool actually equipped (which also enforces weapon ownership). Multi-pellet shotgun spread, per-weapon ammo, upgrade damage multipliers. Blocks firing while downed (see `DownedState`). Reports damage/headshot-kills to `StatsService`; every hit result now includes `Killed` for the client hitmarker. |
| Zombie spawn + AI | `ServerScriptService/Services/ZombieService.lua` | ModuleScript now (Tier 0's endless auto-spawn loop is gone) — `SpawnZombie(type, position, hpMultiplier?, speedMultiplier?, damageMultiplier?)` is called by WaveService (multipliers come from the current wave's modifier). Direct-chase for Normal/Fast/Ranged, PathfindingService for Tank/Boss, a one-shot detonate-on-contact-or-death branch for Exploder. Each type loads a real toolbox model via `AssetService:LoadAssetAsync` (requires "Allow Loading Third Party Assets" — see Setup below) (Normal `3924238625`, Fast `306542926` "Skeleton Dog", Tank `305897868` "NERF Zombie", Boss `319386664` "Axe Monster"; Ranged/Exploder use the placeholder rig, no asset assigned yet), cloned per spawn from a cached template; any `Script`/`LocalScript` in the asset is stripped, *except* `Animate`/`RbxNpcSounds` on the Normal zombie specifically — the only asset verified to actually be a standard, compatible rig; every other (community-sourced) type always strips its own scripts too, since they'd otherwise risk hanging forever `WaitForChild`-ing body parts a non-standard model doesn't have (we drive HP/AI ourselves regardless — the asset's own AI is never trusted either way). The root part is standardized to `HumanoidRootPart` regardless of the source asset's naming. Falls back to the placeholder rig per-type if that type's asset can't load or has no usable Humanoid-capable structure (a warning prints either way, gameplay still works) — this placeholder is a full torso+head+2 arms+2 legs blocky R6-proportioned body: arms are welded in a fixed "reach forward" zombie pose, and legs are Motor6D-jointed at the hip and procedurally swing through a walk/run cycle (`animateLegWalk`) driven by actual root-part travel distance, snapping back to standing the instant it stops moving. Applies a knockback velocity impulse + a death groan sound ([community SFX](https://create.roblox.com/store/asset/116391542832455/Fast-Zombie-Die), used for every type) on every death, and a shorter, briefly-stunning knockback punch (`ApplyHitKnockback`) on every hit the zombie survives. |
| DataStore persistence | `ServerScriptService/Services/DataService.lua` | Coins, unlocked weapons, upgrade levels. Autosaves every 90s + on leave + on server close. Falls back to in-memory defaults if DataStore access fails (e.g. Studio without "Enable Studio Access to API Services"). |
| Best-wave leaderboard | `ServerScriptService/Services/LeaderboardService.lua` | Global top-10 "best wave reached" via `OrderedDataStore`, write-throttled to only save on an actual personal-best improvement. Client requests fresh data each time the leaderboard panel opens. |
| Match stats | `ServerScriptService/Services/StatsService.lua` | Per-match kills/damage/coins-earned (for the end-of-match scoreboard) and a session objective — 10 headshot kills for a 100-coin bonus. This is a SESSION objective, not a true daily (see the file's doc comment for why that's a deliberate simplification, not an oversight). Reset by WaveService at the start of every match. |
| Downed/revive state | `ServerScriptService/Services/DownedState.lua` | Shared flag (same pattern as `MatchState`) tracking which players are currently downed — read by `WeaponService` (blocks firing) and written by `PlayerService`. |
| Match state machine | `ServerScriptService/Services/WaveService.server.lua` | Lobby (waits for a confirmed "yes" on the teleport pad — no longer auto-starts) → countdown → 9 waves (each with a random modifier + a break) → boss → **Victory or Defeat** → back to lobby, forever. Awards coins per kill (scaled by the wave's coin modifier) + a victory bonus. Broadcasts the end-of-match scoreboard and reports wave progress to the leaderboard. |
| Shop | `ServerScriptService/Services/ShopService.server.lua` | Buy AssaultRifle/Shotgun via physical stalls. Upgrade any owned weapon (levels 1-5) either at a physical stall OR anytime via the client's upgrade panel (`ShopController`) — both paths call the same server-side validation. Applies the prestige cosmetic live the instant a weapon hits max level. |
| Internal signals | `ServerScriptService/Services/InternalSignals.lua` | Server-only cross-service signal (not a RemoteEvent) — lets `ShopService` tell `WeaponService` to refresh a player's ammo display immediately after an upgrade changes their magazine capacity. |
| Player HP/death/respawn/backpack | `ServerScriptService/Services/PlayerService.server.lua` | Loads the player's DataService profile and gives Tools for every unlocked weapon on spawn (Pistol auto-equipped, prestige effect applied if maxed). **New: downed/revive system** — mid-match, health hitting 0 is intercepted and pinned at 1 instead of triggering a real death; the player is immobilized with a "hold E to revive" `ProximityPrompt` on their body and a bleed-out timer. A revived player returns at 50% HP; an un-revived one truly dies (waits for the match to end rather than auto-respawning) — this is what makes Defeat possible, which didn't exist before this pass (Tier 1 previously had infinite mid-match respawns). |
| Map | `ServerScriptService/MapBootstrap.server.lua` | Lobby (shop + upgrade stalls + teleport pad + landmark) → lit corridor → arena (10 cover crates, 6 barrels, 3 dividing walls, a raised catwalk with ramps + full side railings, 10-point spawn ring, a 3x3 grid of overhead lamp posts). `Lighting.Brightness`/`Ambient` raised well above default dusk values specifically because the arena previously had zero light fixtures of its own (only the lobby/corridor did) and read as near-pitch-black even with the global atmosphere tuned — gameplay visibility wins over mood here. Still placeholder blocky geometry — no art pipeline yet. Solid perimeter walls sit flush with the lobby's and arena's actual floor edges (each with a doorway-width gap lining up with the corridor), the corridor floor now runs the full distance to the arena with no gap, and the arena floor was widened east to actually sit under the barrel cover cluster — closes off every way we'd previously seen someone fall through the map. A `FallSafetyNet` far below everything (Y = -50) is a last-resort backstop on top of that: catches anyone who still ends up falling and teleports them back to the lobby or arena. **A second map/arena variant was intentionally not built this pass** — focus stayed on one complete map + finishing the game-cycle systems around it. |
| Client input | `StarterPlayer/StarterPlayerScripts/Controllers/WeaponController.lua` | Hold fire button/tap-and-hold to fire, `R`/Reload button to reload. Tracks equipped weapon via `Tool.Equipped` so switching weapons (number keys / Backpack hotbar) just works. |
| Client UI | `StarterPlayer/StarterPlayerScripts/Controllers/UIController.lua` | HP bar, per-weapon ammo counter (shrunk, shakes on fire), coin counter, wave counter + modifier chip, boss HP bar, match-state banner, shop toast, gapped-tick crosshair, hitmarker (white hit / gold kill), full-screen damage vignette, reload button, start-match Yes/No confirmation dialog, downed banner with bleed-out countdown, session-objective progress widget, end-of-match scoreboard, best-wave leaderboard panel (`L` key), death overlay. |
| Client shop panel | `StarterPlayer/StarterPlayerScripts/Controllers/ShopController.lua` | Toggleable (press `U` or tap the on-screen tab) panel listing all 3 weapons with current level and upgrade cost — buy from anywhere, no stall required. |
| Client effects | `StarterPlayer/StarterPlayerScripts/Controllers/EffectsController.lua` | Tracer/flash/hit-spark/damage-number per pellet (shotgun fires up to 8 at once). Also draws a green tracer for incoming Ranged-zombie attacks and an expanding ring + burst for Exploder detonations. Fire sound uses each weapon's own bundled "Fired" `Sound` from the Weapons Kit asset (falls back to a placeholder click if a weapon lacks one); reload sound (played from `WeaponViewController.lua`) similarly uses the asset's own "Reload" `Sound`. Also plays the classic ["oof"](https://create.roblox.com/store/asset/79348298352567/Official-OOF-Sound-Effect) (non-positional, local-only) whenever the local player takes damage (`PlayLocalHitSound`, driven by `ClientMain`'s `PlayerHPChanged` handler). |
| Client camera/facing | `StarterPlayer/StarterPlayerScripts/Controllers/CameraController.lua` | Unchanged from Tier 0 — character-facing, over-the-shoulder camera, auto-aim lock-on. |

### Controls

- **Fire:** hold left mouse (desktop) or hold your finger down on the screen (mobile/touch)
- **Reload:** press `R` (desktop) or tap the **RELOAD** button
- **Switch weapon:** press `1`/`2`/`3` or click a slot in your Backpack hotbar (Roblox default — only shows weapons you've unlocked)
- **Toggle first-person / third-person:** press `V`
- **Open upgrade panel:** press `U` or tap the **UPGRADES** tab (works anywhere, no stall needed)
- **Open leaderboard:** press `L` or tap the **LEADERBOARD** tab
- **Revive a downed teammate:** walk up to them and hold `E`
- **Buy a weapon / interact:** walk up to a stall and hold the interact key (`E` by default)
- **Start a match:** walk onto the glowing teleport pad in the lobby and hold `E` — confirm "Yes, start" in the popup

---

## Setup

1. Install [Rojo](https://rojo.space/) (VS Code extension + the `rojo` CLI) if you haven't already.
2. From this folder, run:
   ```bash
   rojo serve
   ```
3. In Roblox Studio, open the Rojo plugin and click **Connect**.
4. Press **Play** (Studio Play, not just Run).
5. You spawn in the **lobby**. Nothing starts automatically — walk onto the teleport pad and confirm to begin the countdown into wave 1.

**Studio setup — 2 separate settings, both under *File → Game Settings → Security*:**

- **Enable Studio Access to API Services** — needed for `DataService`'s DataStore calls (coins/unlocks persistence). Without it, DataService falls back to in-memory defaults each session.
- **Allow Loading Third Party Assets** — needed for `ZombieService`/`WeaponModelFactory` to load *any* of the real weapon/zombie models. None of those assets are owned by your account or by Roblox, so `AssetService:LoadAssetAsync` refuses to load them at all until this is turned on — **this is almost certainly why you're only seeing placeholder rigs/blocks.** Without it, every weapon/zombie falls back to its placeholder (a `WeaponModelFactory:`/`ZombieService:` warning prints in the Output window either way — check there if something still won't load after enabling this).

Both settings are saved with the place, so you only need to set them once (per place file).

**Real asset caveat:** Normal's zombie model and all 3 weapon models are official Roblox kits with documented structure (NPC kit / Weapons Kit), so their loading is fairly precise. The Fast/Tank/Boss zombie models are still unofficial toolbox uploads of unknown internal structure — `ZombieService` handles them defensively (strip unknown scripts, guess at root parts), but grips, scale, or collision may need manual tuning in Studio once you've seen them in-game.

**If you still only see placeholders after enabling "Allow Loading Third Party Assets":** open the Output window in Studio and look for lines starting with `WeaponModelFactory:` or `ZombieService:` — each one states exactly why that specific asset fell back (load failure vs. no usable Tool/Handle/Humanoid found inside it, or a `:Clone()` failure — some Store assets come back with `Archivable = false` on parts, which both scripts now force back to `true` on the cached template right after loading it), which is the fastest way to tell what's actually wrong.

---

## What's intentionally cut from Tier 1 (per the reconciled plan)

- XP/levels — coins-only economy
- Roguelite random upgrades, perks, gems/premium currency
- Full weapon upgrade curve (levels 4-10)
- 2nd+ map
- A shop *menu* GUI — physical ProximityPrompt stalls instead

See `zombie-shooter-mvp-plan.md` for the full roadmap and Gate 2 success metric.
