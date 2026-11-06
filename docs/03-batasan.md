# Batasan Resmi: Apa yang Bisa dan Tidak Bisa Diamati

Label keyakinan:
- **[Pasti]**: dinyatakan dokumentasi resmi Roblox atau terlihat langsung di API Dump.
- **[Kemungkinan Besar]**: inferensi kuat dari dokumentasi/API, belum dinyatakan eksplisit.
- **[Spekulatif]**: belum terverifikasi; ada langkah uji di docs/04 untuk memastikannya.

Sumber yang dipakai (gratis, bisa diakses):
- Roblox API Dump: https://github.com/MaximumADHD/Roblox-Client-Tracker (file `Full-API-Dump.json`, cabang `roblox`)
- Dokumentasi resmi (sumbernya publik di https://github.com/Roblox/creator-docs):
  - Remote events: https://create.roblox.com/docs/scripting/events/remote
  - Security tactics: https://create.roblox.com/docs/scripting/security/security-tactics
  - Network ownership & movement (security): https://create.roblox.com/docs/scripting/security/network-ownership
  - Access control & decompilation: https://create.roblox.com/docs/scripting/security/access-control
  - Network ownership (physics): https://create.roblox.com/docs/physics/network-ownership
  - Script.Source: https://create.roblox.com/docs/reference/engine/classes/Script
  - Object.Changed / GetPropertyChangedSignal: https://create.roblox.com/docs/reference/engine/classes/Object
  - Animator: https://create.roblox.com/docs/reference/engine/classes/Animator
  - Secrets: https://create.roblox.com/docs/cloud-services/secrets
  - Server authority model: https://create.roblox.com/docs/projects/server-authority
  - Testing modes (toggle Client/Server): https://create.roblox.com/docs/studio/testing-modes

## 1. Data yang bisa diakses CLIENT

| Data | Catatan |
|---|---|
| Workspace (yang sudah ter-stream), ReplicatedStorage, ReplicatedFirst, Lighting, SoundService, Teams, TextChatService, StarterGui/StarterPack/StarterPlayer, Players | Dengan StreamingEnabled, jumlah Instance client lebih kecil dari server; itu normal. |
| LocalPlayer, PlayerGui, PlayerScripts, Backpack, Character milik sendiri | |
| Nama, ClassName, atribut, tag, properti yang terbaca script dari Instance Script/LocalScript/ModuleScript yang direplikasi | **Bukan** Source. |
| Event masuk Server->Client (OnClientEvent) dan BindableEvent lokal | Pasif. |
| Event keluar Client->Server, RemoteFunction, BindableFunction | Hanya bila dipanggil lewat `Net` wrapper. |
| Error/warning client: `ScriptContext.Error`, `LogService.MessageOut`, `GetLogHistory` | Hanya environment client. |
| Input lokal, Humanoid & Animator karakter sendiri | |

## 2. Data yang hanya bisa diakses SERVER

| Data | Label & sumber |
|---|---|
| ServerStorage, ServerScriptService | **[Pasti]** tidak pernah direplikasi; ModuleScript di sana tidak dapat didekompilasi client (Access control, *Script decompilation*). |
| Instance yang dikirim server tetapi tidak terlihat client tiba sebagai `nil` di client, dan sebaliknya part buatan LocalScript tiba sebagai `nil` di server | **[Pasti]** (Remote events, bagian tentang nilai yang hanya terlihat pengirim). Ini dipakai untuk verifikasi CLIENT_LOCAL vs CLIENT_REPLICATED. |
| Event Client->Server (OnServerEvent) semua pemain, error server, nilai Humanoid versi server | |
| WeaponDefinitions, AssetPolicy, ServerConfig | Sengaja disimpan di ServerStorage. |

Dashboard client menampilkan data server **hanya** sebagai jawaban InspectorBridge, bukan dengan membaca container server.

## 3. Data yang hanya bisa diperiksa melalui ROBLOX STUDIO (plugin / Command Bar)

| Data | Label & sumber |
|---|---|
| `Script.Source`, `LocalScript.Source`, `ModuleScript.Source` | **[Pasti]** Dokumentasi Script.Source: mengakses properti ini dari Script atau LocalScript menyebabkan error; bisa dibaca dari Command Bar dan lewat `ScriptEditorService:GetEditorSource()` (PluginSecurity). |
| `SurfaceAppearance.ColorMap/NormalMap/MetalnessMap/RoughnessMap` | **[Pasti]** API Dump: Read = PluginSecurity. Versi `*Content` (mis. `ColorMapContent`) Read = None, jadi runtime memakai itu. |
| Semua map `MaterialVariant` (termasuk `*Content`) | **[Pasti]** API Dump: Read = PluginSecurity. Runtime hanya mencatat keberadaannya. |
| `Instance:GetDebugId()` | **[Pasti]** API Dump: PluginSecurity. Karena itu registry ID dibuat sendiri dengan weak table. |
| Dependency `require` antar modul, asset ID di dalam kode, pola berbahaya | Dari SourceAnalyzer (analisis pola teks, bukan parser penuh). |

## 4. Data yang TIDAK dapat diamati melalui API resmi

| Hal | Label | Alternatif yang dipakai |
|---|---|---|
| Waktu pembuatan Instance | **[Kemungkinan Besar]** tidak ada anggota `Instance` di API Dump yang menyimpannya | `firstSeen` = kapan inspector pertama melihat Instance; `runtimeSpawned` = muncul setelah baseline. |
| Script/fungsi yang membuat atau mengubah suatu Instance, memutar animasi, membuat hitbox | **[Kemungkinan Besar]** tidak ada API | Korelasi timestamp (Timeline) dan heuristik jarak ("nearest character"), selalu diberi label heuristik. |
| Apakah ModuleScript sudah di-require oleh script game | **[Kemungkinan Besar]** tidak ada API | Probe `require` manual (default mati; efek samping dijelaskan). |
| Panggilan `FireServer`/`InvokeServer` dari script yang tidak memakai wrapper | **[Pasti]** callback RemoteFunction hanya satu, dan tidak ada event "remote dipanggil keluar" | Gunakan `Net`. Hooking metatable/executor sengaja tidak dipakai. |
| Perubahan CFrame/Position/velocity akibat simulasi fisika lewat `Changed`/`GetPropertyChangedSignal` | **[Pasti]** (Object, *Limitations*) | Sampling di Heartbeat (CharacterProfiler, MovementValidator). |
| Clipboard dan penulisan file dari game script | **[Pasti]** satu-satunya API clipboard di API Dump adalah `StudioService:CopyToClipboard` dengan RobloxScriptSecurity (tidak bisa dipakai game maupun plugin) | Pilih teks di TextBox lalu Ctrl+C, print ke Output, atau HTTP dari server. |
| Memori internal engine, bytecode, state VM script lain | **[Pasti]** tidak ada API | Tidak diklaim. |
| Perubahan properti oleh exploiter di client | **[Pasti]** dokumentasi keamanan: exploiter dapat mengubah WalkSpeed secara lokal tanpa memicu event dan tanpa bisa dibaca LocalScript | Deteksi client hanya untuk uji Studio. Server memvalidasi hasil gerakan (delta posisi). |

## 5. Perilaku platform yang memengaruhi desain

| Perilaku | Label & sumber | Dampak di sistem |
|---|---|---|
| Event remote tanpa handler diantrekan dan dikirim ke handler pertama yang terhubung | **[Pasti]** (Remote events, *No handler is connected*) | Listener pasif ditunda `PassiveAttachDelay` agar tidak "menelan" antrean milik script game. |
| Tabel dengan nilai `nil` di indeks harus dihindari pada remote | **[Pasti]** (Remote events) | Serializer menandai array berlubang dan tabel campuran; verifikasi replikasi memakai key string. |
| Fungsi sebagai argumen remote menjadi `nil` | **[Pasti]** (Remote events) | Serializer menandai. |
| Animasi yang dimulai client pada Animator di karakternya direplikasi ke server dan client lain | **[Pasti]** (Animator, *Loading an Animation on Client or Server*) | |
| `Animator.AnimationPlayed` ikut fire di server untuk track yang dimulai client | **[Spekulatif]** dokumentasi hanya menyebut track "created and owned by the Animator" | Uji G.6 di docs/04. |
| `Tool.Activated` fire di server | **[Kemungkinan Besar]** pola tool klasik memakai Script server; dokumentasi Tool.Activated tidak menyebut environment | Uji G.5. |
| Isi PlayerGui hanya direplikasi ke pemiliknya | **[Kemungkinan Besar]** API Dump: kelas PlayerGui bertag `PlayerReplicated` | Dasar pengiriman dashboard. Uji G.8. |
| Karakter biasanya network-owned oleh client sehingga server menerima posisi dari client | **[Pasti]** (Network ownership; Security network ownership) | MovementValidator memvalidasi delta posisi, proyeksi XZ, toleransi, dan pengecualian teleport, sesuai saran dokumentasi keamanan. |
| Exploiter dapat mereplikasi komponen Inf/NaN pada CFrame | **[Pasti]** (Security network ownership) | MovementValidator dan Schema menolak NaN/inf. |
| Server authority model (`Workspace.AuthorityMode = Server`) membuat server menyimulasikan pergerakan | **[Pasti]** (Server authority model) | Bila Anda memakainya, banyak kelas speed/fly hack tertutup di level engine; MovementValidator tetap berguna sebagai lapisan audit. |
| Secret Store: `HttpService:GetSecret` hanya untuk URL/header, bukan body | **[Pasti]** (Secrets) | AuditLog memakai secret di header Authorization. |

## 6. Hal yang sengaja tidak dilakukan

- Tidak memakai `hookmetamethod`, `getrawmetatable`, `setclipboard`, `getgc`, `decompile`, atau fungsi executor lain. Fungsi itu bukan API Roblox.
- Tidak mengklaim ekstraksi 100% memori atau source runtime.
- Tidak menjadikan LocalScript sebagai lapisan keamanan.
- Tidak menilai semua Asset ID sebagai kebocoran: aset yang dirender client memang harus bisa diunduh client.
