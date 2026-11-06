# A. Arsitektur, B. Struktur Folder, C. Daftar ModuleScript

## A. Arsitektur keseluruhan

Sistem dipisah menjadi empat lapisan dengan batas kepercayaan yang tegas.

```
                         ┌──────────────────────────────────────────────┐
                         │ SERVER (ServerScriptService + ServerStorage) │
                         │                                              │
  Selalu aktif ────────► │ Security: AuditLog, SecureRemote, ReplayGuard│
  (juga di game live)    │           MovementValidator, CombatAuthority │
                         │           Honeypot                           │
                         │                                              │
  Studio / admin ──────► │ Inspector server: Explorer, ScriptInspector, │
                         │   AssetAuditor, InstanceMonitor,             │
                         │   CharacterProfiler, NetworkMonitor,         │
                         │   AnomalyDetector, Timeline                  │
                         │                 │                            │
                         │          InspectorBridge                     │
                         └─────────────────┼────────────────────────────┘
                                           │ ScreenGui dibuat server di PlayerGui admin:
                                           │   RemoteFunction InspectorRequest (query)
                                           │   RemoteEvent    InspectorStream  (batch log)
                         ┌─────────────────┼────────────────────────────┐
                         │ CLIENT ADMIN (PlayerGui.RuntimeInspectorGui) │
                         │   ClientAgent: inspector client yang sama    │
                         │     + cermin data server + verifikasi        │
                         │   Dashboard: 9 tab, VirtualList, TreeView    │
                         └──────────────────────────────────────────────┘
  Semua client ────────► ReplicatedStorage.RuntimeInspectorNet (Net, Schema, Serializer)
  Studio editor ───────► plugin/SourceAnalyzer -> ServerStorage.RuntimeInspectorManifest
```

Prinsip desain:

1. **Satu kode inspector untuk dua environment.** Modul di `Shared/Inspectors` membaca `RunService:IsServer()` dan hanya menyentuh API yang tersedia di environment itu. Server melihat ServerStorage/ServerScriptService; client tidak pernah mencoba.
2. **Data server ke client hanya lewat jawaban server.** Client admin tidak "membaca ServerStorage". InspectorBridge mengirim data (string, angka, tabel) dan merujuk Instance server-only dengan ID numerik dari registry weak table, karena referensi Instance server-only yang dikirim ke client akan tiba sebagai `nil` (didokumentasikan Roblox, lihat docs/03).
3. **Permukaan serangan minimal.** Remote inspector dibuat di dalam ScreenGui milik admin, bukan di ReplicatedStorage. Setiap request divalidasi: pemanggil = pemilik sesi, masih terotorisasi, lolos rate limit.
4. **Keamanan tidak bergantung pada client.** Deteksi di client hanya indikator untuk pengujian Studio. Validasi otoritatif ada di `Security/*` di server.
5. **Performa terkendali.** Traversal pakai stack eksplisit + budget waktu per frame; event `DescendantAdded` hanya masuk antrean O(1) dan diproses di Heartbeat dengan budget; log memakai RingBuffer berukuran tetap; UI memakai list virtual dan hanya tab aktif yang di-refresh.
6. **Cleanup eksplisit.** Setiap pemain, karakter, tool, dan watcher punya `Maid`. Respawn membersihkan semua koneksi karakter lama sebelum membuat yang baru.

## B. Struktur folder Roblox Studio (hasil sync Rojo)

```
ReplicatedStorage
├─ RuntimeInspectorNet                (Folder)          direplikasi ke SEMUA client
│  ├─ Net                             (ModuleScript)    wrapper instrumentasi remote/bindable
│  ├─ Schema                          (ModuleScript)    validator argumen
│  └─ Serializer                      (ModuleScript)    deskripsi nilai, deteksi NaN/inf/siklus
└─ GameRemotes                        (Folder, dibuat runtime oleh server)
   ├─ CombatRequest                   (RemoteEvent)     dipakai CombatAuthority
   ├─ AdminGiveCurrency, SetPlayerStats (RemoteEvent)   honeypot (nama dari ServerConfig)
   └─ GetAdminPanelData               (RemoteFunction)  honeypot

ServerStorage                                            TIDAK pernah direplikasi
├─ RuntimeInspector                   (Folder)
│  ├─ Shared                          (Folder)          di-clone ke dashboard admin
│  │  ├─ Config                       (ModuleScript)    konfigurasi NON-rahasia
│  │  ├─ Util/ Maid, Signal, RingBuffer, RateLimiter, Batcher, Scheduler
│  │  ├─ Core/ InstanceInfo, AssetCatalog, Findings, Timeline, Protocol
│  │  └─ Inspectors/ DataModelExplorer, ScriptInspector, AssetAuditor,
│  │                 InstanceMonitor, CharacterProfiler, NetworkMonitor, AnomalyDetector
│  ├─ ServerData                      (Folder)          server-only, tidak pernah di-clone
│  │  ├─ ServerConfig                 (ModuleScript)    admin, ambang, honeypot, ekspor
│  │  ├─ WeaponDefinitions            (ModuleScript)    damage/cooldown/range/hitbox
│  │  ├─ AssetPolicy                  (ModuleScript)    aset sensitif & allowlist runtime
│  │  └─ StaticManifest               (ModuleScript)    placeholder kosong
│  ├─ ClientPackage                   (Folder)          di-clone ke PlayerGui admin
│  │  ├─ Main                         (LocalScript)
│  │  ├─ ClientAgent, ServerLink, ExportCenter (ModuleScript)
│  │  └─ UI/ Theme, Widgets, VirtualList, TreeView, ListDetailView, Dashboard
│  │        Tabs/ OverviewTab, ExplorerTab, ScriptsTab, AssetsTab, RuntimeTab,
│  │              ActionsTab, NetworkTab, SecurityTab, ExportTab
│  └─ Tools
│     └─ SourceAnalyzer               (ModuleScript)    Studio-only (plugin / Command Bar)
└─ RuntimeInspectorManifest           (ModuleScript, ditulis plugin; di luar folder Rojo)

ServerScriptService
└─ RuntimeInspectorServer             (Script)          bootstrap
   ├─ API, AccessControl, AuditLog, InspectorBridge (ModuleScript)
   └─ Security/ SecureRemote, ReplayGuard, MovementValidator, CombatAuthority, Honeypot

Players.<Admin>.PlayerGui                                 dibuat server saat runtime
└─ RuntimeInspectorGui                (ScreenGui, ResetOnSpawn=false)
   ├─ InspectorRequest (RemoteFunction), InspectorStream (RemoteEvent)
   ├─ Shared  (clone)
   └─ Package (clone ClientPackage)  -> Main LocalScript berjalan di sini
```

Mengapa bukan StarterPlayerScripts? Isi StarterPlayerScripts disalin ke setiap pemain, jadi kode inspector dan nama remote-nya akan ada di semua client dan dapat didekompilasi. Dokumentasi Roblox menyatakan LocalScript dan ModuleScript yang direplikasi dapat didekompilasi exploiter walau tidak pernah dijalankan ([Access control](https://create.roblox.com/docs/scripting/security/access-control), bagian *Script decompilation*). Pengiriman lewat PlayerGui membatasi kode itu ke admin. **[Kemungkinan Besar]** bahwa isi PlayerGui hanya direplikasi ke pemiliknya: API Dump menandai kelas `PlayerGui` dengan tag `PlayerReplicated`, tetapi halaman dokumentasi PlayerGui tidak menyatakannya secara eksplisit.

## C. Daftar ModuleScript yang harus dibuat

| # | Path | Jenis | Environment |
|---|---|---|---|
| 1 | ReplicatedStorage.RuntimeInspectorNet.Net | ModuleScript | client + server |
| 2 | ReplicatedStorage.RuntimeInspectorNet.Schema | ModuleScript | client + server |
| 3 | ReplicatedStorage.RuntimeInspectorNet.Serializer | ModuleScript | client + server |
| 4 | ServerStorage.RuntimeInspector.Shared.Config | ModuleScript | client admin + server |
| 5-10 | Shared.Util.Maid / Signal / RingBuffer / RateLimiter / Batcher / Scheduler | ModuleScript | client admin + server |
| 11-15 | Shared.Core.InstanceInfo / AssetCatalog / Findings / Timeline / Protocol | ModuleScript | client admin + server |
| 16-22 | Shared.Inspectors.DataModelExplorer / ScriptInspector / AssetAuditor / InstanceMonitor / CharacterProfiler / NetworkMonitor / AnomalyDetector | ModuleScript | client admin + server |
| 23-26 | ServerData.ServerConfig / WeaponDefinitions / AssetPolicy / StaticManifest | ModuleScript | server |
| 27 | ClientPackage.Main | **LocalScript** | client admin |
| 28-30 | ClientPackage.ClientAgent / ServerLink / ExportCenter | ModuleScript | client admin |
| 31-36 | ClientPackage.UI.Theme / Widgets / VirtualList / TreeView / ListDetailView / Dashboard | ModuleScript | client admin |
| 37-45 | ClientPackage.UI.Tabs.* (9 tab) | ModuleScript | client admin |
| 46 | ServerStorage.RuntimeInspector.Tools.SourceAnalyzer | ModuleScript | Studio (plugin/Command Bar) |
| 47 | ServerScriptService.RuntimeInspectorServer | **Script** | server |
| 48-51 | RuntimeInspectorServer.API / AccessControl / AuditLog / InspectorBridge | ModuleScript | server |
| 52-56 | RuntimeInspectorServer.Security.SecureRemote / ReplayGuard / MovementValidator / CombatAuthority / Honeypot | ModuleScript | server |
| 57 | plugin/Main (Script plugin) | Script | Studio |

Nama file Rojo: `*.luau` = ModuleScript, `*.client.luau` = LocalScript, `*.server.luau` = Script, folder dengan `init.server.luau` = Script yang memiliki child.
