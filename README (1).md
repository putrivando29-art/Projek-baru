# Roblox Runtime Inspector & Security Audit Dashboard

Sistem audit runtime untuk game Roblox **milik Anda sendiri**, berjalan di Play Solo, Start Server, dan Start Player di Roblox Studio. Ditulis dalam Luau, modular, disusun sebagai proyek [Rojo](https://rojo.space/docs/v7/).

> Status verifikasi: semua nama kelas, properti, event, dan level security dicek terhadap Roblox API Dump (`Full-API-Dump.json` dari [Roblox-Client-Tracker](https://github.com/MaximumADHD/Roblox-Client-Tracker)) dan dokumentasi resmi [Roblox/creator-docs](https://github.com/Roblox/creator-docs). Kode **belum dijalankan** di Roblox Studio oleh penulisnya (lingkungan pembuatan tidak punya Studio). Jalankan checklist di [docs/04-instalasi-pengujian.md](docs/04-instalasi-pengujian.md) sebelum mengandalkannya.

## Delta Android (client-only)

Versi siap-tempel Game Scanner untuk Delta Android tersedia di [`standalone/Delta.lua`](standalone/Delta.lua). Bundle memakai modul UI dan scanner yang sudah ada di `src/` dan tidak bergantung pada folder RuntimeInspectorNet di game target. Jalankan saat sudah berada di dalam game. Lihat [`standalone/README.md`](standalone/README.md) untuk cara pakai dan batasan client-only.

## Dokumen

| Bagian | File |
|---|---|
| A. Arsitektur, B. Struktur folder, C. Daftar ModuleScript | [docs/01-arsitektur.md](docs/01-arsitektur.md) |
| D. Kode lengkap | folder `src/`, `plugin/`, `examples/` (indeks per file di docs/02) |
| E. Fungsi setiap ModuleScript | [docs/02-modul.md](docs/02-modul.md) |
| Batas data client / server / Studio / tidak teramati (poin 12) | [docs/03-batasan.md](docs/03-batasan.md) |
| F. Pemasangan, G. Pengujian Play Solo & Start Server, J. Checklist | [docs/04-instalasi-pengujian.md](docs/04-instalasi-pengujian.md) |
| H. Contoh log (ilustrasi format) | [docs/05-contoh-log.md](docs/05-contoh-log.md) |
| I. Membaca laporan keamanan & memperbaiki temuan | [docs/06-laporan-keamanan.md](docs/06-laporan-keamanan.md) |

## Ringkas

```
ReplicatedStorage/RuntimeInspectorNet     Net (wrapper remote), Schema, Serializer   <- satu-satunya bagian yang direplikasi ke semua client
ServerStorage/RuntimeInspector            Shared (inspector), ServerData (rahasia), ClientPackage (dashboard), Tools (SourceAnalyzer)
ServerScriptService/RuntimeInspectorServer bootstrap, AuditLog, InspectorBridge, Security/* (SecureRemote, MovementValidator, CombatAuthority, Honeypot)
plugin/                                    plugin Studio untuk analisis Source (PluginSecurity)
```

Dashboard tidak dikirim lewat StarterPlayerScripts. Server meng-clone dashboard ke `PlayerGui` pemain yang terotorisasi saja, karena isi PlayerGui hanya direplikasi ke pemiliknya. Pemain lain tidak menerima kode inspector maupun remote-nya.

## Mulai cepat

```bash
rojo serve                                    # sync ke Studio (plugin Rojo)
rojo build plugin.project.json --plugin RuntimeInspectorAnalyzer.rbxm   # plugin Source Analyzer
```

Di Studio: tekan **Play**, lalu **F6** (atau tombol "Inspector" kiri bawah).


## Game Scanner (Delta Android)

Lihat `standalone/README.md`. `standalone/Delta.lua` menyediakan pemindaian metadata client dan ekspor JSON; data server-only tidak dapat diakses dari client.
