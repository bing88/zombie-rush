--[[
	ConsumableConfig.lua

	Run-cash sinks after weapons are maxed: one-shot supplies bought from
	the in-match shop (see ShopService + ShopController). Costs escalate
	per purchase THIS RUN so deep-wave coin piles keep having something
	meaningful to spend on.
]]

export type ConsumableDef = {
	Id: string,
	Name: string,
	Description: string,
	BaseCost: number,
	CostGrowth: number, -- multiplier per prior buy of this id this run
}

local ConsumableConfig = {}

ConsumableConfig.Order = { "Medkit", "AmmoCrate", "Sweep" }

local Items: { [string]: ConsumableDef } = {
	Medkit = {
		Id = "Medkit",
		Name = "Field Medkit",
		Description = "Restore 50 HP",
		BaseCost = 200,
		CostGrowth = 1.35,
	},
	AmmoCrate = {
		Id = "AmmoCrate",
		Name = "Ammo Crate",
		Description = "Refill every magazine",
		BaseCost = 150,
		CostGrowth = 1.35,
	},
	Sweep = {
		Id = "Sweep",
		Name = "Area Sweep",
		Description = "80 damage to every zombie",
		BaseCost = 700,
		CostGrowth = 1.5,
	},
}

ConsumableConfig.Items = Items

-- Flat HP restored by Medkit (capped at MaxHealth server-side).
ConsumableConfig.MedkitHeal = 50
-- Flat damage Area Sweep deals to each living tagged zombie.
ConsumableConfig.SweepDamage = 80

function ConsumableConfig.Get(id: string): ConsumableDef?
	return Items[id]
end

function ConsumableConfig.GetCost(id: string, purchaseCount: number): number?
	local item = Items[id]
	if not item then
		return nil
	end
	local count = math.max(0, purchaseCount)
	return math.floor(item.BaseCost * (item.CostGrowth ^ count) + 0.5)
end

return ConsumableConfig
