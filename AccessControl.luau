--[[
	AccessControl
	Menentukan siapa yang boleh menerima dashboard inspector.
	- Studio + AllowAllInStudio: semua pemain uji (Play Solo / Start Server + Players).
	- Game live: hanya bila EnableInLiveGame = true DAN UserId ada di AdminUserIds.
	Data inspector server (struktur ServerStorage, log keamanan) adalah informasi sensitif;
	jangan pernah mengirimnya ke pemain yang tidak terotorisasi.
]]

local RunService = game:GetService("RunService")

local AccessControl = {}

function AccessControl.IsAuthorized(player: Player, serverConfig: any): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if RunService:IsStudio() then
		if serverConfig.AllowAllInStudio then
			return true
		end
		return serverConfig.AdminUserIds[player.UserId] == true
	end
	if not serverConfig.EnableInLiveGame then
		return false
	end
	return serverConfig.AdminUserIds[player.UserId] == true
end

return AccessControl
