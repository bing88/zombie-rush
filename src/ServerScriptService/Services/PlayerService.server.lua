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

local PlayerHPChanged = Remotes.PlayerHPChanged
local PlayerDied = Remotes.PlayerDied

local RESPAWN_DELAY_SECONDS = 3

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

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
