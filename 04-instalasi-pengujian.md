# F. Pemasangan, G. Pengujian, J. Checklist

## F. Panduan pemasangan di Roblox Studio

### Opsi 1: Rojo (disarankan)

1. Pasang Rojo 7 (CLI) dan plugin Rojo di Studio: https://rojo.space/docs/v7/getting-started/installation/
2. Di folder repo: `rojo serve`
3. Di Studio, buka place Anda, plugin Rojo > **Connect**. Struktur di docs/01 bagian B akan muncul.
4. Plugin Source Analyzer: `rojo build plugin.project.json --plugin RuntimeInspectorAnalyzer.rbxm`, lalu restart Studio. Tombol **Runtime Inspector > Analyze Sources** muncul di tab Plugins.
5. (Opsional) Salin contoh: buat Tool `ExampleSword` di StarterPack dengan Part `Handle`, masukkan `examples/ExampleSwordClient.client.luau` sebagai LocalScript di dalamnya. `examples/ExampleSecureRemote.server.luau` ke ServerScriptService.

### Opsi 2: Manual

1. Buat Instance persis seperti pohon di docs/01 bagian B. Nama harus sama.
2. Untuk setiap file `.luau`: buat ModuleScript dengan nama file tanpa ekstensi, tempel isinya. `Main.client.luau` dibuat sebagai **LocalScript** bernama `Main`. `init.server.luau` adalah isi **Script** `RuntimeInspectorServer`; file lain di folder itu menjadi child-nya.
3. Plugin manual: buat Script `Main` (isi `plugin/Main.server.luau`), letakkan ModuleScript `SourceAnalyzer` sebagai child-nya, klik kanan Script > **Save as Local Plugin...**
4. Tanpa plugin pun, Command Bar bisa dipakai: tempel isi `tools/CommandBarAnalyzer.txt`.

### Konfigurasi minimum

- `ServerData/ServerConfig.luau`
  - Biarkan `EnableInLiveGame = false` sampai Anda selesai menguji.
  - Untuk live: isi `AdminUserIds = { [UserIdAnda] = true }` lalu `EnableInLiveGame = true`.
- `ServerData/WeaponDefinitions.luau`: key harus sama dengan `Tool.Name`.
- `Shared/Config.luau`: `AllowedWalkSpeeds` (mis. `{16, 24}` bila ada sprint), `AllowedMoverNames` untuk mover milik game (dash, knockback).
- Lapisan keamanan (`Security/*`) aktif juga di game live walau inspector mati.

## G. Cara menjalankan pengujian

### G.1 Play Solo (Test > Play)

1. Tekan **Play**. Output harus menampilkan:
   - `[RuntimeInspector] server siap: ...`
   - `[RuntimeInspector] client siap (...). Tekan F6 untuk membuka dashboard.`
2. Tekan **F6**. Tab Overview menampilkan angka client / server.
3. Gunakan tombol **Client/Server** di toolbar Studio untuk berpindah konteks Explorer dan Command Bar (lihat https://create.roblox.com/docs/studio/testing-modes).

### G.2 Start Server + Start Player (Test > Clients and Servers)

1. Pilih jumlah pemain (mis. 2), **Start**. Studio membuka satu jendela server dan satu jendela per pemain.
2. Di Studio, `AllowAllInStudio = true` membuat semua pemain uji menerima dashboard. Ubah ke `false` dan isi `AdminUserIds` untuk menguji kontrol akses (pemain uji Studio biasanya ber-UserId negatif).
3. Di jendela server, Output menunjukkan `inspector.delivered` per pemain (tab Security > Log audit server).

### G.3 Skenario uji (jalankan dari Command Bar dalam mode Client, di jendela pemain)

| # | Perintah Command Bar (konteks client) | Hasil yang diharapkan |
|---|---|---|
| 1 | `game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = 80` lalu berjalan | Client: `movement.walkspeed_change` HIGH. Client: `verify.client_server_divergence` HIGH (setelah ±4 detik). Server: `movement.speed` MEDIUM lalu HIGH bila berulang. |
| 2 | `game.Players.LocalPlayer.Character:PivotTo(CFrame.new(0, 20, 600))` | Client: `movement.position_jump` MEDIUM. Server: `movement.teleport` HIGH. |
| 3 | `game.ReplicatedStorage.GameRemotes.AdminGiveCurrency:FireServer(99999)` | Server: `honeypot.triggered` CRITICAL. |
| 4 | `game.ReplicatedStorage.GameRemotes.CombatRequest:FireServer("Attack", Vector3.new(0,0,-1))` | Server: `remote.replay` MEDIUM (tanpa seq/sentAt). |
| 5 | `game.ReplicatedStorage.GameRemotes.CombatRequest:FireServer(1, workspace:GetServerTimeNow(), "Attack", Vector3.new(0/0, 0, 0))` | Server: `remote.schema_violation` HIGH (NaN). Jalankan skenario 4 sampai 6 di sesi baru SEBELUM memakai ExampleSword, karena `seq` harus lebih besar dari seq terakhir pemain. |
| 6 | `for i = 2, 61 do game.ReplicatedStorage.GameRemotes.CombatRequest:FireServer(i, workspace:GetServerTimeNow(), "Attack", Vector3.new(0,0,-1)) end` | Server: `remote.rate_limited` MEDIUM dan `network.rate_exceeded`. Client tidak melihat panggilan ini sebagai Outgoing karena Command Bar tidak memakai `Net` wrapper (ini contoh langsung batas observasi pasif). |
| 7 | `local p = Instance.new("Part"); p.Name = "Hitbox"; p.Size = Vector3.new(40,40,40); p.Anchored = true; p.Parent = workspace` | Client: `combat.hitbox_oversize` HIGH. Explorer: part ber-label CLIENT_LOCAL setelah verifikasi. |
| 8 | `local bv = Instance.new("BodyVelocity"); bv.Parent = game.Players.LocalPlayer.Character.HumanoidRootPart` | Client: `runtime.mover_in_character` MEDIUM. |
| 9 | Equip ExampleSword, klik | Action Profiler: rantai `Input.AttackBegan` -> `Tool.Activated` -> `Remote.Client->Server`. Server: `combat.attack`, `combat.hit` di Log audit. |
| 10 | Klik sangat cepat dengan cooldown lokal dihapus dari contoh | Server: `combat.cooldown_bypass` MEDIUM. |

### G.4 Verifikasi replikasi
Buka Explorer (Client), buka `Workspace`. Node berubah warna dari abu (UNVERIFIED) ke hijau (CLIENT_REPLICATED) atau oranye (CLIENT_LOCAL) dalam 1 sampai 2 detik.

### G.5 Uji [Kemungkinan Besar]: Tool.Activated di server
Klik ExampleSword. Di Actions > Server, cari `Tool.Activated`. Bila tidak ada, ubah label di docs/03 menjadi "tidak fire di server" untuk game Anda.

### G.6 Uji [Spekulatif]: AnimationPlayed di server untuk animasi client
Set atribut Tool `AttackAnimationId` dengan ID animasi milik Anda, klik. Di Actions > Server filter Animation. Ada entri `Animator.AnimationPlayed` = event fire di server; tidak ada = hanya client.

### G.7 Static manifest
Di mode edit, klik **Analyze Sources**. Output: `[RuntimeInspector] SourceAnalyzer: N script, ...`. Play lagi; Scripts tab > pilih script > bagian "Dependency & referensi" terisi. Assets > "Di source" berisi ID dari kode.

### G.8 Uji [Kemungkinan Besar]: dashboard tidak bocor ke pemain lain
Start 2 pemain dengan `AllowAllInStudio = false` dan hanya Player1 di `AdminUserIds`. Di jendela Player2, Explorer Studio: `Players.Player1.PlayerGui` tidak boleh berisi `RuntimeInspectorGui`.

## J. Checklist modul

| ✓ | Pemeriksaan | Cara |
|---|---|---|
| [ ] | Rojo sync lengkap | Pohon docs/01-B ada; tidak ada error require di Output |
| [ ] | Bootstrap server | Output `server siap` |
| [ ] | Dashboard terkirim | `PlayerGui.RuntimeInspectorGui` ada di pemain uji; Output `client siap` |
| [ ] | Overview | Angka client & server terisi; server bukan `?` |
| [ ] | Explorer client & server | ServerStorage terlihat hanya di mode Server |
| [ ] | Search & filter class | Cari `Part` di class filter |
| [ ] | Verifikasi replikasi | Warna node berubah (G.4) |
| [ ] | Script Inspector | Daftar terisi; Rescan bekerja; Error tab menampilkan error uji (`error("tes")` di Command Bar client) |
| [ ] | Probe require | Tambah FullName modul ke `ProbeAllowlist`, `AllowRequireProbe = true`, tombol Probe menampilkan ekspor |
| [ ] | Asset Inspector | Kategori terisi; Unreadable menampilkan MaterialVariant bila ada |
| [ ] | Runtime Monitor | Skenario 7 dan 8 muncul sebagai `added` |
| [ ] | Action Profiler | Lompat (Space): rantai `Input.JumpBegan` -> `Humanoid.Jumping` -> `StateChanged Jumping/Freefall/Landed` |
| [ ] | Network Monitor | Skenario 9: Outgoing (wrapper) di client, Incoming di server |
| [ ] | Security Audit | Skenario 1 sampai 8 menghasilkan temuan sesuai tabel G.3 |
| [ ] | Export | JSON/TXT/CSV ter-generate; Prev/Next; Print ke Output; Laporan lengkap server |
| [ ] | Respawn tanpa kebocoran | Reset karakter 10x; jumlah entri Animation per lompat tidak berlipat; MicroProfiler/Developer Console Memory stabil |
| [ ] | Keluar pemain | Start 2 pemain, tutup satu; tidak ada error di server |
| [ ] | Game live aman | `EnableInLiveGame=false`: publish, join; tidak ada `RuntimeInspectorGui`; Security tetap aktif (honeypot tetap mencatat) |

## Performa: hal yang perlu diketahui

- Saat start, beberapa traversal berjalan bersamaan (Explorer, Asset, Script, Network), masing-masing dibatasi `Scan.FrameBudgetMs` per frame. Pada place sangat besar, turunkan nilai itu.
- `Monitor.QueueMax` dan `MaxWatchedInstances` membatasi biaya saat ledakan Instance (misal map dimuat). Lihat `dropped` dan `watchSkipped` di Runtime Monitor.
- Hanya tab aktif yang di-refresh (`UI.RefreshHz`).
