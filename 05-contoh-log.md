# H. Contoh Hasil Log

**Penting:** semua contoh di halaman ini adalah **ilustrasi format**. Strukturnya diturunkan langsung dari string format di kode (`Timeline.FormatChain`, `NetworkMonitor.FormatEntry`, `ExportCenter.ToTXT`, `RuntimeTab`), tetapi angka waktu, nama pemain, dan nilai lainnya adalah contoh rekaan untuk menunjukkan bentuk keluaran. Ini **bukan** hasil tangkapan dari sesi Studio nyata. Jalankan skenario di docs/04 untuk melihat log asli game Anda.

## 1. Karakter melompat (Action Profiler, mode "Rantai", Client)

Format: `Timeline.FormatChain` = `[t=<os.clock>] ANCHOR <kind> :: <ringkasan>` lalu baris `<offset ms> <kategori> <jenis> <ringkasan>`.

```
[t=812.430] ANCHOR Input.JumpBegan :: Space
      +2 ms  Jump       Humanoid.Jumping         Player1 jumping
      +2 ms  Jump       Humanoid.StateChanged    Player1 Running -> Jumping
     +18 ms  Movement   Humanoid.Running         Player1 running speed=0.00
    +317 ms  Jump       Humanoid.StateChanged    Player1 Jumping -> Freefall
    +598 ms  Jump       Humanoid.StateChanged    Player1 Freefall -> Landed
```

Cara membaca: offset relatif terhadap anchor. Urutan ini menunjukkan input diterima, Humanoid masuk state Jumping, lalu Freefall dan Landed. Ini korelasi waktu, bukan bukti kausal.

## 2. Menyerang dengan Tool (Client lalu Server)

Client, mode "Rantai":
```
[t=820.112] ANCHOR Input.AttackBegan :: MouseButton1
      +1 ms  Tool       Tool.Activated           Player1 activate ExampleSword
      +1 ms  Network    Remote.Client->Server    Client->Server CombatRequest argc=4
      +3 ms  Animation  Animator.AnimationPlayed Player1 play Animation id=rbxassetid://<ID Anda> prio=Enum.AnimationPriority.Action speed=1.00
     +97 ms  Attack     Combat.Attribute         Player1 Player1.ComboIndex nil -> 1
    +124 ms  Animation  AnimationTrack.Sample    Player1 Animation weight=1.00 playing=true
```
`Combat.Attribute ComboIndex` datang dari server (CombatAuthority men-set atribut, lalu direplikasi). Selisih ±100 ms tersebut mencakup latensi jaringan pulang-pergi.

Server, Security > "Log audit server":
```
  821.034 combat.hit             Player1 -> Dummy 12.0 dmg (combo 1, dist 4.2)
  821.034 combat.attack          Player1 attack ExampleSword combo=1 targets=1
```

## 3. Menggunakan Tool (Action Profiler, kategori Tool)

Format baris: `%9.3f %-10s %-26s %s`
```
  819.870 Tool       Tool.Equipped              Player1 equip ExampleSword
  820.113 Tool       Tool.Activated             Player1 activate ExampleSword
  820.290 Tool       Tool.Deactivated           Player1 deactivate ExampleSword
  825.004 Tool       Tool.Activated             Player1 activate ExampleSword [cooldown aktif: Player1.Stunned=true]
```
Baris terakhir juga menghasilkan temuan `combat.tool_during_cooldown` (LOW) di client.

## 4. Menerima RemoteEvent (Network Monitor, detail entri, Client)

Format: `NetworkMonitor.FormatEntry`.
```
Remote    : RoundState (RemoteEvent)
FullName  : ReplicatedStorage.GameRemotes.RoundState
Direction : Server->Client
Via       : passive   Env: client
Time      : os.clock=830.551  serverTime=1762448130.212
Player    : -
ArgCount  : 2   ~bytes(estimasi): 37
ArgTypes  : string, table

[Payload]
arg1:
  "Intermission"
arg2:
  {dict, n=2}
    [timeLeft] = 15
    [spawn] = Vector3(0, 5, 0)
```

Contoh payload bermasalah (server, Client->Server):
```
[Masalah payload]
  - arg2: Vector3 berisi NaN/inf
  - arg3: tabel campuran (array + dictionary): sebagian entri bisa hilang saat dikirim via remote
```

## 5. Runtime Monitor

Format baris: `%9.3f %-9s %-16s %s%s`
```
  833.420 added     Part             Workspace.Hitbox
  833.420 property  Humanoid         Workspace.Player1.Humanoid WalkSpeed: 16 -> 80
  833.902 attribute Model            Workspace.Player1 Stunned: nil -> true
  834.100 removed   Part             Workspace.Hitbox
```

## 6. Temuan keamanan (Export TXT)

Format: `ExportCenter.ToTXT`.
```
== FINDINGS (server) ==
[CRITICAL] honeypot.triggered x1 :: ReplicatedStorage.GameRemotes.AdminGiveCurrency#Player1
   detail : Player1 memanggil remote umpan AdminGiveCurrency dengan 1 argumen: 99999
   alasan : Remote ini tidak dipakai oleh kode game. Pemanggilan berarti client menjalankan kode di luar game resmi.
   saran  : Tinjau pemain ini. Di game live, pertimbangkan Enforcement='kick'. Jangan beri tahu client bahwa honeypot terpicu.
[HIGH] movement.teleport x1 :: Players.Player1
   detail : 587.3 studs dalam 0.25s
   ...
```
