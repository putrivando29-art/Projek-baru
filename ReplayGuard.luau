--[[
	ReplayGuard
	Memvalidasi (seq, sentAt) yang ditambahkan Net.FireServerSecure di client:
	- seq harus integer dan lebih besar dari seq terakhir untuk (player, remote).
	- sentAt (workspace:GetServerTimeNow() di client) harus dalam jendela waktu.

	Batas yang jujur: client (termasuk exploiter) yang mengendalikan Net bisa membuat
	seq & sentAt valid sendiri. ReplayGuard hanya menolak pengiriman ulang paket lama
	dan duplikasi naif. Perlindungan sebenarnya adalah state server (cooldown, idempotensi).
]]

local Players = game:GetService("Players")

local ReplayGuard = {}
ReplayGuard.__index = ReplayGuard

function ReplayGuard.new(windowSeconds: number, maxSeqJump: number)
	local self = setmetatable({ window = windowSeconds, maxJump = maxSeqJump, last = {} }, ReplayGuard)
	self.conn = Players.PlayerRemoving:Connect(function(p)
		self.last[p] = nil
	end)
	return self
end

function ReplayGuard:Check(player: Player, remoteName: string, seq: any, sentAt: any): (boolean, string?)
	if type(seq) ~= "number" or seq ~= seq or seq % 1 ~= 0 or seq < 1 then
		return false, "seq tidak valid"
	end
	if type(sentAt) ~= "number" or sentAt ~= sentAt then
		return false, "sentAt tidak valid"
	end
	local now = workspace:GetServerTimeNow()
	if math.abs(now - sentAt) > self.window then
		return false, string.format("sentAt di luar jendela (selisih %.2fs)", now - sentAt)
	end
	local perPlayer = self.last[player]
	if not perPlayer then
		perPlayer = {}
		self.last[player] = perPlayer
	end
	local last = perPlayer[remoteName] or 0
	if seq <= last then
		return false, "seq " .. seq .. " <= terakhir " .. last .. " (replay/duplikat)"
	end
	if seq - last > self.maxJump then
		return false, "lompatan seq terlalu besar"
	end
	perPlayer[remoteName] = seq
	return true
end

function ReplayGuard:Destroy()
	self.conn:Disconnect()
	table.clear(self.last)
end

return ReplayGuard
