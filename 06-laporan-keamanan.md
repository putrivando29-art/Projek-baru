# I. Membaca Laporan Keamanan dan Memperbaiki Temuan

## 1. Urutan membaca

1. **Pisahkan sumber.** Tab Security, filter "Server" dulu. Temuan server berbasis state server dan bisa dipercaya. Temuan "Client" berasal dari client admin; di Studio berguna untuk menguji, tetapi dokumentasi keamanan Roblox menyatakan exploiter dapat mengubah properti lokal tanpa memicu event, jadi deteksi client tidak boleh menjadi dasar hukuman.
2. **Urutkan severity.** CRITICAL lalu HIGH. Kolom `x<count>` menunjukkan berapa kali temuan sama digabung dalam `DedupeWindow` (default 30 detik).
3. **Baca `detail`, `alasan`, `rekomendasi`.** Setiap temuan menyertakan ketiganya.
4. **Korelasikan.** Untuk temuan movement atau combat, buka Action Profiler (mode Rantai, env yang sama) di sekitar `serverTime` temuan.
5. **Risk score** = `min(100, Σ bobot(severity) × (1 + log2(count)))`, bobot INFO 0, LOW 1, MEDIUM 3, HIGH 7, CRITICAL 15. Ini **heuristik sistem ini**, bukan standar industri. Gunakan untuk membandingkan sesi uji sebelum dan sesudah perbaikan, bukan sebagai angka absolut.

## 2. Katalog rule

### Server (otoritatif)

| Rule | Severity | Arti | Perbaikan |
|---|---|---|---|
| `honeypot.triggered` | CRITICAL | Remote umpan dipanggil. Kode game sah tidak pernah memanggilnya. | Tinjau pemain. Pertimbangkan `Security.Enforcement = "kick"` di live. Jangan beri umpan balik ke client. |
| `combat.damage_exceeds_global` | CRITICAL | Damage > `GlobalMaxDamage`. | Telusuri sumber angka; semua damage harus lewat `CombatAuthority:ValidateDamage`. |
| `movement.non_finite_position` | CRITICAL | Posisi HRP NaN/inf. | Kembalikan ke posisi valid/respawn. Jangan gunakan posisi itu. |
| `remote.schema_violation` | HIGH | Argumen di luar kontrak Schema. | Pertahankan penolakan. Bila client resmi Anda yang mengirim, perbaiki client atau skema. |
| `remote.payload_too_large` | HIGH | Estimasi payload > batas. | Kirim ID/enum, bukan data mentah. |
| `movement.teleport` | HIGH | Lompatan posisi (XZ + naik) > `TeleportDistance`. | Teleport sah: panggil `MovementValidator:AllowTeleport(player, detik)` sebelum memindahkan. |
| `movement.speed` | MEDIUM, HIGH bila ≥ `ViolationsForHigh` dalam `ViolationWindow` | Kecepatan horizontal > WalkSpeed server × toleransi + buffer. | Sprint/dash sah harus mengubah WalkSpeed **di server** atau memanggil `AllowTeleport`. Naikkan `SpeedTolerance` hanya bila false positive terbukti (misal lag). |
| `movement.vertical` | MEDIUM/HIGH | Kenaikan > tinggi lompatan server + buffer. | Jump pad/launcher sah: `AllowTeleport` singkat sebelum melontarkan. |
| `remote.rate_limited` | MEDIUM | Melebihi token bucket. | Cari loop di client. Atur `rate` per remote. |
| `remote.replay` | MEDIUM | `seq` tidak naik atau `sentAt` di luar jendela. | Client harus memakai `Net.FireServerSecure`. Ingat: ini hanya menahan replay naif. |
| `combat.cooldown_bypass` | MEDIUM | Serangan lebih cepat dari cooldown server. | Pertahankan; tampilkan cooldown di client hanya sebagai UX. |
| `combat.attack_while_stunned` | MEDIUM | Serangan saat atribut `Stunned` aktif di server. | Pastikan UI client juga mengunci input saat stun. |
| `combat.no_weapon` | MEDIUM | Attack tanpa Tool terdaftar terpasang. | Samakan `Tool.Name` dengan key `WeaponDefinitions`. |
| `combat.aim_angle` | LOW | Arah bidik jauh dari arah hadap server. | Bila sering pada satu pemain, kemungkinan arah dipalsukan; turunkan `MaxAimAngleDeg`. |
| `remote.handler_error` | LOW | Handler remote error (traceback di detail). | Perbaiki handler; error yang bisa dipicu input client adalah celah. |
| `inspector.foreign_caller` | HIGH | Pemain memanggil remote inspector milik admin lain. | Tinjau pemain; remote itu tidak direplikasi ke pemain lain dalam kondisi normal. |
| `network.rate_exceeded` | MEDIUM/HIGH | Frekuensi > `DefaultRateLimit`/`PerRemoteRateLimit` (pengamatan pasif). | Bind remote dengan SecureRemote dan rate limit yang sesuai. |
| `network.invalid_payload` | MEDIUM | NaN/inf, tabel campuran, fungsi, metatable dalam payload. | Validasi dengan Schema di server. |
| `movement.position_jump` | HIGH | CharacterProfiler server melihat lompatan posisi yang tidak dijelaskan velocity. | Sama dengan `movement.teleport`. |
| `movement.walkspeed_change` | MEDIUM/HIGH | WalkSpeed server diubah ke nilai di luar `AllowedWalkSpeeds`. | Tambahkan nilai sah ke daftar, atau perbaiki script yang mengubahnya. |
| `combat.hitbox_oversize` | HIGH | Part hitbox (nama/tag) melebihi `MaxHitboxSize`. | Ambil ukuran dari `WeaponDefinitions` server. |
| `runtime.mover_in_character` | MEDIUM | BodyVelocity/LinearVelocity/dll. muncul di karakter. | Daftarkan mover sah di `AllowedMoverNames`. |
| `asset.unknown_runtime` | MEDIUM | Aset baru saat gameplay, tidak ada di baseline/allowlist. | Tambahkan ke `AssetPolicy.RuntimeAllowlist` bila sah. |
| `attribute.protected_changed` | LOW | Atribut di `ProtectedAttributes` berubah. | Pastikan hanya server yang mengubahnya. |
| `script.error` | LOW/MEDIUM (burst) | Error script. | Lihat stack trace di Scripts > Error. |

### Client (indikator, untuk uji Studio)

| Rule | Severity | Arti |
|---|---|---|
| `verify.client_server_divergence` | HIGH | Nilai Humanoid/atribut terlindungi di client berbeda dari server pada dua pengecekan berturut-turut. Di Studio, ini berarti Anda (atau script lokal) mengubahnya secara lokal. |
| `movement.walkspeed_change`, `movement.jumppower_exceeds`, `movement.jumpheight_exceeds` | MEDIUM/HIGH | Properti Humanoid berubah di client. |
| `movement.position_jump` | MEDIUM | Lompatan posisi terlihat di client. |
| `combat.hitbox_oversize`, `runtime.mover_in_character`, `combat.tool_during_cooldown` | HIGH/MEDIUM/LOW | Sama seperti di server, tetapi untuk Instance yang terlihat/dibuat di client (hitbox lokal tidak direplikasi ke server). |
| `network.*`, `script.error`, `asset.unknown_runtime` | | Versi client dari rule yang sama. |

Temuan client HIGH/CRITICAL dikirim ke server dan muncul di laporan server dengan `source = "client-reported (tidak terpercaya)"`.

## 3. Penilaian aset (Asset Inspector)

| Level | Arti | Tindakan |
|---|---|---|
| INFO | Wajar: client harus mengunduh aset untuk merender, atau aset hanya di container server. | Tidak ada. |
| LOW | Hanya di ReplicatedStorage/Starter*: semua client menerimanya sebelum dipakai. | Bila konten belum rilis: pindahkan ke ServerStorage dan clone saat dibutuhkan. |
| MEDIUM | Muncul saat runtime dan tidak dikenal. | Verifikasi sumbernya; tambah allowlist bila sah. |
| HIGH | Ada di `AssetPolicy.Sensitive` tetapi berada di container yang direplikasi. | Pindahkan ke ServerStorage. |

Tab "Di source": ID aset yang tertulis di kode. ID di ModuleScript/LocalScript yang direplikasi ikut terkirim ke client sebagai bytecode yang dapat didekompilasi.

## 4. Peringatan Source Analyzer

| Peringatan | Tindakan |
|---|---|
| `require(<angka>)` | Memuat modul dari asset ID. Pastikan milik Anda; kalau tidak, ini pola backdoor umum. |
| `loadstring` | Pastikan `ServerScriptService.LoadStringEnabled` mati bila tidak diperlukan. |
| `getfenv/setfenv` | Sering dipakai obfuscation; telusuri asal script. |
| `OnServerEvent menerima parameter 'damage'` (atau speed, cframe, price, ...) | Server harus menghitung nilai itu sendiri. Lihat CombatAuthority sebagai pola. |
| `LocalScript mengubah Health/TakeDamage` | Pindahkan logika damage ke server. |
| `InsertService:LoadAsset` | Pastikan aset yang dimuat milik Anda. |

## 5. Siklus perbaikan

1. Ekspor JSON (Export Center > Laporan lengkap server) sebagai baseline.
2. Perbaiki temuan CRITICAL/HIGH server.
3. Ulangi skenario docs/04 G.3.
4. Bandingkan jumlah temuan dan risk score dengan baseline.
5. Setelah stabil, isi `AdminUserIds` dan uji di server privat sebelum `EnableInLiveGame = true`.
