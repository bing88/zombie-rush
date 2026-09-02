# UI Icon Design Brief

Nothing in-game uses images yet — HUD, draft cards, hotbar, shop, and perks are all text stand-ins.

**Ask: 29 square icons** (13 core + 4 HUD + 7 perks + 1 coin + 4 wave modifiers).

Perks also need a **512×512** Game Pass version (Roblox dashboard). Same art, just larger.

---

## Delivery


|        | Spec                                                                             |
| ------ | -------------------------------------------------------------------------------- |
| Format | PNG, transparent background                                                      |
| Size   | 256×256 (we scale down). Perks: also deliver 512×512 for the Game Pass.          |
| Style  | Simple silhouette / graphic, not a photo. High contrast so it still reads small. |
| Color  | One clear accent per icon is fine. Avoid tiny detail that dies at 16–60px.       |
| Naming | Use the **Id** below as the filename, e.g. `Gunslinger.png`, `Pistol.png`        |


In-game sizes to check against:


| Where                  | On-screen size                                                           |
| ---------------------- | ------------------------------------------------------------------------ |
| Hotbar / backpack slot | ~48px inside a 60×60 slot (number badge top-left, name along the bottom) |
| Upgrade draft card     | ~64px on a 190×210 card                                                  |
| Owned-upgrade list     | ~16–24px — only if the silhouette still reads                            |
| HUD action buttons     | 56×56 circle (`Reload` / `View` / `Ult`); `Fire` is 110×110              |
| Perk shop row          | ~40px in a 50px-tall row                                                 |
| Coin chip              | ~24px in a 140×32 bar                                                    |
| Wave modifier chip     | ~20px next to the wave label                                             |
| Roblox Game Pass       | 512×512 (perks only)                                                     |


---



## 1. Weapon hotbar / backpack — 3 icons

Bottom-center hotbar. One slot per owned gun, numbered 1–3. Unowned guns stay hidden. Equipped slot gets a gold ring.

Slots are **60×60**, corner radius 10. Keep a little padding so the icon does not collide with the `1`/`2`/`3` badge (top-left) or the weapon name (bottom).


| #   | Id             | Display       | Role                                             | Icon idea                        |
| --- | -------------- | ------------- | ------------------------------------------------ | -------------------------------- |
| 1   | `Pistol`       | Pistol        | Free starter. Semi-auto sidearm.                 | Handgun / pistol silhouette      |
| 2   | `AssaultRifle` | Assault Rifle | Shop unlock (150 coins). Fast full-auto rifle.   | Assault rifle / AR silhouette    |
| 3   | `Shotgun`      | Shotgun       | Shop unlock (300 coins). Close-range, 8 pellets. | Pump / combat shotgun silhouette |


These three can also sit on the shop upgrade list (50px-tall rows) later — same art, no extra variants needed.

---



## 2. Wave upgrade cards — 10 icons

Every wave break the player is offered **3 random cards** and picks **1**. Cards can stack (same card again = stronger), so each needs its **own** icon — not a generic “upgrade” glyph.

Draft card size: **190×210**. Icon sits above the name.

### Gun (5)


| Id            | Display name | Effect               | Icon idea                        |
| ------------- | ------------ | -------------------- | -------------------------------- |
| `Gunslinger`  | GUNSLINGER   | +15% fire rate       | Revolver / rapid trigger         |
| `HollowPoint` | HOLLOW POINT | +20% weapon damage   | Hollow-point bullet              |
| `Marksman`    | MARKSMAN     | +35% headshot damage | Crosshair / sniper scope         |
| `ExtendedMag` | EXTENDED MAG | +30% magazine size   | Extended magazine                |
| `SpeedLoader` | SPEED LOADER | Reload 25% faster    | Speed loader / spinning cylinder |




### Survivor (3)


| Id            | Display name | Effect             | Icon idea                |
| ------------- | ------------ | ------------------ | ------------------------ |
| `Survivor`    | SURVIVOR     | +25 max health     | Heart / armor vest       |
| `Adrenaline`  | ADRENALINE   | +12% move speed    | Syringe / running figure |
| `Bloodthirst` | BLOODTHIRST  | Heal 3 HP per kill | Blood drop / fangs       |




### Special (2)


| Id              | Display name  | Effect                       | Icon idea                   |
| --------------- | ------------- | ---------------------------- | --------------------------- |
| `Demolitionist` | DEMOLITIONIST | Kills explode nearby zombies | Explosion / grenade         |
| `Scavenger`     | SCAVENGER     | +25% coins from kills        | Coin pouch / scavenged loot |


A shared visual language per group (gun / survivor / special) is welcome, as long as each card is still instantly distinct from the other nine.

---



## 3. Combat HUD buttons — 4 icons

Right-side circular buttons. Text labels today (`RELOAD` / `VIEW` / `ULT` / `FIRE`). Glyphs should read at a glance on mobile.

`Reload` / `View` / `Ult` sit in **56×56** circles. `Fire` is a **110×110** circle (thumb reach, bottom-right). Leave a little inset so the glyph does not touch the circle edge.


| Id       | Display | What it does                                         | Icon idea                                  |
| -------- | ------- | ---------------------------------------------------- | ------------------------------------------ |
| `Reload` | Reload  | Reload the equipped gun                              | Mag / ammo in, or circular arrows on a mag |
| `View`   | View    | Toggle first / third person                          | Eye / camera                               |
| `Ult`    | Berserk | Spend the ultimate: +100% fire rate, +50% damage, 8s | Rage / bursting skull / glowing fists      |
| `Fire`   | Fire    | Hold to shoot (the only fire button)                 | Crosshair / muzzle flash                   |


Skip **Aim** — the button exists in code but is hidden (no ADS yet).

---



## 4. Robux perks — 7 icons

Permanent Game Pass perks. Shown in the Perks shop (`P` key) and, when we create the passes, as the Roblox Game Pass icon.

**Must not look identical to the matching wave card.** Same fantasy is fine; different composition so a paid perk is not mistaken for a run pick. Suggested split: cards = weapon/item close-up; perks = badge / emblem / character-scale.


| Id            | Display name  | Effect                             | Related card (keep distinct) | Icon idea                                      |
| ------------- | ------------- | ---------------------------------- | ---------------------------- | ---------------------------------------------- |
| `DamageBoost` | Damage Boost  | +25% weapon damage                 | `HollowPoint`                | Crossed bullets / damage emblem                |
| `ExtraHealth` | Extra Health  | +50% max health                    | `Survivor`                   | Shield with a heart, not a lone heart          |
| `SpeedBoost`  | Swift Feet    | +20% move speed                    | `Adrenaline`                 | Boots / sprint trails, not a syringe           |
| `CoinDoubler` | Coin Doubler  | 2× coins                           | `Scavenger`                  | Two stacked coins / “×2”, not a pouch          |
| `FastReload`  | Fast Hands    | Reload 35% faster                  | `SpeedLoader`                | Hands swapping a mag, not a speed loader       |
| `BigMag`      | Extended Mags | +50% mag on every gun              | `ExtendedMag`                | Twin mags / drum, not a single stick mag       |
| `QuickRevive` | Quick Revive  | Revive 2× faster, bleed out slower | —                            | Hands lifting / defibrillator / plus on a body |


Also deliver **512×512** of each for the Creator Dashboard Game Pass.

---



## 5. HUD chips — 5 icons



### Coin

Bottom-left `$0` bar (140×32). One coin glyph, reusable on Scavenger/Coin Doubler if needed — but those two still need their own icons above.


| Id     | Display | Icon idea                 |
| ------ | ------- | ------------------------- |
| `Coin` | Coins   | Single coin / dollar chip |




### Wave modifiers (4)

Chip under the top-center wave counter. Skip **Normal** (no modifier — text-only is fine).


| Id           | Display    | Effect                  | Icon idea                      |
| ------------ | ---------- | ----------------------- | ------------------------------ |
| `Swarm`      | Swarm      | Faster zombies, less HP | Horde / many small silhouettes |
| `Juggernaut` | Juggernaut | Slower, much more HP    | Heavy / armored brute          |
| `Payday`     | Payday     | Double coins this wave  | Money bag / raining coins      |
| `Bloodbath`  | Bloodbath  | Zombies hit much harder | Bloody claw / dripping fang    |


---



## Skip (not this ask)

- Combo tiers (HOT / BLAZING / UNSTOPPABLE / GODLIKE) — color + text is the identity
- Elite affixes / zombie types — already a 3D model + tint + nameplate
- Shop / Perks / Leaderboard tab buttons — labels work
- Aim button — hidden until ADS exists

---



## Checklist

**Weapons (3)**

- [ ] `Pistol`
- [ ] `AssaultRifle`
- [ ] `Shotgun`

**Wave cards (10)**

- [ ] `Gunslinger`
- [ ] `HollowPoint`
- [ ] `Marksman`
- [ ] `ExtendedMag`
- [ ] `SpeedLoader`
- [ ] `Survivor`
- [ ] `Adrenaline`
- [ ] `Bloodthirst`
- [ ] `Demolitionist`
- [ ] `Scavenger`

**HUD buttons (4)**

- [ ] `Reload`
- [ ] `View`
- [ ] `Ult`
- [ ] `Fire`

**Perks (7)** — 256×256 + 512×512 each

- [ ] `DamageBoost`
- [ ] `ExtraHealth`
- [ ] `SpeedBoost`
- [ ] `CoinDoubler`
- [ ] `FastReload`
- [ ] `BigMag`
- [ ] `QuickRevive`

**HUD chips (5)**

- [ ] `Coin`
- [ ] `Swarm`
- [ ] `Juggernaut`
- [ ] `Payday`
- [ ] `Bloodbath`

Source of truth in code: `WeaponConfig.lua` (guns), `RunUpgradeConfig.lua` (cards), `PerkConfig.lua` (perks), `WaveModifiers.lua` (modifiers), `UltimateConfig.lua` (Berserk), `UIController.lua` (HUD buttons + coin).