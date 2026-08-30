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
| Zombie config | `ReplicatedStorage/Shared/ZombieConfig.lua` | Normal, Fast, Tank, Boss (2-phase enrage at 50% HP). |
| Wave config | `ReplicatedStorage/Shared/WaveConfig.lua` | 10 hand-tuned waves + lobby/break/boss/victory timings. Balance lives entirely here. |
| Upgrade config | `ReplicatedStorage/Shared/UpgradeConfig.lua` | 3 upgrade levels per weapon, flat damage multipliers. |
| Weapon model | `ReplicatedStorage/Shared/WeaponModelFactory.lua` | `CreateTool(weaponName)` loads the real model from Roblox's official [Weapons Kit](https://create.roblox.com/docs/resources/weapons-kit) per weapon (Pistol `118912302094201`, AssaultRifle (Auto Rifle) `96131146947811`, Shotgun `104068096273092`) via `AssetService:LoadAssetAsync` (requires "Allow Loading Third Party Assets" — see Setup below). None of the kit's own `WeaponsSystem` framework (fire/reload/ammo/recoil/camera/GUI scripts) is imported — only the visual geometry, using the kit's documented `TipAttachment`/`HandleAttachment` to correctly place the `Muzzle` attachment and derive `Tool.Grip`. Falls back to a placeholder Tool (Handle + Muzzle attachment) if the asset can't load or has no usable Tool/Handle inside. |
| Remotes | `ReplicatedStorage/Remotes/init.lua` | All client/server events. No "switch weapon" remote — that rides on Roblox's default Backpack hotbar. |
| Shooting (server-authoritative) | `ServerScriptService/Services/WeaponService.server.lua` | Validates fire rate, ammo, reload, and that the client is only ever firing the Tool actually equipped (which also enforces weapon ownership). Multi-pellet shotgun spread, per-weapon ammo, upgrade damage multipliers. |
| Zombie spawn + AI | `ServerScriptService/Services/ZombieService.lua` | ModuleScript now (Tier 0's endless auto-spawn loop is gone) — `SpawnZombie(type, position)` is called by WaveService. Direct-chase for Normal/Fast, PathfindingService for Tank/Boss. Each type loads a real toolbox model via `AssetService:LoadAssetAsync` (requires "Allow Loading Third Party Assets" — see Setup below) (Normal `3924238625`, Fast `82664805038905`, Tank `14000778389`, Boss `158642843`), cloned per spawn from a cached template; any `Script`/`LocalScript` in the asset is stripped except ones named `Animate`/`RbxNpcSounds` (we drive HP/AI ourselves — the asset's own is never trusted), and the root part is standardized to `HumanoidRootPart` regardless of the source asset's naming. Falls back to the placeholder blocky rig per-type if that type's asset can't load or has no usable Humanoid-capable structure (a warning prints either way, gameplay still works). |
| DataStore persistence | `ServerScriptService/Services/DataService.lua` | Coins, unlocked weapons, upgrade levels, secret-found flag. Autosaves every 90s + on leave + on server close. Falls back to in-memory defaults if DataStore access fails (e.g. Studio without "Enable Studio Access to API Services"). |
| Match state machine | `ServerScriptService/Services/WaveService.server.lua` | Lobby → countdown → 10 waves (with breaks) → boss → victory → back to lobby, forever. Awards coins per kill + a victory bonus. |
| Shop | `ServerScriptService/Services/ShopService.server.lua` | Buy AssaultRifle/Shotgun, upgrade any weapon (levels 1-3), claim the secret stash — all via physical `ProximityPrompt` stalls, no shop menu GUI. |
| Player HP/death/respawn/backpack | `ServerScriptService/Services/PlayerService.server.lua` | Loads the player's DataService profile and gives Tools for every unlocked weapon on spawn (Pistol auto-equipped). |
| Map | `ServerScriptService/MapBootstrap.server.lua` | Lobby (shop + upgrade stalls) → corridor → arena (10 cover crates, 3 dividing walls, 10-point spawn ring) → 1 hidden secret room. Still placeholder blocky geometry — no art pipeline yet. |
| Client input | `StarterPlayer/StarterPlayerScripts/Controllers/WeaponController.lua` | Hold fire button/tap-and-hold to fire, `R`/Reload button to reload. Tracks equipped weapon via `Tool.Equipped` so switching weapons (number keys / Backpack hotbar) just works. |
| Client UI | `StarterPlayer/StarterPlayerScripts/Controllers/UIController.lua` | HP bar, per-weapon ammo counter, coin counter, wave counter, boss HP bar, match-state banner, shop toast, crosshair, reload button, death overlay. |
| Client effects | `StarterPlayer/StarterPlayerScripts/Controllers/EffectsController.lua` | Tracer/flash/hit-spark/damage-number per pellet (shotgun fires up to 8 at once). Fire sound uses each weapon's own bundled "Fired" `Sound` from the Weapons Kit asset (falls back to a placeholder click if a weapon lacks one); reload sound (played from `WeaponViewController.lua`) similarly uses the asset's own "Reload" `Sound`. |
| Client camera/facing | `StarterPlayer/StarterPlayerScripts/Controllers/CameraController.lua` | Unchanged from Tier 0 — character-facing, over-the-shoulder camera, auto-aim lock-on. |

### Controls

- **Fire:** hold left mouse (desktop) or hold your finger down on the screen (mobile/touch)
- **Reload:** press `R` (desktop) or tap the **RELOAD** button
- **Switch weapon:** press `1`/`2`/`3` or click a slot in your Backpack hotbar (Roblox default — only shows weapons you've unlocked)
- **Toggle first-person / third-person:** press `V`
- **Buy / upgrade / interact:** walk up to a stall or the secret button and hold the interact key (`E` by default)

---

## Setup

1. Install [Rojo](https://rojo.space/) (VS Code extension + the `rojo` CLI) if you haven't already.
2. From this folder, run:
   ```bash
   rojo serve
   ```
3. In Roblox Studio, open the Rojo plugin and click **Connect**.
4. Press **Play** (Studio Play, not just Run).
5. You spawn in the **lobby**. A match auto-starts ~20s after the first player joins; you're teleported into the arena when wave 1 begins.

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
