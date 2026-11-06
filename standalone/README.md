# Standalone Client Inspector

`RuntimeInspector.client.lua` adalah satu LocalScript mandiri. Isinya modul client yang sudah ada di `src/` (disalin apa adanya oleh `build.py`, hanya `require` yang diganti loader internal) ditambah `StandaloneMain.luau` (agent client, jendela floating, 8 tab, tombol Start/Stop/Refresh/Copy/Export).

## Pasang
1. Studio > StarterPlayer > StarterPlayerScripts > Insert **LocalScript**.
2. Tempel seluruh isi `RuntimeInspector.client.lua`.
3. Play. Tekan **F7** untuk tampil/sembunyi.

Default hanya aktif di Studio (`ALLOW_IN_LIVE_GAME = false` di bagian akhir file). StarterPlayerScripts dikirim ke semua pemain, jadi kode ini bisa dibaca siapa pun bila diaktifkan di live.

## Build ulang
```bash
python3 standalone/build.py
```
Wajib setelah mengubah modul di `src/` atau `StandaloneMain.luau`.

## Yang tidak ada di versi standalone (keterbatasan client, bukan bug)
| Fitur | Alasan |
|---|---|
| Isi ServerStorage / ServerScriptService | Tidak direplikasi ke client. |
| Verifikasi CLIENT_LOCAL vs CLIENT_REPLICATED, divergence check | Butuh jawaban server (InspectorBridge). |
| Source script | ProtectedString; hanya plugin/Command Bar. |
| Panggilan Client->Server dari script game | Hanya terlihat bila game memakai `ReplicatedStorage.RuntimeInspectorNet.Net` (otomatis dipakai bila ada). |
| Clipboard | Tidak ada API resmi; Copy/Export memilih teks, lalu tekan Ctrl+C. |
| Penegakan keamanan | Client tidak otoritatif; temuan hanya indikator. |


## Delta Android (client-only)

Gunakan `Delta.lua` jika ingin menjalankan inspector sebagai script client dari Delta Android:

1. Buka Roblox dan masuk ke game milik Anda sendiri.
2. Buka Delta Android, buat/buka editor script, lalu tempel seluruh isi `Delta.lua`.
3. Tekan **Execute**. Panel **Runtime Inspector** akan muncul; tombol `×` menutup panel dan tombol `Inspector` membukanya kembali.
4. Tab dapat digeser horizontal pada layar sempit.

`Delta.lua` dibangun otomatis dari modul di `src/` dan `StandaloneMain.luau`. Setelah mengubah salah satunya, jalankan `python3 standalone/build.py` dari root repository untuk membangun ulang kedua file standalone.

**Batasan:** ini berjalan di sisi client. Script ini tidak dapat membaca isi `ServerStorage` atau `ServerScriptService`, source script yang dilindungi, maupun data server yang tidak direplikasi. Fitur yang memerlukan server atau plugin Studio tetap hanya tersedia pada pemasangan Studio penuh. API executor berbeda antarversi; GUI mencoba `gethui()` bila tersedia dan fallback ke `PlayerGui`.
