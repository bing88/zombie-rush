# Zombie Design Brief (Meshy)

10 enemy types. Generate **one humanoid mesh per type** in Meshy. Elites are a tint + nameplate on the same mesh — do **not** generate 5 extra elite models.

Setting: grimy **subway outbreak** (the arena is an L4D-style station). Torn commuter / worker clothes, not medieval, not sci-fi armor.

Today: mix of toolbox models (Normal / Fast / Tank / Boss) and **placeholder block rigs** (Ranged / Exploder / Spitter / Bomber). Fast and Runner currently share a skeleton-dog mesh — replace those with bipeds.

---

## Meshy settings (every type)

Paste this as the **shared tail** of every prompt:

```
full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

| Setting | Value |
|---|---|
| Mode | Text to 3D (Image to 3D if you paint a turnaround first) |
| Pose | **T-pose** (required for Roblox Avatar Setup / Humanoid) |
| Style | Stylized realistic. Same look across all 10. |
| Poly | Fodder 5k–10k tris. Boss up to ~15k. Bake detail into texture, not geo. |
| Scale | Generate at **normal human height**. We scale in-game (see Scale below). |
| Export | GLB, textured. Remesh in Meshy before export. |

**Must-haves (gameplay):**

- **Biped humanoid.** The game uses `Humanoid` + pathfinding. No quadrupeds, no floating torsos.
- **A distinct Head.** Headshots are a real mechanic. If the head blends into the shoulders, precision play dies.
- **No held weapons.** Walk/attack anims are generic Humanoid. Claws / swollen arms / fused growths are fine; a separate axe/gun will clip and not animate.
- **Readable silhouette at 30+ studs.** Players pick targets in a horde. Height, bulk, and one signature shape per type.
- **One character, not a scene.** Meshy will glue props to the floor if you mention subway tiles.

**Do not generate:** elite variants, combo/HUD icons, dead poses, attack poses.

---

## Shared look

One outbreak family. A player should glance at the horde and still name the type.

- Skin: rotting, blotched, not plastic-smooth.
- Clothes: subway commuters, janitors, security, maintenance — ripped, blood/dirt, not armor sets (except Tank / Brute / Boss bulk).
- Accent color per type (table below) should dominate the **texture**, not just a later tint.
- Same face language (sunken eyes, slack jaw) so they feel like one species with mutations.

---

## Roster — 10 types

Generate in this order. Placeholders first; they currently look like colored blocks.

Scale is applied in-game on a ~R6-sized body. `1.0` ≈ player height.

### Priority A — no real mesh yet

#### 1. `Ranged`

Stops at ~28 studs and lobs a projectile. Fragile. Must read as “stays back” — not another walker.

| | |
|---|---|
| Scale | 0.95 |
| Color | `#78B45A` sick green |
| Fantasy | Gaunt subway commuter, one swollen throwing arm, hunched, jaw unhinged. Looks like it *spits/throws*, not a gunner. |

```
Gaunt humanoid zombie, skinny subway commuter, one oversized swollen right arm for throwing, hunched shoulders, sagging jaw, sick green rotting skin RGB 120 180 90, torn office shirt, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

#### 2. `Exploder`

Runs in and detonates. Low HP, must be shot *now*. Signature: bloated orange body.

| | |
|---|---|
| Scale | 1.1 |
| Color | `#C8781E` orange |
| Fantasy | Swollen, taut belly, veins, about to burst. Rounder silhouette than walkers. |

```
Bloated bursting humanoid zombie, taut swollen belly, visible veins, orange rotting skin RGB 200 120 30, round heavy silhouette, cracked skin ready to explode, torn stretched clothes, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

#### 3. `Spitter`

Longer-range, harder-hitting cousin of Ranged (45 studs). Acid / bile, not a copy of Ranged.

| | |
|---|---|
| Scale | 1.0 |
| Color | `#96DC50` acid lime |
| Fantasy | Distended throat / dripping maw, bile-green, thinner than Exploder. Reads as “spits from far,” not “throws.” |

```
Humanoid spitter zombie, distended throat, dripping acid maw, bile lime green rotting skin RGB 150 220 80, thin body, hunched, wet glistening sores on chest and mouth, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

#### 4. `Bomber`

Bigger, tankier Exploder. Cannot be deleted on sight. Orange, but **heavier and taller** than Exploder.

| | |
|---|---|
| Scale | 1.5 |
| Color | `#E68C28` bright orange |
| Fantasy | Barrel-chested walking bomb, fused canisters / swollen sacs on the torso (fused to the mesh, not separate props). |

```
Large barrel-chested bomber zombie, fused swollen explosive sacs on torso, bright orange rotting skin RGB 230 140 40, heavy set, slow looking, cracked glowing seams on belly, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

---

### Priority B — replace toolbox / wrong silhouette

#### 5. `Normal`

Fodder. Most common. Must be the **family baseline** the others mutate from.

| | |
|---|---|
| Scale | 1.0 |
| Color | `#5A7846` olive rot |
| Fantasy | Average subway zombie. Slow shuffle energy. Torn jacket, slack face. The “default undead.” |

```
Average male humanoid zombie, olive rotting skin RGB 90 120 70, torn commuter jacket, slack jaw, sunken eyes, medium build, walking-dead subway passenger, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

#### 6. `Fast`

Smaller, jaundiced, closes quickly. Currently a dog mesh — must be a **thin biped**.

| | |
|---|---|
| Scale | 0.85 |
| Color | `#CDBE3C` jaundiced yellow |
| Fantasy | Wiry, long limbs, yellow-grey skin, rags. Looks fast even standing still. |

```
Wiry thin humanoid zombie, long limbs, jaundiced yellow skin RGB 205 190 60, small frame, ragged clothes, alert feral face, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

#### 7. `Runner`

Glass cannon, faster than the player, dies instantly. Smaller and redder than Fast. Must not look like Fast at a glance.

| | |
|---|---|
| Scale | 0.8 |
| Color | `#C85A5A` bloody red |
| Fantasy | Emaciated sprinter, bloody smears, almost no clothes, hunched to sprint. Tiny compared to Tank. |

```
Emaciated sprinting humanoid zombie, very skinny, bloody red rotting skin RGB 200 90 90, small crouched ready-to-run look, almost no clothes, feral, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

#### 8. `Tank`

Slow sponge. Wide, tall, bruise-purple. Silhouette: **rectangle**.

| | |
|---|---|
| Scale | 1.6 |
| Color | `#50465A` bruise purple |
| Fantasy | Massive undead, thick torso, small head (still a clear headshot target), torn security / high-vis vest. |

```
Massive bulky tank zombie, thick torso, wide shoulders, bruise purple rotting skin RGB 80 70 90, small but distinct head, torn security vest, slow heavy look, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

#### 9. `Brute`

Between Tank and Boss. Mid-wave spike. Darker, meaner, not a recolor of Tank.

| | |
|---|---|
| Scale | 1.7 |
| Color | `#5A3C3C` dark meat |
| Fantasy | Butcher-like, meaty arms, darker red-brown, hunched ape stance but still T-pose biped. |

```
Hulking brute zombie, meaty oversized arms, dark reddish brown rotting skin RGB 90 60 60, ape-like hunched bulk, torn butcher apron fused to body, distinct head, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

#### 10. `Boss`

Every 10th wave. 2.5× scale. At 50% HP the body tints **bright red** in code — design the base as dark blood-red so that recolor still reads.

| | |
|---|---|
| Scale | 2.5 |
| Color | `#8C1414` blood red (enrage: `#FF3232`) |
| Fantasy | Hero enemy. Crown of the horde: huge, crowned in viscera / broken subway signage fused to the back (fused, not a prop). Clear head. Intimidating even in T-pose. |

```
Giant boss zombie, towering, blood red rotting skin RGB 140 20 20, huge distinct head, fused broken metal and viscera on shoulders, torn heavy clothes, monstrous but still humanoid biped, full body humanoid zombie character, T-pose, standing, two arms two legs, distinct separate head, game-ready, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, torn dirty clothes, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no scene, no background, no base
```

---

## Silhouette cheat sheet

If two types could be confused at 40 studs, regenerate.

| Type | Height vs player | Shape | Accent |
|---|---|---|---|
| Runner | much shorter | stick | red |
| Fast | shorter | thin | yellow |
| Normal | same | average | olive |
| Ranged | same | hunched, one fat arm | green |
| Spitter | same | long neck / maw | lime |
| Exploder | slightly taller | round belly | orange |
| Bomber | taller | barrel + sacs | bright orange |
| Tank | much taller | wide box | purple |
| Brute | taller than Tank | ape arms | dark meat |
| Boss | huge | king of the pile | blood red |

---

## Elites — no extra meshes

Rolled per spawn from wave 6. Same model, **lerped toward this color** + a nameplate. Texture should still look like the base type after a 65% tint.

| Affix | Tint | How it’s fought |
|---|---|---|
| Armored | `#788CB0` steel blue | Headshots / bigger gun |
| Frenzied | `#FF7828` orange | Kill first — it closes fast (never on Fast/Runner) |
| Regenerating | `#50D278` green | Finish the kill or it heals |
| Volatile | `#FFC83C` yellow | Don’t stand next to it when it dies (never on Exploder/Bomber) |
| Vampiric | `#BE285A` crimson | Don’t leave it on a teammate |

---

## After Meshy (for whoever imports)

1. Remesh → GLB.
2. Roblox Studio **Avatar Setup** (R15) or a standard R6 dummy — game supports both, but **Head** must exist as a named part.
3. Strip any Animate/AI scripts except if we explicitly keep `Animate`.
4. In-game `ZombieConfig.Scale` does the size. Don’t pre-scale the mesh to 2.5× for Boss.
5. Filename = type Id: `Normal.glb`, `Fast.glb`, …

Source of truth: `ZombieConfig.lua` (stats/colors/scale), `EliteConfig.lua` (tints), `ZombieService.lua` (spawn + current toolbox IDs).
