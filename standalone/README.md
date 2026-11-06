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
