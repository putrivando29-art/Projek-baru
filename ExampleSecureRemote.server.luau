--[[
	Contoh Script server: mengamankan remote MILIK GAME ANDA dengan SecureRemote.
	Pasang di ServerScriptService. Remote "BuyItem" dibuat di ReplicatedStorage.GameRemotes.
	Client memanggil: Net.FireServerSecure(remote, "Sword")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local API = require(ServerScriptService:WaitForChild("RuntimeInspectorServer"):WaitForChild("API")).WaitReady()
local S = require(ReplicatedStorage:WaitForChild("RuntimeInspectorNet"):WaitForChild("Schema"))

local folder = ReplicatedStorage:WaitForChild("GameRemotes")
local remote = Instance.new("RemoteEvent")
remote.Name = "BuyItem"
remote.Parent = folder

-- Harga hidup di server. Client hanya menyebut item; client tidak pernah mengirim harga.
local PRICES = { Sword = 100, Shield = 150 }

API.SecureRemote:Bind(remote, {
	schema = S.Tuple({ S.OneOf({ "Sword", "Shield" }) }),
	rate = { perSecond = 2, burst = 4 },
	replay = true,
	maxPayloadBytes = 128,
	handler = function(player: Player, itemName: string)
		local price = PRICES[itemName]
		local coins = player:GetAttribute("Coins") or 0
		if coins < price then
			API.AuditLog:Event("shop.denied", player.Name .. " koin kurang untuk " .. itemName, nil)
			return
		end
		player:SetAttribute("Coins", coins - price)
		API.AuditLog:Event("shop.bought", player.Name .. " membeli " .. itemName, { price = price })
	end,
})

--[[ Teleport sah oleh game: izinkan dulu agar MovementValidator tidak menandai.
	API.MovementValidator:AllowTeleport(player, 2)
	player.Character:PivotTo(targetCFrame)
]]
