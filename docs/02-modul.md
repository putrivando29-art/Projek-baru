# D. Indeks Kode dan E. Fungsi Setiap ModuleScript

Kode lengkap ada di repo. Tabel ini memetakan setiap file ke perannya.

## ReplicatedStorage.RuntimeInspectorNet (direplikasi ke semua client)

| File | Fungsi |
|---|---|
| `src/ReplicatedStorage/RuntimeInspectorNet/Serializer.luau` | `Describe(value)` mengubah nilai apa pun (tabel bertingkat, Vector3, CFrame, Instance, EnumItem, buffer) menjadi tabel plain aman JSON dan daftar masalah: NaN/inf, string non-UTF-8, siklus, tabel campuran/berlubang, metatable, fungsi. `DescribeArgs(...)` aman terhadap `nil` di tengah argumen. `EstimateBytes` perkiraan ukuran payload (estimasi buatan sistem ini, bukan ukuran paket asli). |
| `.../Schema.luau` | Validator: `Number`, `String`, `Boolean`, `Vector3`, `CFrame`, `Instance`, `EnumItem`, `OneOf`, `Optional`, `Array`, `Struct`, `Tuple`. Semua menolak NaN/inf secara default. `CheckTuple(tuple, ...)` untuk argumen remote. |
| `.../Net.luau` | Wrapper instrumentasi untuk remote/bindable milik Anda: `FireServer`, `FireServerSecure` (menambah `seq`, `sentAt`), `InvokeServer`, `OnClientEvent`, `OnServerEvent`, `SetServerInvoke`, `FireClient`, `FireAllClients`, `Fire`, `Invoke`. Mencatat ke ring buffer 600 entri dan `Subscribe` listener. Ini satu-satunya cara sah melihat panggilan **keluar** dan RemoteFunction. |

## ServerStorage.RuntimeInspector.Shared

| File | Fungsi |
|---|---|
| `Config.luau` | Konfigurasi non-rahasia (ikut ke client admin): budget scan, kapasitas log, kelas & properti yang dipantau, ambang anomali, jendela korelasi, hotkey. |
| `Util/Maid.luau` | Cleanup koneksi, Instance, thread, fungsi. `Set(key, task)` mengganti task lama dengan aman. |
| `Util/Signal.luau` | Event internal berbasis tabel (tanpa BindableEvent agar tabel tidak di-deep-copy). |
| `Util/RingBuffer.luau` | Log berukuran tetap dengan nomor urut; `GetSince(seq)` untuk konsumsi inkremental. |
| `Util/RateLimiter.luau` | Token bucket per key + `Prune` agar key lama tidak menumpuk. |
| `Util/Batcher.luau` | Mengirim log per batch (interval / ukuran maksimum); kelebihan antrean dihitung `dropped`. |
| `Util/Scheduler.luau` | `Walk(root, visit, opts)` traversal iteratif dengan budget ms per frame dan batas node. |
| `Core/InstanceInfo.luau` | Baca properti aman (pcall), atribut, tag, Enabled, klasifikasi visibilitas statis (SERVER_ONLY, REPLICATED, OWNER_ONLY, CLIENT_*), detail terformat. |
| `Core/AssetCatalog.luau` | Peta properti aset per kelas (diverifikasi dengan API Dump), `Parse` ID, `Scan(inst)`. Menandai properti PluginSecurity sebagai unreadable. |
| `Core/Findings.luau` | Penyimpanan temuan dengan deduplikasi (rule+path dalam jendela waktu), `RiskScore` heuristik, `GetSince` untuk streaming. |
| `Core/Timeline.luau` | Rekam kejadian aksi; `CorrelateEntries` membentuk rantai kejadian di sekitar anchor (input serang, lompat, Tool.Activated). |
| `Core/Protocol.luau` | Nama remote inspector dan aksi request/stream. |
| `Inspectors/DataModelExplorer.luau` | Root per environment, baseline scan bertahap, `firstSeen`, penanda `runtimeSpawned`, hitungan per service/kelas, children berpaging, pencarian nama + ClassName/IsA, registry ID weak. |
| `Inspectors/ScriptInspector.luau` | Daftar LuaSourceContainer: Enabled, RunContext, atribut, petunjuk lokasi eksekusi, catatan eksposur. Probe `require` terkontrol (default mati, butuh allowlist) dengan waktu muat, status, error, ekspor via `debug.info`. Error dari `ScriptContext.Error`, warning dari `LogService.MessageOut`, riwayat dari `GetLogHistory`. |
| `Inspectors/AssetAuditor.luau` | Kumpulan referensi aset per kategori, jumlah kemunculan, lokasi, service; penilaian kontekstual (INFO/LOW/MEDIUM/HIGH); sinyal `UnknownAsset` untuk aset baru saat runtime. |
| `Inspectors/InstanceMonitor.luau` | `DescendantAdded/Removing` (antrean + budget), `ChildAdded/ChildRemoved` level root, `GetPropertyChangedSignal` untuk properti terdaftar, `AttributeChanged` dengan nilai sebelum/sesudah, batas jumlah watcher. |
| `Inspectors/CharacterProfiler.luau` | Humanoid (StateChanged, Jumping, Running, MoveDirection, WalkSpeed, JumpPower, JumpHeight, AutoRotate, UseJumpPower, HipHeight), sampling HRP posisi/velocity, Tool (Equipped/Unequipped/Activated/Deactivated), Animator.AnimationPlayed (ID, Priority, Speed, WeightCurrent, IsPlaying, Length, Stopped), atribut combat, hitbox & efek (heuristik jarak), input lokal (tanpa merekam ketikan TextBox). |
| `Inspectors/NetworkMonitor.luau` | Listener pasif (OnClientEvent/OnServerEvent/BindableEvent.Event) dengan jeda pemasangan, ingest log wrapper Net, statistik per remote (count, rate, peak, bytes), throttle log, cek skema, sinyal rate exceeded / payload invalid. |
| `Inspectors/AnomalyDetector.luau` | Aturan deteksi yang dipasang ke sinyal modul lain; menghasilkan temuan dengan severity, alasan, rekomendasi. |

## ServerStorage.RuntimeInspector.ServerData (server-only)

| File | Fungsi |
|---|---|
| `ServerConfig.luau` | Admin, aktif di live atau tidak, ambang MovementValidator, combat, honeypot, enforcement, ekspor HTTP (token lewat Secrets Store). |
| `WeaponDefinitions.luau` | Damage, combo multiplier, maxDamage, cooldown, range, ukuran hitbox per Tool. |
| `AssetPolicy.luau` | `Sensitive` (tidak boleh terlihat client) dan `RuntimeAllowlist`. |
| `StaticManifest.luau` | Placeholder; hasil sebenarnya ditulis plugin ke `ServerStorage.RuntimeInspectorManifest`. |

## ServerStorage.RuntimeInspector.ClientPackage (hanya ke admin)

| File | Fungsi |
|---|---|
| `Main.client.luau` | Entry LocalScript; hanya berjalan bila berada di ScreenGui inspector di PlayerGui. |
| `ClientAgent.luau` | Merakit inspector client, cermin data server (findings, net, audit, timeline, monitor), verifikasi replikasi (Instance lokal tiba `nil` di server), divergence check nilai client vs server, laporan temuan client HIGH/CRITICAL ke server. |
| `ServerLink.luau` | `Call`/`CallAsync` ke InspectorRequest dengan pcall; `OnStream`. |
| `ExportCenter.luau` | Sanitasi data, susun laporan per kategori & scope, format JSON/TXT/CSV, paging, print ke Output. |
| `UI/Theme.luau`, `UI/Widgets.luau` | Token warna & helper GUI. |
| `UI/VirtualList.luau` | List virtual (hanya baris terlihat yang di-render). |
| `UI/TreeView.luau` | Directory tree buka/tutup, lazy load, paging "muat lagi". |
| `UI/ListDetailView.luau` | Toolbar filter + list + panel detail yang dipakai banyak tab. |
| `UI/Dashboard.luau` | Jendela, drag, hotkey, sidebar 9 tab, refresh hanya tab aktif. |
| `UI/Tabs/*.luau` | Overview, Explorer, Scripts, Assets, Runtime, Actions, Network, Security, Export. |

## ServerScriptService.RuntimeInspectorServer

| File | Fungsi |
|---|---|
| `init.server.luau` | Bootstrap: keamanan selalu aktif; inspector hanya di Studio atau bila `EnableInLiveGame`. Cleanup di `BindToClose`. |
| `API.luau` | Akses untuk script server Anda: `API.WaitReady()`, lalu `SecureRemote`, `MovementValidator`, `CombatAuthority`, `AuditLog`. |
| `AccessControl.luau` | Siapa yang menerima dashboard. |
| `AuditLog.luau` | Temuan server, log kejadian keamanan, strike & enforcement opsional, ekspor JSON & HTTP. |
| `InspectorBridge.luau` | Pengiriman dashboard ke PlayerGui admin, handler request tervalidasi, stream batch. |
| `Security/SecureRemote.luau` | Pipeline: pemain valid, rate limit, ukuran payload, anti-replay, skema, handler di `xpcall`. |
| `Security/ReplayGuard.luau` | Validasi `seq` monoton dan `sentAt` dalam jendela waktu. |
| `Security/MovementValidator.luau` | Validasi delta posisi (horizontal XZ, kenaikan vertikal, teleport, NaN/inf) dari nilai Humanoid server; `AllowTeleport`; mode log/rubberband. |
| `Security/CombatAuthority.luau` | Combat server-authoritative: tool, stun, cooldown, combo, sudut bidik, hitbox `GetPartBoundsInBox`, range, raycast LOS, batas damage, `TakeDamage`. `ValidateDamage` untuk sistem lain. |
| `Security/Honeypot.luau` | Remote umpan; setiap panggilan = CRITICAL. |

## Studio-only

| File | Fungsi |
|---|---|
| `src/ServerStorage/RuntimeInspector/Tools/SourceAnalyzer.luau` | Membaca Source (plugin/Command Bar), resolusi `require` sederhana, daftar remote yang dipakai, asset ID di source dengan nomor baris, map SurfaceAppearance/MaterialVariant (PluginSecurity), peringatan (require by ID, loadstring, getfenv, parameter otoritatif dari client). Menulis `ServerStorage.RuntimeInspectorManifest`. |
| `plugin/Main.server.luau` | Tombol toolbar "Analyze Sources". |
| `tools/CommandBarAnalyzer.txt` | Satu baris untuk Command Bar. |
| `examples/ExampleSwordClient.client.luau` | Contoh client combat yang hanya mengirim niat. |
| `examples/ExampleSecureRemote.server.luau` | Contoh mengamankan remote toko dengan SecureRemote. |
