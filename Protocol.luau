--[[
	Protocol: nama remote & aksi antara dashboard client dan server.
	Remote inspector dibuat server DI DALAM ScreenGui milik admin (PlayerGui), sehingga
	hanya client admin tersebut yang menerima replikasinya.
]]

return table.freeze({
	GuiName = "RuntimeInspectorGui",
	RequestName = "InspectorRequest", -- RemoteFunction (client admin -> server, query)
	StreamName = "InspectorStream", -- RemoteEvent (server -> client admin, batch log)

	Actions = table.freeze({
		Hello = "hello",
		TreeRoots = "tree.roots",
		TreeChildren = "tree.children",
		TreeDetails = "tree.details",
		TreeSearch = "tree.search",
		ScriptsList = "scripts.list",
		ScriptsManifest = "scripts.manifest",
		ScriptsProbe = "scripts.probe",
		AssetsReport = "assets.report",
		FindingsSince = "findings.since",
		NetSince = "net.since",
		EventsSince = "events.since",
		VerifyReplication = "verify.replication",
		VerifyValues = "verify.values",
		ReportClient = "report.client",
		ExportServer = "export.server",
		Overview = "overview",
	}),

	Stream = table.freeze({
		Findings = "findings",
		Net = "net",
		Events = "events",
		Notice = "notice",
	}),
})
