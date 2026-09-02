# Roblox Unlimited-Wave Zombie Shooter — Gameplay Improvement Recommendations

## 1. Vision

The goal is to make the game more than:

> Shoot → reload → clear wave → repeat

The core experience should become:

```text
KILL ZOMBIES
     ↓
EARN REWARDS
     ↓
UPGRADE / CHOOSE BUILD
     ↓
SURVIVE HARDER WAVES
     ↓
NEW THREAT / NEW REWARD
     ↓
KILL ZOMBIES
```

The main design pillars are:

- 🎯 Shooting skill
- 🔫 Weapon variety and builds
- 🧟 Different zombie behaviors
- 🎲 Random events and wave modifiers
- 🏆 Long-term progression

---

# 2. Do Not Scale Difficulty Only With Zombie HP

Avoid a system like:

```text
Wave 1    HP 100
Wave 10   HP 1,000
Wave 50   HP 5,000
Wave 100  HP 50,000
```

This eventually feels like bullet sponges.

Instead, combine:

```text
More HP
+
More enemies
+
More enemy types
+
Different enemy combinations
+
Environmental danger
+
Boss mechanics
+
Special wave modifiers
```

## Example progression

| Wave | New Gameplay |
|---:|---|
| 1–5 | Basic zombies |
| 6 | Fast zombie |
| 10 | Tank zombie |
| 15 | Ranged zombie |
| 20 | Exploder |
| 25 | Elite zombie |
| 30 | Mini boss |
| 40 | Special event |
| 50 | Major boss |
| 60+ | Mutations and procedural combinations |

---

# 3. Add a Preparation Phase Between Waves

Do not immediately start the next wave.

Give players approximately 10–20 seconds to prepare.

```text
WAVE COMPLETE
      ↓
   15 seconds
      ↓
Choose Upgrade
      ↓
Buy / Upgrade Weapon
      ↓
Repair Barricade
      ↓
Prepare
      ↓
NEXT WAVE
```

This creates a strong gameplay rhythm:

**Action → Reward → Decision → Action**

---

# 4. Add Random 3-Choice Upgrades

After selected waves, offer three random upgrades.

Example:

```text
┌────────────────┐
│ 🔫 GUNSLINGER  │
│ +15% Fire Rate │
└────────────────┘

┌────────────────┐
│ 💥 EXPLOSIVE   │
│ Bullets explode│
│ on kill        │
└────────────────┘

┌────────────────┐
│ ❤️ SURVIVOR    │
│ +25 Max HP     │
└────────────────┘
```

The player should not always receive the same upgrades.

This creates different builds every run.

---

# 5. Build System

Allow players to specialize.

## Crit Build

```text
Critical Chance
      ↓
Critical Damage
      ↓
Headshot Damage
      ↓
Weak Point Bonus
```

## Fire Build

```text
Burn Damage
      ↓
Burn Duration
      ↓
Burn Spread
      ↓
Explosion on Death
```

## Speed Build

```text
Movement Speed
      ↓
Reload Speed
      ↓
Fire Rate
      ↓
Dodge
```

## Explosive Build

```text
Explosion Radius
      ↓
Explosion Damage
      ↓
Chain Explosion
      ↓
Cluster Explosion
```

The objective is for two players to be able to reach high waves using different strategies.

---

# 6. Weapon Variety

Avoid weapons that are simply stronger versions of each other.

Each weapon should have a gameplay identity.

| Weapon | Gameplay Identity |
|---|---|
| SMG | Very fast fire, weak individual shots |
| Assault Rifle | Balanced |
| Shotgun | Massive close-range burst |
| Sniper | High weak-point damage |
| Minigun | Huge DPS, overheating |
| Flamethrower | Area control |
| Rocket Launcher | Large AoE |
| Railgun | Piercing shots |
| Plasma Gun | Chain damage |
| Freeze Gun | Crowd control |

The next weapon should not simply be:

```text
Weapon B = Weapon A + 50% damage
```

---

# 7. Add Weapon Trade-Offs

## Shotgun

```text
+ Massive close-range damage
+ Excellent against swarms

- Slow reload
- Poor long-range performance
```

## Minigun

```text
+ Extremely high DPS

- Slow movement
- Overheating
- Long reload
```

## Sniper

```text
+ Massive weak-point damage

- Slow fire rate
- Poor against crowds
```

This makes weapon selection a meaningful decision.

---

# 8. Zombie Variety

Players should immediately understand what each enemy does.

## Normal Zombie

- Slow
- Low HP
- Large numbers

## Runner

- Very fast
- Low HP
- Targets isolated players

## Tank

- Slow
- Very high HP
- Blocks paths

## Screamer

- Stays behind other zombies
- Buffs nearby zombies

## Exploder

- Runs toward players
- Explodes on death

## Jumper

- Can jump over barricades

## Shield Zombie

- Reduced frontal damage
- Must be attacked from the side/back

## Necromancer

- Revives dead zombies

---

# 9. Target Priority

Good zombie design should make players ask:

> Which zombie should I kill first?

Example:

```text
Tank
 ↓
Normal Zombies
 ↓
Screamer
 ↓
Runner
```

But if the Screamer buffs all nearby zombies:

```text
Screamer
    ↓
Buffs zombies
    ↓
Player must kill Screamer first
```

This creates decision-making instead of mindless shooting.

---

# 10. Special Wave Modifiers

Every few waves, randomly select a modifier.

## Blood Moon

```text
Zombie Speed +30%
Zombie HP +20%
Reward +50%
```

## Swarm

```text
3× Zombie Count
50% Zombie HP
```

## Darkness

```text
Reduced visibility
Flashlight becomes important
```

## Fast Zombies

```text
All zombies +50% speed
```

## Double XP

```text
XP ×2
```

## Explosive Night

```text
Higher Exploder spawn rate
```

Example:

```text
Wave 31
Normal

Wave 32
Normal

Wave 33
🔥 BLOOD MOON

Wave 34
Normal

Wave 35
💀 BOSS
```

---

# 11. Mini-Objectives During Waves

Do not make the only objective:

> Kill everything.

Add secondary objectives.

Example:

```text
WAVE 27

☐ Kill 100 zombies
☐ Protect generator
☐ Kill 3 elites
☐ Keep barricade alive
```

## Generator Defense

```text
ZOMBIES
↓↓↓↓↓↓↓↓

████████████
  GENERATOR
████████████

Survive for 60 seconds
```

This changes how players move and position themselves.

---

# 12. Map Interaction

Make the map part of the gameplay.

Possible interactable objects:

```text
Barricade
    ↓
Repair

Turret
    ↓
Activate

Generator
    ↓
Restore power

Door
    ↓
Unlock

Ammo Box
    ↓
Refill
```

The environment should be something players actively use, not just decoration.

---

# 13. Destructible Barricades

Barricades create defensive decision-making.

```text
        ZOMBIES
     ↓ ↓ ↓ ↓ ↓ ↓

====================
      BARRICADE
====================

       PLAYER
```

Example:

```text
Barricade HP: 5000

5000
 ↓
3500
 ↓
2000
 ↓
500
 ↓
BROKEN
```

Players then need to decide:

> Repair the barricade or keep fighting?

---

# 14. Last Stand Mechanic

When the player reaches low HP, temporarily give them a powerful survival state.

Example:

```text
HP < 20%

LAST STAND

+20% Damage
+20% Fire Rate
+10% Move Speed

Duration: 8 seconds
```

This creates clutch moments and makes near-death situations exciting.

---

# 15. Boss Design

Never make bosses simply:

```text
Boss HP = 500,000
```

and require players to hold the fire button for several minutes.

Bosses should have mechanics.

## Example: Zombie King

### Phase 1

Normal attacks

### Phase 2

Summons zombies

### Phase 3

Ground slam

### Phase 4

Weak point appears

### Phase 5

Enraged

The player should react to boss behavior rather than only maximize DPS.

---

# 16. Elite Zombies

Add elite variants between major bosses.

Example:

```text
Normal Runner
      ↓
Elite Runner
      ↓
🔥 Burning Runner
      ↓
💀 Mutated Runner
```

Elite modifiers:

- Fast
- Regenerating
- Explosive
- Armored
- Shielded
- Invisible
- Splitting
- Vampiric

You can combine modifiers:

```text
🔥 Elite Tank
+
Regeneration
+
Explosion on Death
```

This makes high waves unpredictable.

---

# 17. Risk / Reward System

Give players choices between safer and harder waves.

Example:

## Safe

```text
Normal enemies

Reward:
1,000 Coins
```

## Risky

```text
Zombie HP +50%
Zombie Speed +30%

Reward:
3,000 Coins
+ Rare Upgrade
```

The player decides:

> Do I play safely or gamble for a bigger reward?

---

# 18. Powerups

Temporary powerups are ideal for zombie shooters.

Examples:

```text
⚡ Double Damage
🔥 Infinite Ammo
💀 Instant Kill
❤️ Full Heal
❄ Freeze
💥 Explosive Bullets
```

Powerups should create short periods where the player feels extremely powerful.

Example:

```text
Normal
100 DPS
   ↓
Double Damage
200 DPS
   ↓
Infinite Ammo
   ↓
Massive Horde
```

---

# 19. Kill Streak / Combo System

Reward aggressive play.

Example:

```text
10 Kills
20 Kills
30 Kills
50 Kills
100 Kills
```

Possible rewards:

```text
10 Kill
+10% Fire Rate

25 Kill
+10% Damage

50 Kill
Powerup

100 Kill
Ultimate Charge
```

The combo resets when the player stops killing for a certain period.

---

# 20. Ultimate Ability

Give each player a powerful ability that charges during combat.

Examples:

## Bombardment

Calls an air strike.

## Berserk

```text
+100% Fire Rate
+50% Damage
```

## Freeze

Freezes nearby zombies.

## Turret

Deploys an automatic turret.

## Black Hole

Pulls zombies into one location.

This creates another decision:

> Use the Ultimate now, or save it for the boss?

---

# 21. Persistent Progression

When a run ends, the player should keep some progress.

```text
RUN
 ↓
Wave 37
 ↓
Death
 ↓
Rewards
 ↓
Permanent Upgrade
 ↓
New Run
```

Possible permanent upgrades:

- Damage
- HP
- Movement Speed
- Reload Speed
- Crit Chance
- Starting Ammo
- Starting Weapon
- Starting Ability

Keep permanent bonuses relatively controlled so early waves do not become completely meaningless.

---

# 22. Prestige System

Once players reach a high milestone:

```text
Wave 100
    ↓
PRESTIGE
```

Reset run-specific progression and grant permanent Prestige currency.

Example:

```text
+2% Damage
+2% XP
+1% Crit
+1% Luck
```

This gives experienced players a reason to keep replaying.

---

# 23. Make Wave Milestones Meaningful

Avoid:

```text
Wave 1
Wave 2
Wave 3
...
Wave 1000
```

Instead:

| Wave | Milestone |
|---:|---|
| 10 | Mini Boss |
| 20 | New Zombie |
| 30 | Boss |
| 40 | New Map Event |
| 50 | Major Boss |
| 75 | Elite Event |
| 100 | Mega Boss |

Wave 100 should feel significantly different from Wave 20.

---

# 24. Horde Director

For an advanced system, create a dynamic Horde Director instead of blindly spawning a fixed number of zombies.

```text
                 HORDE DIRECTOR
                       │
        ┌──────────────┼──────────────┐
        │              │              │
   Zombie Count    Enemy Types      Events
        │              │              │
        ▼              ▼              ▼
       100            Tank        Blood Moon
       150            Runner      Exploder
       200            Elite       Boss
```

Monitor:

```text
Player DPS
Player HP
Current Wave
Zombie Count
Time to Clear Wave
Player Deaths
```

Then dynamically adjust the next wave.

Example:

```text
Player killing too easily
        ↓
Increase special enemies

Player struggling
        ↓
Reduce elite spawn rate

Player performing extremely well
        ↓
Trigger bonus event
```

The goal is not to secretly cheat the player. The goal is to keep the experience within an enjoyable difficulty range.

---

# 25. Recommended First 50 Waves

| Wave | Gameplay |
|---:|---|
| 1 | Basic zombies |
| 2 | Basic |
| 3 | Basic + more |
| 4 | Runner introduced |
| 5 | Mini Horde |
| 6 | Basic + Runner |
| 7 | Fast wave |
| 8 | Tank introduced |
| 9 | Mixed enemies |
| 10 | **Mini Boss** |
| 11 | Basic |
| 12 | Exploder introduced |
| 13 | Exploder + Runner |
| 14 | Horde |
| 15 | **Blood Moon** |
| 16 | Basic |
| 17 | Screamer introduced |
| 18 | Mixed |
| 19 | Elite |
| 20 | **Boss** |
| 21–24 | Increasing combinations |
| 25 | Special Event |
| 26–29 | Elite combinations |
| 30 | **Boss** |
| 31–34 | Mutation system |
| 35 | **Horde Event** |
| 36–39 | Hard combinations |
| 40 | **Boss** |
| 41–44 | Elite mutations |
| 45 | Special Event |
| 46–49 | Extreme |
| 50 | **Major Boss** |

After Wave 50:

```text
Wave 51+
    ↓
Procedural Wave Generation
    +
Random Modifiers
    +
Enemy Combinations
    +
Boss Intervals
```

---

# 26. Core Gameplay Loop

The recommended loop:

```text
                    ┌───────────────┐
                    │     WAVE      │
                    └───────┬───────┘
                            │
                            ▼
                     Kill Zombies
                            │
                            ▼
                       Get XP/Cash
                            │
                            ▼
                    Wave Completed
                            │
                            ▼
                 ┌─────────────────────┐
                 │ Choose Your Reward  │
                 └──────────┬──────────┘
                            │
             ┌──────────────┼──────────────┐
             ▼              ▼              ▼
           Weapon         Upgrade       Ability
             │              │              │
             └──────────────┼──────────────┘
                            ▼
                       Next Wave
                            │
                            ▼
                   Random Event?
                      /                             YES          NO
                     │            │
                     ▼            ▼
                  Special      Normal
                   Wave          Wave
                     │            │
                     └─────┬──────┘
                           ▼
                     Mini Boss?
                           │
                           ▼
                        Repeat
```

---

# 27. Shooting Feel

The gunplay needs to feel good before adding dozens of progression systems.

Prioritize:

```text
✓ Stable weapon holding
✓ Both-hand IK
✓ Recoil
✓ Hit effects
✓ Damage numbers
✓ Headshots
✓ Zombie hit reactions
✓ Death animations
✓ Shooting sounds
✓ Impact effects
```

Every kill should provide feedback:

```text
Hit
 ↓
Damage Number
 ↓
Zombie Reaction
 ↓
Particles / Impact
 ↓
Sound
 ↓
Death Animation
 ↓
XP
 ↓
Coins
```

For headshots:

```text
HEADSHOT
+250
```

Use different feedback for critical hits.

---

# 28. Development Priority

Do not build everything at once.

## Phase 1 — Shooting Feel

```text
✓ Weapon animations
✓ Stable hands
✓ Recoil
✓ Hit effects
✓ Damage numbers
✓ Headshots
✓ Zombie reactions
✓ Shooting sounds
```

## Phase 2 — Wave Variety

```text
✓ 5–8 zombie types
✓ Elite zombies
✓ Mini bosses
✓ Bosses
✓ Special waves
```

## Phase 3 — Progression

```text
✓ XP
✓ Coins
✓ Weapon upgrades
✓ Player upgrades
✓ Random 3-choice upgrades
```

## Phase 4 — Replayability

```text
✓ Random modifiers
✓ Build system
✓ Powerups
✓ Kill streak
✓ Ultimate ability
```

## Phase 5 — Long-Term Roblox Progression

```text
✓ Missions
✓ Daily rewards
✓ Achievements
✓ Prestige
✓ Skins
✓ Leaderboards
✓ Statistics
```

---

# 29. Most Important Design Principle

Do not ask:

> How can I make Wave 100 harder?

Ask:

> **How can I make Wave 100 different from Wave 20?**

The game should constantly introduce new decisions:

```text
Which zombie do I kill first?
        ↓
Which weapon should I use?
        ↓
Which upgrade should I choose?
        ↓
Should I take the risky wave?
        ↓
Should I use my Ultimate now?
        ↓
Should I repair the barricade?
        ↓
Should I save resources for the boss?
```

That is what turns an endless shooter into a game players can keep playing.

---

# 30. Recommended Final Game Structure

```text
                    ZOMBIE SHOOTER
                          │
         ┌────────────────┼────────────────┐
         │                │                │
         ▼                ▼                ▼
      GUNPLAY           WAVES          PROGRESSION
         │                │                │
    ┌────┼────┐      ┌────┼────┐      ┌────┼────┐
    │    │    │      │    │    │      │    │    │
  Aim  Shoot Recoil Zombies Bosses   XP  Builds Prestige
    │    │    │      │    │    │      │    │    │
    └────┼────┘      └────┼────┘      └────┼────┘
         │                │                │
         └────────────────┼────────────────┘
                          ▼
                  REPLAYABILITY
                          │
             ┌────────────┼────────────┐
             │            │            │
         Random Builds  Events     Challenges
             │            │            │
             └────────────┼────────────┘
                          ▼
                    PLAY AGAIN
```

## Priority Recommendation

If development resources are limited, implement these **10 features first**:

1. **Stable two-hand weapon animation + IK**
2. **5–8 meaningfully different zombie types**
3. **Mini bosses + major bosses**
4. **Random 3-choice upgrades**
5. **Weapon-specific builds**
6. **Special wave modifiers**
7. **Powerups**
8. **Kill streak / Ultimate**
9. **Destructible barricades / map objectives**
10. **Persistent progression + prestige**

These features will provide substantially more replayability than simply adding hundreds of waves.
