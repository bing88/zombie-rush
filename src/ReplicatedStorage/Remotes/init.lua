--[[
	Remotes/init.lua
	Central place to create and fetch RemoteEvents so client and server
	never hardcode WaitForChild paths all over the codebase.

	Tier 1 adds coins/shop/wave/game-state/boss events on top of Tier 0's
	weapon + HP events. Weapon *switching* deliberately has no remote of
	its own — it rides on Roblox's default Backpack hotbar (number keys /
	clicking a Tool), which already replicates Tool.Equipped to the server
	for free.
]]

local remoteNames = {
	"FireWeapon", -- client -> server: player fired their currently equipped weapon
	"ReloadWeapon", -- client -> server: player requested a manual reload of the equipped weapon
	"AmmoUpdated", -- server -> owning client: authoritative ammo/reload state for a given weapon
	"WeaponFired", -- server -> all clients: origin + per-pellet hit results, for tracer/flash/damage-number effects
	"ZombieHPChanged", -- server -> client: for hit feedback / health bars
	"PlayerHPChanged", -- server -> client: for HP UI
	"PlayerDied", -- server -> client: for death UI
	"CoinsUpdated", -- server -> owning client: authoritative coin balance
	"WeaponsOwned", -- server -> owning client: which weapons are unlocked + their upgrade levels
	"WaveStateChanged", -- server -> all clients: wave number/total/state ("InProgress"/"Break"/"Boss")
	"GameStateChanged", -- server -> all clients: match state ("Lobby"/"Starting"/"BossIncoming"/"Victory") + seconds left
	"BossHPChanged", -- server -> all clients: boss health bar
	"ShopResult", -- server -> owning client: toast feedback for a purchase/upgrade/secret attempt
	"PurchaseUpgradeRequest", -- client -> server: player wants to upgrade a weapon from the anytime UI panel (not a physical stall)
	"ShowStartConfirmation", -- server -> client: player stepped on the lobby teleport pad, show a Yes/No prompt
	"ConfirmStartGame", -- client -> server: player's answer to the above
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
