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

	Weapon upgrades are ALSO purchasable anytime via ShopController's
	client-side panel (PurchaseUpgradeRequest below) — both paths call
	the exact same tryBuyUpgrade validation, so server-side trust is
	identical either way; only the trigger differs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)
local DataService = require(script.Parent.DataService)
local InternalSignals = require(script.Parent.InternalSignals)

local CoinsUpdated = Remotes.CoinsUpdated
local WeaponsOwned = Remotes.WeaponsOwned
local ShopResult = Remotes.ShopResult
local PurchaseUpgradeRequest = Remotes.PurchaseUpgradeRequest

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

	-- Magazine capacity scales with level too (see UpgradeConfig) —
	-- refresh the ammo display immediately so a level-up shows the new
	-- max right away instead of waiting for the next reload/switch.
	InternalSignals.RequestAmmoRefresh(player)

	-- Live-apply the prestige cosmetic the instant a weapon hits max
	-- level, on whichever Tool instance currently exists (backpack or
	-- equipped) rather than waiting for the next respawn.
	if nextLevel >= UpgradeConfig.MaxLevel then
		local character = player.Character
		local backpack = player:FindFirstChildOfClass("Backpack")
		local tool = (character and character:FindFirstChild(weaponName))
			or (backpack and backpack:FindFirstChild(weaponName))
		if tool and tool:IsA("Tool") then
			WeaponModelFactory.ApplyPrestigeEffect(tool)
		end
	end
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
