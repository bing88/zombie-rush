--[[
	Remotes/init.lua
	Central place to create and fetch RemoteEvents so client and server
	never hardcode WaitForChild paths all over the codebase.

	Tier 1 adds coins/shop/wave/game-state/boss events on top of Tier 0's
	weapon + HP events. Weapon *switching* deliberately has no remote of
	its own — it rides on Roblox's default Backpack hotbar (number keys /
	clicking a Tool), which already replicates Tool.Equipped to the server
	for free.

	EVERY remote listed here must actually be listened to on the receiving
	side. Roblox queues events fired at a remote with no connected handler
	and then drops them, printing "Remote event invocation queue exhausted
	for ...; did you forget to implement OnClientEvent?" with a doubling
	drop count. A `ZombieHPChanged` entry was removed from this list for
	exactly that reason: the server broadcast it to all clients on every
	pellet of every hit and no client ever connected to it (see the note
	in WeaponService's resolvePellet). If a remote here has no listener,
	delete it rather than leaving it firing into the void.
]]

local remoteNames = {
	"FireWeapon", -- client -> server: player fired their currently equipped weapon
	"ReloadWeapon", -- client -> server: player requested a manual reload of the equipped weapon
	"AmmoUpdated", -- server -> owning client: authoritative ammo/reload state for a given weapon
	"WeaponFired", -- server -> all clients: origin + per-pellet hit results, for tracer/flash/damage-number effects
	"PlayerHPChanged", -- server -> client: for HP UI
	"PlayerDied", -- server -> client: for death UI
	"CoinsUpdated", -- server -> owning client: authoritative coin balance
	"WeaponsOwned", -- server -> owning client: which weapons are unlocked + their upgrade levels
	"WaveStateChanged", -- server -> all clients: wave number/total/state ("InProgress"/"Break"/"Boss")
	"GameStateChanged", -- server -> all clients: match state ("Lobby"/"Starting"/"BossIncoming"/"Defeat") + seconds left
	"BossHPChanged", -- server -> all clients: boss health bar
	"ShopResult", -- server -> owning client: toast feedback for a purchase/upgrade/secret attempt
	"PurchaseUpgradeRequest", -- client -> server: player wants to upgrade a weapon from the anytime UI panel (not a physical stall)
	"ShowStartConfirmation", -- server -> client: player opened a lobby portal, show the party size (1-4) picker; carries the portal id
	"ConfirmStartGame", -- client -> server: (portalId, partySize) from the picker; partySize nil = cancelled
	"LeaveParty", -- client -> server: player pressed the exit button while waiting inside a portal
	"PartyStatusChanged", -- server -> owning client: (inParty, joined, target) — drives the in-portal waiting UI
	"PerksUpdated", -- server -> owning client: array of owned perk keys, so the perks panel can show OWNED
	"RequestPerkPurchase", -- client -> server: perk key the player tapped buy on; server prompts the real game pass purchase
	"PlayerDownedChanged", -- server -> owning client: entered/left the downed (bleeding out) state, + seconds left
	"ZombieRangedAttack", -- server -> all clients: a Ranged zombie fired, for a visual projectile
	"ZombieExploded", -- server -> all clients: an Exploder zombie went off, for a visual blast
	"WeaponExploded", -- server -> all clients: an ExplodeOnImpact weapon's shot detonated, for a visual blast (see WeaponConfig/WeaponService)
	"WaveModifierAnnounced", -- server -> all clients: this wave's random modifier, for a banner
	"MatchScoreboard", -- server -> all clients: final per-player kills/damage/coins at Victory or Defeat
	"ObjectiveUpdated", -- server -> owning client: session objective progress
	"LeaderboardData", -- server -> owning client: top entries, sent on request
	"RequestLeaderboard", -- client -> server: ask for the current top entries
	"RunUpgradeOffer", -- server -> owning client: the 3 draft cards offered this break (see RunUpgradeConfig/RunUpgradeService)
	"RunUpgradeChosen", -- client -> server: the card id the player picked from their current offer
	"RunUpgradesChanged", -- server -> owning client: owned run-upgrade stacks + the client-side scales derived from them
	"ComboChanged", -- server -> owning client: kill-streak count, current tier and the fire-rate scale the client must mirror (see ComboService)
	"UltimateStateChanged", -- server -> owning client: ultimate charge 0-1, whether it's active, and for how much longer
	"ActivateUltimate", -- client -> server: player pressed the ultimate key; server re-checks charge/liveness before spending it
	"UltimateActivated", -- server -> all clients: someone spent their ultimate, for the aura FX everyone should see
	"SkipWaveBreak", -- client -> server: vote to skip the between-wave break; all living participants must vote before it ends early
	"WaveBreakSkipStatus", -- server -> all clients: (skippedCount, totalNeeded) during a break, or (0, 0) when the break ends
	"PurchaseWeaponRequest", -- client -> server: buy a weapon with this run's cash (replaces the removed lobby Stall_Buy* prompts)
	"MetaProgressChanged", -- server -> owning client: persistent meta level/XP, which decides what the run shop may offer (see MetaConfig)
}

local Remotes = {}

for _, name in remoteNames do
	local existing = script:FindFirstChild(name)
	if existing then
		Remotes[name] = existing
	else
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = script
		Remotes[name] = remote
	end
end

return Remotes
