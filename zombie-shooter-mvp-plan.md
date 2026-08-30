# Zombie Shooter — Reconciled MVP & Timeline

This resolves the mismatch between the "MVP Features" list and the "First Playable Version" list in the original plan, and adds testing gates, realistic time budgets, and a success metric so "done" is actually measurable.

---

## 1. Canonical MVP Checklist

Two tiers. Don't skip Tier 0 — it's the actual bet you're making on whether this game is fun at all.

### Tier 0 — "Is shooting zombies fun?" (build first, judge honestly)

- [ ] 1 player only (no multiplayer yet)
- [ ] 1 map — doesn't need to be polished, just playable
- [ ] 1 zombie type (Normal)
- [ ] 1 weapon (pick the one you think will feel best — probably AR or SMG)
- [ ] Shooting: raycast, damage, hit feedback, muzzle flash, basic recoil
- [ ] Zombie chase + attack AI (no state machine polish needed yet)
- [ ] Player HP, death, respawn
- [ ] No UI beyond HP bar and ammo counter
- [ ] No coins, no XP, no waves — just an endless single-zombie-type spawn

**Gate:** Don't proceed to Tier 1 until shooting a zombie feels satisfying to you and at least 2-3 other people. If it doesn't feel good here, no amount of waves/weapons/progression will fix it — fix the gun feel first.

### Tier 1 — MVP (the original section 27 scenario)

- [ ] 1 map (now polished: cover, corridors, shop area, 1 secret)
- [ ] 1–4 players (co-op, server-authoritative)
- [ ] 3 zombie types: Normal, Fast, Tank
- [ ] 3 weapons: Pistol, AR, Shotgun (cut Sniper/Rocket Launcher/SMG until post-MVP)
- [ ] 10 waves with difficulty scaling
- [ ] 1 boss (can be simple — 2 phases, not 4)
- [ ] Coins (earned + spent on basic weapon upgrades — levels 1-3 only, not full 10-level curve)
- [ ] Basic wave/HP/coin UI
- [ ] Basic anti-cheat (server validates fire rate, ammo, damage — see original section 22)
- [ ] DataStore persistence (coins + unlocked weapons only — no full player profile yet)
- [ ] Return-to-lobby loop

**Explicitly cut from Tier 1** (add in Phase 5/6 per original roadmap):
- XP/Levels — coins-only economy for now
- Roguelite random upgrades
- Perks
- Gems/premium currency
- Full weapon upgrade curve (levels 4-10)
- 2nd+ map

---

## 2. Timeline (Realistic Budget)

Original per-phase estimates assumed an experienced Roblox dev hitting first-try success. Budget below applies a 1.5–2x multiplier and inserts playtest gates. Adjust down if you're further along than "starting from zero."

| Phase | Original Estimate | Realistic Budget | Playtest Gate? |
|---|---|---|---|
| 0 — Tier 0 prototype (new) | — | 1–2 weeks, **time-boxed on feel, not features** | ✅ Yes — required before Phase 1 |
| 1 — Prototype → Tier 1 map/player/zombie | 1–2 weeks | 2–3 weeks | — |
| 2 — Wave System | ~1 week | 1.5–2 weeks | ✅ Yes |
| 3 — Multiplayer | 1–2 weeks | 2–4 weeks (networking bugs eat time) | — |
| 4 — Weapons (3 for MVP, not 6) | 1–2 weeks | 1–1.5 weeks | ✅ Yes — full MVP loop playable here |
| 5 — Progression (XP, full upgrades) | 1–2 weeks | 2–3 weeks | — |
| 6 — Content (2-3 maps, 8-15 zombies) | 2–4 weeks | 3–6 weeks | ✅ Yes |
| 7 — Monetization | 1–2 weeks | 1.5–2.5 weeks (+ Roblox review delays) | — |
| 8 — Polish | 2–3 weeks | 3–5 weeks | ✅ Final |

**Totals:**
- Original: ~9–16 weeks to full roadmap (excludes Tier 0)
- Realistic: ~17–29 weeks to full roadmap

**MVP-only milestone (Phases 0–4):** ~7.5–12.5 weeks realistic, vs. ~4.5–6.5 weeks original. This is the number to actually plan around — everything past Phase 4 depends on whether the MVP playtest gate passes.

---

## 3. Playtest Gates — What to Actually Check

| Gate | When | What to test | Pass condition |
|---|---|---|---|
| Gate 0 | After Tier 0 | Does shooting one zombie feel good, repeatedly? | You + 2-3 others voluntarily keep playing past 2 min without prompting |
| Gate 1 | After Phase 2 | Does wave progression create tension/pacing? | Testers can articulate "wave X was harder than wave Y" unprompted |
| Gate 2 | After Phase 4 (full MVP) | Full loop: lobby → 10 waves → boss → rewards → lobby | See success metric below |
| Gate 3 | After Phase 6 | Content variety — does map/zombie variety change strategy? | Testers report different approaches on different maps |
| Gate 4 | After Phase 8 | Full polish pass, mobile + desktop | No P0 bugs, session length metric holds on mobile too |

---

## 4. Success Metric (pick before you build, not after)

Define "MVP is good enough to keep building" with actual numbers. Suggested starting bar — adjust to taste:

- **Primary:** At least 3 of 5 external playtesters voluntarily start a second match without being asked.
- **Secondary:** Average first-session length exceeds 8 minutes (i.e., past wave 5-6, not just Tier 0 prototype).
- **Qualitative:** In post-test conversation, testers describe the *shooting* as fun before mentioning progression, waves, or anything else — this confirms the core loop (not just novelty) is carrying the game.

If Gate 2 fails against these numbers, the right move is iterating on Phases 0-4 (gun feel, wave pacing, zombie AI) — not pushing forward into content/monetization to "add more stuff." More content on a weak core loop doesn't fix the core loop.

---

## 5. Open Decisions to Lock Before Phase 1 Starts

These were flagged as gaps in the original plan — resolve them now so they don't cause rework later:

1. **Control scheme (mobile vs. desktop)** — decide in Phase 1, not Phase 8. Roblox skews majority-mobile; a tap-to-aim scheme designed after desktop controls usually forces a redesign.
2. **Pathfinding budget** — decide which zombie types get full `PathfindingService` (Tank/Elite/Boss) vs. cheap direct-chase (Normal/Fast), and cap concurrent pathfinding calls.
3. **Economy model** — before Phase 5, build a simple spreadsheet: coin income per wave vs. weapon/upgrade costs, so balancing isn't done blind post-launch.
4. **Premium currency + randomization** — if Gems ever touch randomized rewards (loot-box-style skins), Roblox requires odds disclosure. Simplify by keeping Gem purchases deterministic (buy a specific skin) unless you're ready to build that UI.
