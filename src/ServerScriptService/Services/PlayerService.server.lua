--[[
	PlayerService.server.lua

	Tier 0 scope: HP tracking, death, and Roblox's default respawn.
	No DataStore yet (that's Tier 1 — coins/unlocked weapons only, per the
	reconciled MVP doc). This just wires up the events the client needs to
	draw an HP bar and a death screen.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)

local PlayerHPChanged = Remotes.PlayerHPChanged
local PlayerDied = Remotes.PlayerDied

local RESPAWN_DELAY_SECONDS = 3

--[[
	Tier 0 has exactly one weapon, so equip it automatically on spawn
	rather than making the player dig it out of their Backpack. Parenting
	a Tool directly to the character is the same thing Humanoid:EquipTool
	does under the hood — it's equipped immediately.
]]
local function equipStarterWeapon(character: Model)
	local tool = WeaponModelFactory.CreateAssaultRifleTool()
	tool.Parent = character
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	equipStarterWeapon(character)

	humanoid.HealthChanged:Connect(function(newHealth)
		PlayerHPChanged:FireClient(player, newHealth, humanoid.MaxHealth)
	end)

	humanoid.Died:Connect(function()
		PlayerDied:FireClient(player)
		task.delay(RESPAWN_DELAY_SECONDS, function()
			if player.Parent then
				player:LoadCharacter()
			end
		end)
	end)

	-- Fire once immediately so the UI has correct values on spawn.
	PlayerHPChanged:FireClient(player, humanoid.Health, humanoid.MaxHealth)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
end)
