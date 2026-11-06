--[[
	AuditLog (server)
	- Penyimpanan temuan server (Findings) + log kejadian keamanan (RingBuffer).
	- Sistem strike per pemain dengan peluruhan waktu; penegakan opsional (kick) hanya
	  di game live dan hanya bila ServerConfig.Security.Enforcement = "kick".
	- Ekspor JSON dan (opsional) pengiriman ke endpoint HTTP milik Anda sendiri.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local Root = ServerStorage:WaitForChild("RuntimeInspector")
local Shared = Root:WaitForChild("Shared")
local Findings = require(Shared.Core.Findings)
local RingBuffer = require(Shared.Util.RingBuffer)
local Signal = require(Shared.Util.Signal)

local AuditLog = {}
AuditLog.__index = AuditLog

function AuditLog.new(serverConfig: any, sharedConfig: any)
	local self = setmetatable({
		serverConfig = serverConfig,
		sharedConfig = sharedConfig,
		findings = Findings.new(sharedConfig.Anomaly.Capacity, sharedConfig.Anomaly.DedupeWindow),
		events = RingBuffer.new(3000),
		strikes = {},
		EventAdded = Signal.new(),
	}, AuditLog)
	self.conn = Players.PlayerRemoving:Connect(function(p)
		self.strikes[p] = nil
	end)
	return self
end

function AuditLog:Event(kind: string, summary: string, data: { [string]: any }?)
	local entry = {
		t = os.clock(),
		st = workspace:GetServerTimeNow(),
		env = "server",
		kind = kind,
		summary = summary,
		data = data,
	}
	entry.seq = self.events:Push(entry)
	self.EventAdded:Fire(entry)
	return entry
end

function AuditLog:Strike(player: Player?, severity: string, reason: string)
	if not player or player.Parent ~= Players then
		return
	end
	local sec = self.serverConfig.Security
	local now = os.clock()
	local s = self.strikes[player] or { score = 0, last = now }
	-- peluruhan linear
	local decay = (now - s.last) / sec.StrikeDecaySeconds * sec.KickStrikeThreshold
	s.score = math.max(0, s.score - decay) + (sec.Weights[severity] or 1)
	s.last = now
	self.strikes[player] = s
	if sec.Enforcement == "kick" and not RunService:IsStudio() and s.score >= sec.KickStrikeThreshold then
		self:Event("enforcement.kick", player.Name .. " di-kick (strike " .. math.floor(s.score) .. ")", { reason = reason })
		player:Kick("Koneksi diputus oleh sistem keamanan server.")
	end
end

-- f mengikuti format Findings:Report. player (Instance) opsional untuk strike.
function AuditLog:Finding(f: { [string]: any }, player: Player?)
	f.env = "server"
	if player then
		f.player = player.Name
		f.path = f.path or ("Players." .. player.Name)
	end
	local entry = self.findings:Report(f)
	if player and f.strike ~= false then
		self:Strike(player, entry.severity, entry.rule)
	end
	return entry
end

function AuditLog:StrikeScore(player: Player): number
	local s = self.strikes[player]
	return s and math.floor(s.score * 10) / 10 or 0
end

function AuditLog:ExportTable(): { [string]: any }
	return {
		generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		placeId = game.PlaceId,
		jobId = game.JobId,
		isStudio = RunService:IsStudio(),
		riskScore = self.findings:RiskScore(),
		counts = self.findings:Counts(),
		findings = self.findings:List(),
		events = self.events:ToArray(),
	}
end

-- Kirim JSON ke endpoint sendiri, dipotong per ChunkChars. Hanya bila diaktifkan.
function AuditLog:PostHttp(json: string): (boolean, string)
	local cfg = self.serverConfig.Export
	if not cfg.HttpEnabled or cfg.Url == "" then
		return false, "Export HTTP nonaktif (ServerConfig.Export.HttpEnabled/Url)"
	end
	local headers = { ["Content-Type"] = "application/json" }
	if cfg.SecretName ~= "" then
		local okSecret, secret = pcall(HttpService.GetSecret, HttpService, cfg.SecretName)
		if okSecret and secret then
			local okPrefix, value = pcall(function()
				return secret:AddPrefix("Bearer ")
			end)
			if okPrefix then
				headers["Authorization"] = value
			end
		end
	end
	local total = math.ceil(#json / cfg.ChunkChars)
	for i = 1, total do
		local chunk = string.sub(json, (i - 1) * cfg.ChunkChars + 1, i * cfg.ChunkChars)
		local ok, res = pcall(HttpService.RequestAsync, HttpService, {
			Url = cfg.Url,
			Method = "POST",
			Headers = headers,
			Body = HttpService:JSONEncode({ part = i, total = total, jobId = game.JobId, data = chunk }),
		})
		if not ok then
			return false, tostring(res)
		end
		if not res.Success then
			return false, "HTTP " .. tostring(res.StatusCode)
		end
	end
	return true, "terkirim " .. total .. " bagian"
end

function AuditLog:Destroy()
	self.conn:Disconnect()
end

return AuditLog
