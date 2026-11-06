# Game Scanner — Delta Android

File `Delta.lua` menampilkan satu tombol **SCAN GAME**. Setelah pemindaian selesai, hasil metadata client ditampilkan sebagai JSON. Gunakan **COPY** untuk menyalin (jika executor menyediakan clipboard) atau **DOWNLOAD JSON** untuk menyimpan `GameScan_<PlaceId>.json` (jika executor menyediakan `writefile`).

## Menjalankan
1. Buka game milik sendiri / game yang memang Anda berwenang uji.
2. Jalankan seluruh isi `Delta.lua` melalui executor client.
3. Tekan **SCAN GAME**, tunggu hingga selesai, lalu Copy atau Download.

## Batasan penting
Scanner hanya dapat mengumpulkan data yang direplikasi dan dapat diakses oleh client. Tidak ada cara dari LocalScript client untuk membaca seluruh isi server secara mutlak: `ServerStorage`, `ServerScriptService`, data server-only, serta source Script yang dilindungi tidak dapat diekspor. Pemindaian juga tunduk pada batas node konfigurasi dan kemampuan executor. Hasil tidak boleh dianggap sebagai dump lengkap seluruh server. Untuk inventaris lengkap game milik sendiri, tambahkan komponen server-side melalui Roblox Studio.


## Game Scanner build (Delta Android)

`Delta.lua` adalah bundle mandiri yang menggunakan modul UI, tema, serializer, explorer, dan auditor yang sudah ada di `src/`. Bundle ini tidak menunggu folder `ReplicatedStorage.RuntimeInspectorNet` di game target; dependensi tersebut dimasukkan langsung ke bundle agar tidak macet saat dijalankan di game lain.

Tekan **SCAN GAME** untuk mengumpulkan inventaris instance yang terlihat client, metadata script, atribut, tag, properti terpilih, referensi aset, dan data runtime yang tersedia. Inventaris diekspor hingga 25.000 instance per sesi untuk menjaga penggunaan memori di Android. Jika batas tercapai, laporan menandai `inventoryTruncated`. Gunakan **COPY** atau **DOWNLOAD JSON** untuk seluruh laporan; kotak di layar hanya menampilkan pratinjau agar UI tidak membeku.

Data `ServerStorage`, `ServerScriptService`, source `Script`, serta instance yang tidak direplikasi ke client tidak dapat diambil dari LocalScript/executor client. Untuk audit penuh game milik sendiri, pasang komponen server dari proyek Rojo di Roblox Studio.
