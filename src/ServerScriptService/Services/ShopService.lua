--[[
	ShopService.lua (ModuleScript)

	The in-match shop: buying weapons and buying upgrade levels, both
	paid for with THIS RUN's cash (see RunLoadoutService) and both wiped
	when the next match starts.

	WAS PHYSICAL STALLS IN THE LOBBY, NOW A PANEL IN THE MATCH. The five
	Stall_* podiums (2 buy + 3 upgrade) and their ProximityPrompts are
	gone from MapBootstrap. They existed when purchases were permanent,
	which made shopping a thing you did once, in the lobby, before the
	interesting part started. Now that everything resets per run, the
	purchase IS the interesting part — "rifle now, or two more pistol
	levels?" is a decision that only means anything while zombies are
	coming — so both paths moved into the always-available `U` panel
	(ShopController) next to each other, because putting them in two
	different places hid the fact that they compete for the same cash.

	TRUST. Losing the ProximityPrompts means losing the one thing that
	made the old buy path inherently safe: prompt.Triggered reports the
	real triggering Player server-side, so it couldn't be forged. Both
	paths are now client-initiated remotes, so every check that decides
	whether a purchase is legal — is the match running, does the player's
	META level even allow this weapon, do they have the cash, is the
	level already maxed — happens here, and the client sends nothing but
	a weapon name. The name is validated against WeaponConfig before it
	indexes anything.

	SELLING IS REFUSED OUTSIDE AN ACTIVE MATCH. Cash only exists during a
	run, and RunLoadoutService is wiped at both ends of one, so a lobby
	purchase would be spending soon-to-be-deleted money on a
	soon-to-be-deleted weapon. Refusing with a visible message is much
	kinder than accepting it and silently reverting.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local MetaConfig = require(ReplicatedStorage.Shared.MetaConfig)
local ConsumableConfig = require(ReplicatedStorage.Shared.ConsumableConfig)
local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)
local DataService = require(script.Parent.DataService)
local RunLoadoutService = require(script.Parent.RunLoadoutService)
local MatchState = require(script.Parent.MatchState)
local InternalSignals = require(script.Parent.InternalSignals)

local CollectionService = game:GetService("CollectionService")

local CoinsUpdated = Remotes.CoinsUpdated
local WeaponsOwned = Remotes.WeaponsOwned
local ShopResult = Remotes.ShopResult
local PurchaseUpgradeRequest = Remotes.PurchaseUpgradeRequest
local PurchaseWeaponRequest = Remotes.PurchaseWeaponRequest
local PurchaseConsumableRequest = Remotes.PurchaseConsumableRequest
local ConsumablesUpdated = Remotes.ConsumablesUpdated
local MetaProgressChanged = Remotes.MetaProgressChanged

local ShopService = {}

-- [player][consumableId] = purchases this run (drives escalating costs).
local consumableBuys: { [Player]: { [string]: number } } = {}

local function getConsumableBuys(player: Player): { [string]: number }
	local buys = consumableBuys[player]
	if not buys then
		buys = {}
		consumableBuys[player] = buys
	end
	return buys
end

--[[
	Spend path shared by weapon buys, upgrades, consumables, and draft
	rerolls — always syncs CoinsUpdated so the HUD can't drift.
]]
function ShopService.TrySpend(player: Player, amount: number, failMessage: string): boolean
	if amount <= 0 then
		return true
	end
	if not RunLoadoutService.SpendCash(player, amount) then
		ShopResult:FireClient(player, false, failMessage)
		return false
	end
	CoinsUpdated:FireClient(player, RunLoadoutService.GetCash(player))
	return true
end

local function syncConsumables(player: Player)
	local buys = getConsumableBuys(player)
	local payload = {}
	for _, id in ConsumableConfig.Order do
		local count = buys[id] or 0
		payload[id] = {
			Buys = count,
			NextCost = ConsumableConfig.GetCost(id, count),
		}
	end
	ConsumablesUpdated:FireClient(player, payload)
end

--[[
	Pushes the player's whole shop-relevant state: cash, and per weapon
	whether they own it this run, its level, and whether their meta level
	even permits it.

	`available` rides along with `owned` rather than being derived
	client-side from a separate meta message, so the panel can never
	render a buy button for a weapon the server would refuse — the three
	facts it needs to pick a button state all arrive together.
]]
function ShopService.SyncPlayer(player: Player)
	CoinsUpdated:FireClient(player, RunLoadoutService.GetCash(player))

	local metaLevel = MetaConfig.GetLevel(DataService.GetMetaXP(player))
	local owned, levels, available = {}, {}, {}
	for _, weaponName in WeaponConfig.Order do
		owned[weaponName] = RunLoadoutService.IsWeaponUnlocked(player, weaponName)
		levels[weaponName] = RunLoadoutService.GetWeaponLevel(player, weaponName)
		available[weaponName] = MetaConfig.IsWeaponAvailable(metaLevel, weaponName)
	end
	WeaponsOwned:FireClient(player, owned, levels, available)
	syncConsumables(player)
end

--[[
	Sends the persistent meta level and progress toward the next one.
	Separate from SyncPlayer because it changes exactly once per run (at
	the end), whereas the shop state changes on every purchase and every
	kill.
]]
--[[
	The one write path for run cash. Kill payouts, boss bonuses and the
	session-objective reward all come through here so CoinsUpdated can
	never drift from the loadout — previously each caller fired the
	remote itself after talking to DataService, and a missed FireClient
	left the HUD showing a stale bank.
]]
function ShopService.AwardCash(player: Player, amount: number): number
	local newBalance = RunLoadoutService.AddCash(player, amount)
	CoinsUpdated:FireClient(player, newBalance)
	return newBalance
end

function ShopService.SyncAll()
	for _, player in Players:GetPlayers() do
		ShopService.SyncPlayer(player)
		ShopService.SyncMetaProgress(player)
	end
end

--[[
	Makes the player's Tools match the run loadout: destroy anything they
	no longer own, and hand over anything they do own but aren't holding.

	Needed because a match reset does NOT always LoadCharacter (alive
	players are just teleported), so leftover rifles from the previous
	run would otherwise stay in the Backpack after the loadout had
	already forgotten them. Also used after ResetAllRuns so the lobby
	is pistol-only the moment the run ends, not after the next death.
]]
local function reconcileTools(player: Player)
	local character = player.Character
	local backpack = player:FindFirstChildOfClass("Backpack")
	local containers = { character, backpack }
	for _, container in containers do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") and WeaponConfig[child.Name] then
					if not RunLoadoutService.IsWeaponUnlocked(player, child.Name) then
						child:Destroy()
					end
				end
			end
		end
	end

	if not backpack then
		return
	end

	for _, weaponName in WeaponConfig.Order do
		if RunLoadoutService.IsWeaponUnlocked(player, weaponName) then
			local existing = (character and character:FindFirstChild(weaponName))
				or backpack:FindFirstChild(weaponName)
			if not existing then
				local tool = WeaponModelFactory.CreateTool(weaponName)
				if RunLoadoutService.GetWeaponLevel(player, weaponName) >= UpgradeConfig.MaxLevel then
					WeaponModelFactory.ApplyPrestigeEffect(tool)
				end
				tool.Parent = backpack
			end
		end
	end
end

--[[
	Wipes every run loadout back to the starting Pistol and zero cash,
	then forces Tools and the HUD to match. Called at both ends of a
	match (see WaveService) so leftover cash can never be spent in the
	lobby and leftover guns can never walk into the next run.
]]
function ShopService.ResetAllRuns()
	for _, player in Players:GetPlayers() do
		RunLoadoutService.ResetPlayer(player)
		consumableBuys[player] = nil
		reconcileTools(player)
		ShopService.SyncPlayer(player)
	end
end

function ShopService.Init()
	RunLoadoutService.Init()
	Players.PlayerAdded:Connect(function(player)
		-- Meta bar can show before the first match; cash/weapons wait
		-- for the run. Syncing here means a joiner isn't staring at a
		-- blank shop until someone dies.
		task.defer(function()
			if player.Parent then
				ShopService.SyncPlayer(player)
				ShopService.SyncMetaProgress(player)
			end
		end)
	end)
end

function ShopService.SyncMetaProgress(player: Player, xpGained: number?)
	local totalXP = DataService.GetMetaXP(player)
	local level, intoLevel, forNext = MetaConfig.GetProgress(totalXP)
	MetaProgressChanged:FireClient(player, {
		Level = level,
		TotalXP = totalXP,
		XPIntoLevel = intoLevel,
		XPForNextLevel = forNext, -- nil at max level
		XPGained = xpGained, -- set only on the run-end award, for the "+n XP" readout
		MaxLevel = MetaConfig.MaxLevel,
	})
end

local function requireActiveMatch(player: Player): boolean
	if MatchState.IsMatchActive() then
		return true
	end
	ShopResult:FireClient(player, false, "The shop is only open during a match")
	return false
end

local function tryBuyWeapon(player: Player, weaponName: string)
	local stats = WeaponConfig[weaponName]
	if not stats then
		return -- unknown name; nothing to tell the player, they can't have seen it
	end
	if not requireActiveMatch(player) then
		return
	end

	if RunLoadoutService.IsWeaponUnlocked(player, weaponName) then
		ShopResult:FireClient(player, false, "You already have the " .. weaponName)
		return
	end

	-- Meta gate, re-checked server-side: the panel greys these out, but
	-- the panel is the client.
	local metaLevel = MetaConfig.GetLevel(DataService.GetMetaXP(player))
	if not MetaConfig.IsWeaponAvailable(metaLevel, weaponName) then
		ShopResult:FireClient(
			player,
			false,
			("%s unlocks at account level %d"):format(weaponName, MetaConfig.GetWeaponRequiredLevel(weaponName))
		)
		return
	end

	if not RunLoadoutService.SpendCash(player, stats.Price) then
		ShopResult:FireClient(player, false, ("Need %d coins for the %s"):format(stats.Price, weaponName))
		return
	end
	CoinsUpdated:FireClient(player, RunLoadoutService.GetCash(player))

	RunLoadoutService.UnlockWeapon(player, weaponName)
	ShopResult:FireClient(player, true, "Bought the " .. weaponName .. "!")
	ShopService.SyncPlayer(player)

	-- Hand the Tool over immediately: this is a mid-fight purchase, and
	-- waiting for the next respawn to receive it would mean the only way
	-- to use what you just bought is to die.
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
	if not requireActiveMatch(player) then
		return
	end

	if not RunLoadoutService.IsWeaponUnlocked(player, weaponName) then
		ShopResult:FireClient(player, false, "Buy the " .. weaponName .. " first")
		return
	end

	local currentLevel = RunLoadoutService.GetWeaponLevel(player, weaponName)
	local nextLevel = currentLevel + 1
	if nextLevel > UpgradeConfig.MaxLevel then
		ShopResult:FireClient(player, false, weaponName .. " is already max level")
		return
	end

	local levelData = weaponUpgrades.Levels[nextLevel]
	if not RunLoadoutService.SpendCash(player, levelData.Cost) then
		ShopResult:FireClient(player, false, ("Need %d coins for %s Lv%d"):format(levelData.Cost, weaponName, nextLevel))
		return
	end
	CoinsUpdated:FireClient(player, RunLoadoutService.GetCash(player))

	RunLoadoutService.SetWeaponLevel(player, weaponName, nextLevel)
	ShopResult:FireClient(player, true, ("%s upgraded to Lv%d!"):format(weaponName, nextLevel))
	ShopService.SyncPlayer(player)

	-- Magazine capacity scales with level too (see UpgradeConfig) —
	-- refresh the ammo display immediately so a level-up shows the new
	-- max right away instead of waiting for the next reload/switch.
	InternalSignals.RequestAmmoRefresh(player)

	-- Live-apply the max-level cosmetic on whichever Tool instance
	-- currently exists (backpack or equipped) rather than waiting for
	-- the next respawn.
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

PurchaseWeaponRequest.OnServerEvent:Connect(function(player: Player, weaponName: unknown)
	if typeof(weaponName) ~= "string" then
		return
	end
	tryBuyWeapon(player, weaponName :: string)
end)

PurchaseUpgradeRequest.OnServerEvent:Connect(function(player: Player, weaponName: unknown)
	if typeof(weaponName) ~= "string" then
		return
	end
	tryBuyUpgrade(player, weaponName :: string)
end)

local function tryBuyConsumable(player: Player, consumableId: string)
	local def = ConsumableConfig.Get(consumableId)
	if not def then
		return
	end
	if not requireActiveMatch(player) then
		return
	end

	local buys = getConsumableBuys(player)
	local prior = buys[consumableId] or 0
	local cost = ConsumableConfig.GetCost(consumableId, prior)
	if not cost then
		return
	end
	if not ShopService.TrySpend(player, cost, ("Need %d coins for %s"):format(cost, def.Name)) then
		return
	end

	buys[consumableId] = prior + 1

	if consumableId == "Medkit" then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + ConsumableConfig.MedkitHeal)
		end
		ShopResult:FireClient(player, true, ("Used %s (+%d HP)"):format(def.Name, ConsumableConfig.MedkitHeal))
	elseif consumableId == "AmmoCrate" then
		InternalSignals.RequestAmmoRefill(player)
		ShopResult:FireClient(player, true, "Magazines refilled")
	elseif consumableId == "Sweep" then
		local hit = 0
		for _, zombie in CollectionService:GetTagged("Zombie") do
			if zombie:IsA("Model") and zombie.Parent then
				local humanoid = zombie:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					zombie:SetAttribute("LastHitPlayerId", player.UserId)
					humanoid:TakeDamage(ConsumableConfig.SweepDamage)
					hit += 1
				end
			end
		end
		ShopResult:FireClient(player, true, ("Sweep hit %d zombie(s)"):format(hit))
	else
		ShopResult:FireClient(player, true, "Bought " .. def.Name)
	end

	syncConsumables(player)
end

PurchaseConsumableRequest.OnServerEvent:Connect(function(player: Player, consumableId: unknown)
	if typeof(consumableId) ~= "string" then
		return
	end
	tryBuyConsumable(player, consumableId :: string)
end)

Players.PlayerRemoving:Connect(function(player)
	consumableBuys[player] = nil
end)

return ShopService
