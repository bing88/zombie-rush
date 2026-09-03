# Zombie Design Brief (Meshy → R6 Simple)

Generate **one** simple humanoid zombie mesh in Meshy. That single mesh is the shared R6 base for all 10 types.

Types are told apart by **Color** + **Scale** only — do **not** generate 10 Meshy variants, elite meshes, or unique silhouettes.

Old toolbox asset IDs (Normal / Fast / Runner / Tank / Brute / Boss) are **retired**. Replace them with this one Meshy → R6 import.

Setting: grimy **subway outbreak**. Torn commuter / worker clothes, not medieval, not sci-fi armor. Keep the mesh **simple** — readable blocky proportions that map cleanly to R6 parts.

---

## Design rules

| Rule | Detail |
|---|---|
| Count | **One** Meshy character. Clone + recolor + rescale in-game. |
| Rig target | Classic **R6** (Head, Torso, Left/Right Arm, Left/Right Leg + HumanoidRootPart). |
| Distinguish | `ZombieConfig.Color` + `ZombieConfig.Scale` only. |
| Head | Clear, separate head (headshots). |
| Weapons / props | None. No held items, no extra limbs, no fused bombs/sacs. |
| Scale | Generate at **normal human height**. In-game `Scale` sizes Boss etc. Do not pre-scale. |

Behavior (melee / ranged / explode) is code-only. No need for a throwing arm or bloated belly on the mesh.

---

## Meshy settings (the one base mesh)

| Setting | Value |
|---|---|
| Mode | Text to 3D (Image to 3D if you paint a turnaround first) |
| Pose | **T-pose** (required for Roblox Avatar Setup / Humanoid) |
| Style | Stylized realistic, **simple** — not cartoon, not photoreal, not high-detail costume |
| Poly | ~5k–10k tris. Bake detail into texture, not geo. |
| Scale | Normal human height |
| Export | GLB, textured. Remesh in Meshy before export. |

**Must-haves:**

- **Biped humanoid** with R6-friendly proportions (blocky torso, distinct limbs, separate head).
- **Neutral body color** in the texture (grey-green / olive rot) so in-game tint still reads for every type.
- **No held weapons**, no floating parts, no extra limbs, no scene / background / base.
- **One character**, not a subway station prop glue-on.

**Do not generate:** per-type variants, elites, combo icons, dead poses, attack poses.

### Prompt (paste as-is)

```
Simple blocky humanoid zombie, R6-style proportions, average male build, T-pose, standing, distinct separate head, two arms two legs, olive rotting skin RGB 90 120 70, torn dirty subway commuter clothes, slack jaw, sunken eyes, stylized realistic not cartoon not photoreal, dirty subway outbreak, rotting flesh, game-ready, watertight solid mesh, no floating parts, no extra limbs, no held weapons, no armor, no mutations, no swollen limbs, no scene, no background, no base
```

Shared look notes:

- Skin: rotting, blotched — but keep the albedo **tintable** (avoid baking strong unique hues).
- Clothes: simple torn jacket / shirt — detail is fine if it still recolors cleanly.
- Face: one slack undead face for the whole roster.

---

## Roster — 10 types (color + scale)

Same mesh. `1.0` ≈ player height after R6 setup.

| Type | Scale | Color | Hex | Role (code) |
|---|---|---|---|---|
| Runner | 0.8 | RGB 200 90 90 | `#C85A5A` | Glass cannon melee |
| Fast | 0.85 | RGB 205 190 60 | `#CDBE3C` | Quick melee |
| Ranged | 0.95 | RGB 120 180 90 | `#78B45A` | Stops ~28 studs, projectile |
| Normal | 1.0 | RGB 90 120 70 | `#5A7846` | Fodder baseline |
| Spitter | 1.0 | RGB 150 220 80 | `#96DC50` | Long-range acid (~45 studs) |
| Exploder | 1.1 | RGB 200 120 30 | `#C8781E` | Fragile detonate |
| Bomber | 1.5 | RGB 230 140 40 | `#E68C28` | Tankier detonate |
| Tank | 1.6 | RGB 80 70 90 | `#50465A` | Slow sponge |
| Brute | 1.7 | RGB 90 60 60 | `#5A3C3C` | Mid-wave melee spike |
| Boss | 2.5 | RGB 140 20 20 | `#8C1414` | Every 10th wave; enrage tint `#FF3232` |

### Readability at distance

At 40+ studs, rely on **size bands** + **hue**:

| Band | Types |
|---|---|
| Tiny | Runner, Fast |
| Player-sized | Ranged, Normal, Spitter |
| Medium-tall | Exploder |
| Tall / bulky | Bomber, Tank, Brute |
| Huge | Boss |

Same-scale pairs (Normal vs Spitter) use different greens. Exploder vs Bomber: scale first, then brighter orange on Bomber.

---

## Elites — no extra meshes

Rolled per spawn from wave 6. Same model, **lerped toward this color** + a nameplate. Base texture must still read after a ~65% tint.

| Affix | Tint | How it’s fought |
|---|---|---|
| Armored | `#788CB0` steel blue | Headshots / bigger gun |
| Frenzied | `#FF7828` orange | Kill first — it closes fast (never on Fast/Runner) |
| Regenerating | `#50D278` green | Finish the kill or it heals |
| Volatile | `#FFC83C` yellow | Don’t stand next to it when it dies (never on Exploder/Bomber) |
| Vampiric | `#BE285A` crimson | Don’t leave it on a teammate |

---

## After Meshy (import once)

1. Remesh → export **GLB**.
2. Roblox Studio **Avatar Setup** → target **R6** (or map parts onto a standard R6 dummy). Named `Head` is required.
3. Strip Animate/AI scripts unless we explicitly keep `Animate`.
4. Save as one template (e.g. `ZombieBase`). Filename for the source file: `ZombieBase.glb`.
5. In-game: clone template → apply `ZombieConfig.Scale` + `ZombieConfig.Color`. Never bake type size/color into separate Meshy exports.
6. Do **not** use old toolbox asset IDs in `ZombieService`.

Source of truth: `ZombieConfig.lua` (stats / colors / scale), `EliteConfig.lua` (tints), `ZombieService.lua` (spawn).
