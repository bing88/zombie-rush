--[[
	ShopService.server.lua

	Tier 1's "basic shop UI" is deliberately just physical stalls with
	ProximityPrompts (Roblox renders the "Hold E" prompt itself — no
	custom shop menu GUI needed) wired to server-side purchase logic here.
	ProximityPrompt.Triggered reports the actual triggering Player
	server-side, so this is not spoofable the way a client-sent "I bought
	X" remote would be — the only client input is walking up and holding
	the interact key; everything about whether the purchase is valid and
	what it costs is decided here.

	Also owns the one secret in the Tier 1 map: a hidden button that
	opens a door to a stash granting a one-time coin bonus per player
	(persisted via DataService.FoundSecret so it can't be re-farmed).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)
local DataService = require(script.Parent.DataService)

local CoinsUpdated = Remotes.CoinsUpdated
local WeaponsOwned = Remotes.WeaponsOwned
local ShopResult = Remotes.ShopResult
local PurchaseUpgradeRequest = Remotes.PurchaseUpgradeRequest

local SECRET_REWARD_COINS = 250

local function syncPlayer(player: Player)
	local profile = DataService.Get(player)
	if not profile then
		return
	end
	CoinsUpdated:FireClient(player, profile.Coins)

	local owned, levels = {}, {}
	for _, weaponName in WeaponConfig.Order do
		owned[weaponName] = DataService.IsWeaponUnlocked(player, weaponName)
		levels[weaponName] = DataService.GetWeaponLevel(player, weaponName)
	end
	WeaponsOwned:FireClient(player, owned, levels)
end

local function tryBuyWeapon(player: Player, weaponName: string)
	local stats = WeaponConfig[weaponName]
	if not stats then
		return
	end
	if DataService.IsWeaponUnlocked(player, weaponName) then
		ShopResult:FireClient(player, false, weaponName .. " already unlocked")
		return
	end
	if not DataService.SpendCoins(player, stats.Price) then
		ShopResult:FireClient(player, false, "Not enough coins for " .. weaponName .. " (" .. stats.Price .. ")")
		return
	end

	DataService.UnlockWeapon(player, weaponName)
	ShopResult:FireClient(player, true, "Unlocked " .. weaponName .. "!")
	syncPlayer(player)

	-- Give the Tool immediately so a mid-match purchase is usable right
	-- away, instead of waiting for the player's next respawn.
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack and not backpack:FindFirstChild(weaponName) then
		local tool = WeaponModelFactory.CreateTool(weaponName)
		tool.Parent = backpack
	end
end

local function tryBuyUpgrade(player: Player, weaponName: string)
	local weaponUpgrades = UpgradeConfig.Weapons[weaponName]
	if not weaponUpgrades then
		return
	end
	if not DataService.IsWeaponUnlocked(player, weaponName) then
		ShopResult:FireClient(player, false, "Unlock " .. weaponName .. " first")
		return
	end

	local currentLevel = DataService.GetWeaponLevel(player, weaponName)
	local nextLevel = currentLevel + 1
	if nextLevel > UpgradeConfig.MaxLevel then
		ShopResult:FireClient(player, false, weaponName .. " is already max level")
		return
	end

	local levelData = weaponUpgrades.Levels[nextLevel]
	if not DataService.SpendCoins(player, levelData.Cost) then
		ShopResult:FireClient(player, false, "Not enough coins for " .. weaponName .. " upgrade (" .. levelData.Cost .. ")")
		return
	end

	DataService.SetWeaponLevel(player, weaponName, nextLevel)
	ShopResult:FireClient(player, true, weaponName .. " upgraded to level " .. nextLevel .. "!")
	syncPlayer(player)
end

local function trySecretButton(_player: Player)
	local door = Workspace.Map:FindFirstChild("SecretDoor")
	if door then
		door.Transparency = 1
		door.CanCollide = false
	end
end

local function trySecretCache(player: Player)
	if DataService.HasFoundSecret(player) then
		ShopResult:FireClient(player, true, "You already claimed this stash.")
		return
	end
	DataService.MarkSecretFound(player)
	local newBalance = DataService.AddCoins(player, SECRET_REWARD_COINS)
	if newBalance then
		CoinsUpdated:FireClient(player, newBalance)
	end
	ShopResult:FireClient(player, true, "Secret stash found! +" .. SECRET_REWARD_COINS .. " coins")
end

local function connectStall(stallName: string, handler: (Player) -> ())
	local mapFolder = Workspace:WaitForChild("Map", 10)
	local stall = mapFolder and mapFolder:WaitForChild(stallName, 10)
	if not stall then
		warn("ShopService: stall not found: " .. stallName)
		return
	end
	local prompt = stall:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		warn("ShopService: no ProximityPrompt on stall: " .. stallName)
		return
	end
	prompt.Triggered:Connect(function(player)
		handler(player)
	end)
end

connectStall("Stall_BuyAssaultRifle", function(player)
	tryBuyWeapon(player, "AssaultRifle")
end)
connectStall("Stall_BuyShotgun", function(player)
	tryBuyWeapon(player, "Shotgun")
end)
connectStall("Stall_UpgradePistol", function(player)
	tryBuyUpgrade(player, "Pistol")
end)
connectStall("Stall_UpgradeAssaultRifle", function(player)
	tryBuyUpgrade(player, "AssaultRifle")
end)
connectStall("Stall_UpgradeShotgun", function(player)
	tryBuyUpgrade(player, "Shotgun")
end)
connectStall("Stall_SecretButton", trySecretButton)
connectStall("Stall_SecretCache", trySecretCache)

--[[
	Anytime upgrade path: same tryBuyUpgrade validation as the physical
	stalls (cost/level-cap/ownership checks all still happen server-side
	here, nothing new is trusted), just triggered by a direct remote
	instead of a ProximityPrompt. This is what backs the client's
	always-available upgrade panel — upgrades shouldn't require walking
	to a specific map location, unlike unlocking a new weapon for the
	first time, which stays a physical stall per the original design.
]]
PurchaseUpgradeRequest.OnServerEvent:Connect(function(player: Player, weaponName: string)
	if typeof(weaponName) ~= "string" then
		return
	end
	tryBuyUpgrade(player, weaponName)
end)
