--[[
	Signal ringan berbasis tabel (tanpa BindableEvent) agar tabel tidak di-deep-copy
	dan metatable tidak hilang. Listener dipanggil sinkron dalam pcall.
]]

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _listeners = {}, _nextId = 0 }, Signal)
end

function Signal:Connect(fn: (...any) -> ())
	self._nextId += 1
	local id = self._nextId
	self._listeners[id] = fn
	local listeners = self._listeners
	return {
		Connected = true,
		Disconnect = function(conn)
			conn.Connected = false
			listeners[id] = nil
		end,
	}
end

function Signal:Fire(...)
	for _, fn in self._listeners do
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[RuntimeInspector] Signal listener error: " .. tostring(err))
		end
	end
end

function Signal:DisconnectAll()
	table.clear(self._listeners)
end

Signal.Destroy = Signal.DisconnectAll

return Signal
