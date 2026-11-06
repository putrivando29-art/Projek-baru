--[[
	ServerLink: pembungkus RemoteFunction/RemoteEvent inspector di dalam ScreenGui admin.
	Semua InvokeServer dibungkus pcall; kegagalan dikembalikan sebagai (nil, pesan).
]]

local ServerLink = {}
ServerLink.__index = ServerLink

function ServerLink.new(gui: ScreenGui, protocol: any)
	local request = gui:WaitForChild(protocol.RequestName, 30)
	local stream = gui:WaitForChild(protocol.StreamName, 30)
	return setmetatable({
		request = request,
		stream = stream,
		available = request ~= nil and stream ~= nil,
		lastError = nil,
		calls = 0,
	}, ServerLink)
end

function ServerLink:Call(action: string, payload: any?): (any, string?)
	if not self.available then
		return nil, "remote inspector tidak tersedia"
	end
	self.calls += 1
	local ok, result = pcall(self.request.InvokeServer, self.request, action, payload)
	if not ok then
		self.lastError = tostring(result)
		return nil, self.lastError
	end
	if type(result) == "table" and result.error then
		self.lastError = tostring(result.error)
		return result, self.lastError
	end
	return result, nil
end

-- Panggilan async: callback(result, err) dijalankan di thread baru.
function ServerLink:CallAsync(action: string, payload: any?, callback: (any, string?) -> ())
	task.spawn(function()
		local r, e = self:Call(action, payload)
		local ok, err = pcall(callback, r, e)
		if not ok then
			warn("[RuntimeInspector] callback error: " .. tostring(err))
		end
	end)
end

function ServerLink:OnStream(fn: (string, { any }) -> ()): RBXScriptConnection?
	if not self.stream then
		return nil
	end
	return self.stream.OnClientEvent:Connect(fn)
end

return ServerLink
