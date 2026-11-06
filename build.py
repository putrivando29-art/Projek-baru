#!/usr/bin/env python3
"""
Membangun standalone/RuntimeInspector.client.lua: satu LocalScript mandiri.

Modul client yang SUDAH ADA di src/ disalin apa adanya ke dalam fungsi loader;
hanya baris dependency yang diubah:
  - require(<path ke ModuleScript>)          -> __require("<NamaModul>")
  - local Shared = script.Parent.Parent       -> dihapus
  - local NetFolder = ...RuntimeInspectorNet  -> dihapus
Lalu standalone/StandaloneMain.luau ditambahkan di akhir.

Pemakaian (dari root repo):  python3 standalone/build.py
Jalankan ulang setiap kali modul di src/ atau StandaloneMain.luau berubah.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "standalone" / "RuntimeInspector.client.lua"
DELTA_OUT = ROOT / "standalone" / "Delta.lua"
MAIN = ROOT / "standalone" / "StandaloneMain.luau"

MODULES = {
    "Serializer": "ReplicatedStorage/RuntimeInspectorNet/Serializer.luau",
    "Schema": "ReplicatedStorage/RuntimeInspectorNet/Schema.luau",
    "Net": "ReplicatedStorage/RuntimeInspectorNet/Net.luau",
    "Config": "ServerStorage/RuntimeInspector/Shared/Config.luau",
    "Maid": "ServerStorage/RuntimeInspector/Shared/Util/Maid.luau",
    "Signal": "ServerStorage/RuntimeInspector/Shared/Util/Signal.luau",
    "RingBuffer": "ServerStorage/RuntimeInspector/Shared/Util/RingBuffer.luau",
    "RateLimiter": "ServerStorage/RuntimeInspector/Shared/Util/RateLimiter.luau",
    "Batcher": "ServerStorage/RuntimeInspector/Shared/Util/Batcher.luau",
    "Scheduler": "ServerStorage/RuntimeInspector/Shared/Util/Scheduler.luau",
    "InstanceInfo": "ServerStorage/RuntimeInspector/Shared/Core/InstanceInfo.luau",
    "AssetCatalog": "ServerStorage/RuntimeInspector/Shared/Core/AssetCatalog.luau",
    "Findings": "ServerStorage/RuntimeInspector/Shared/Core/Findings.luau",
    "Timeline": "ServerStorage/RuntimeInspector/Shared/Core/Timeline.luau",
    "DataModelExplorer": "ServerStorage/RuntimeInspector/Shared/Inspectors/DataModelExplorer.luau",
    "ScriptInspector": "ServerStorage/RuntimeInspector/Shared/Inspectors/ScriptInspector.luau",
    "AssetAuditor": "ServerStorage/RuntimeInspector/Shared/Inspectors/AssetAuditor.luau",
    "InstanceMonitor": "ServerStorage/RuntimeInspector/Shared/Inspectors/InstanceMonitor.luau",
    "CharacterProfiler": "ServerStorage/RuntimeInspector/Shared/Inspectors/CharacterProfiler.luau",
    "NetworkMonitor": "ServerStorage/RuntimeInspector/Shared/Inspectors/NetworkMonitor.luau",
    "AnomalyDetector": "ServerStorage/RuntimeInspector/Shared/Inspectors/AnomalyDetector.luau",
    "ExportCenter": "ServerStorage/RuntimeInspector/ClientPackage/ExportCenter.luau",
    "Theme": "ServerStorage/RuntimeInspector/ClientPackage/UI/Theme.luau",
    "Widgets": "ServerStorage/RuntimeInspector/ClientPackage/UI/Widgets.luau",
    "VirtualList": "ServerStorage/RuntimeInspector/ClientPackage/UI/VirtualList.luau",
    "TreeView": "ServerStorage/RuntimeInspector/ClientPackage/UI/TreeView.luau",
    "ListDetailView": "ServerStorage/RuntimeInspector/ClientPackage/UI/ListDetailView.luau",
}

DROP_LINE = [
    re.compile(r"^local Shared = script\.Parent\.Parent\s*$"),
    re.compile(r'^local NetFolder = .*WaitForChild\("RuntimeInspectorNet"\)\s*$'),
]

# Standalone bundle harus memakai modul yang sudah dibundel, bukan menunggu folder
# RuntimeInspectorNet di game target (folder itu biasanya memang tidak ada).
STANDALONE_LINE_REWRITES = {
    'local Serializer = require(game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))': 'local Serializer = __require("Serializer")',
    'local Schema = require(NetFolder:WaitForChild("Schema"))': 'local Schema = __require("Schema")',
    'local Net = require(NetFolder:WaitForChild("Net"))': 'local Net = __require("Net")',
}
NAME_AT_END = re.compile(r'([A-Za-z_]\w*)"?\)?\s*$')
REQ_CALL = re.compile(r"__require\(\"(\w+)\"\)")


def rewrite_requires(line: str, where: str) -> str:
    out, i = "", 0
    while True:
        j = line.find("require(", i)
        if j < 0 or (j > 0 and (line[j - 1].isalnum() or line[j - 1] == "_")):
            return out + line[i:] if j < 0 else out + line[i : j + 8] + rewrite_requires(line[j + 8 :], where)
        depth, k = 0, j + 7
        while k < len(line):
            depth += line[k] == "("
            depth -= line[k] == ")"
            if depth == 0:
                break
            k += 1
        inner = line[j + 8 : k]
        m = NAME_AT_END.search(inner)
        if not m or m.group(1) not in MODULES:
            sys.exit(f"{where}: require tidak dikenal: require({inner})")
        out += line[i:j] + f'__require("{m.group(1)}")'
        i = k + 1


def transform(text: str, where: str) -> str:
    lines, in_block = [], False
    for n, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if in_block:
            in_block = "]]" not in line
            lines.append(line)
            continue
        if stripped.startswith("--[["):
            in_block = "]]" not in stripped[4:]
            lines.append(line)
            continue
        if any(p.match(line) for p in DROP_LINE):
            lines.append("-- [standalone] " + stripped)
            continue
        if stripped in STANDALONE_LINE_REWRITES:
            lines.append(STANDALONE_LINE_REWRITES[stripped])
            continue
        if "require(" in line and not stripped.startswith("--"):
            line = rewrite_requires(line, f"{where}:{n}")
        lines.append(line)
    return "\n".join(lines).rstrip()


def main() -> None:
    main_src = MAIN.read_text(encoding="utf-8")
    needed, order, queue = set(), [], REQ_CALL.findall(main_src)
    bodies = {}
    while queue:
        name = queue.pop(0)
        if name in needed:
            continue
        if name not in MODULES:
            sys.exit(f"modul tidak terdaftar: {name}")
        needed.add(name)
        body = transform((SRC / MODULES[name]).read_text(encoding="utf-8"), MODULES[name])
        bodies[name] = body
        queue.extend(REQ_CALL.findall(body))
    order = [n for n in MODULES if n in needed]

    try:
        rev = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        rev = "unknown"

    parts = [
        "--[[",
        "\tRuntimeInspector Standalone Client (LocalScript)",
        "\tFILE INI DIHASILKAN OTOMATIS oleh standalone/build.py dari modul di src/ (commit " + rev + ").",
        "\tJangan edit langsung: ubah src/ atau standalone/StandaloneMain.luau lalu build ulang.",
        "",
        "\tPasang: StarterPlayer > StarterPlayerScripts > LocalScript, tempel seluruh isi file ini.",
        "\tDefault hanya aktif di Roblox Studio. Tekan F7 untuk tampil/sembunyi.",
        "\tModul: " + ", ".join(order),
        "]]",
        "",
        "local __modules = {}",
        "local __cache = {}",
        "",
        "-- Integrasi opsional: bila repo utama terpasang, pakai Net milik game agar panggilan",
        "-- Net.FireServer dari script game ikut tercatat. Tanpa itu, Net internal yang dipakai.",
        "local function __external(name)",
        '\tif name ~= "Net" then',
        "\t\treturn nil",
        "\tend",
        '\tlocal folder = game:GetService("ReplicatedStorage"):FindFirstChild("RuntimeInspectorNet")',
        '\tlocal m = folder and folder:FindFirstChild("Net")',
        '\tif m and m:IsA("ModuleScript") then',
        "\t\tlocal ok, v = pcall(require, m)",
        "\t\tif ok then",
        "\t\t\treturn v",
        "\t\tend",
        "\tend",
        "\treturn nil",
        "end",
        "",
        "local function __require(name)",
        "\tlocal cached = __cache[name]",
        "\tif cached ~= nil then",
        "\t\treturn cached",
        "\tend",
        "\tlocal value = __external(name)",
        "\tif value == nil then",
        "\t\tlocal loader = __modules[name]",
        "\t\tif not loader then",
        '\t\t\terror("[RuntimeInspector] modul tidak ada di bundle: " .. tostring(name), 2)',
        "\t\tend",
        "\t\tvalue = loader()",
        "\tend",
        "\t__cache[name] = value",
        "\treturn value",
        "end",
        "",
    ]
    for name in order:
        parts.append(f"-- ===== {name} ({MODULES[name]}) =====")
        parts.append(f"__modules.{name} = function()")
        parts.append(bodies[name])
        parts.append("end")
        parts.append("")
    parts.append("-- ===== StandaloneMain (standalone/StandaloneMain.luau) =====")
    parts.append(main_src.rstrip())
    out = "\n".join(parts) + "\n"

    leftovers = [l for l in out.split("\n") if ("script.Parent" in l or 'WaitForChild("RuntimeInspectorNet")' in l) and not l.strip().startswith("--")]
    if leftovers:
        sys.exit("sisa dependency eksternal:\n" + "\n".join(leftovers))
    OUT.write_text(out, encoding="utf-8")

    # File siap-tempel untuk executor Android. Kode inti identik dengan standalone;
    # hanya petunjuk header yang dibedakan. Tidak membutuhkan loadstring/HTTP.
    delta_out = out.replace(
        "RuntimeInspector Standalone Client (LocalScript)",
        "RuntimeInspector Delta Android (client-side)"
    ).replace(
        "Pasang: StarterPlayer > StarterPlayerScripts > LocalScript, tempel seluruh isi file ini.",
        "Delta Android: tempel seluruh isi file ini ke editor executor saat sudah berada di dalam game, lalu Execute."
    ).replace(
        "Default hanya aktif di Roblox Studio. Tekan F7 untuk tampil/sembunyi.",
        "Client-only. UI dapat dibuka melalui tombol Inspector di layar."
    )
    DELTA_OUT.write_text(delta_out, encoding="utf-8")
    print(f"OK {OUT.relative_to(ROOT)}: {len(order)} modul, {out.count(chr(10))} baris, {len(out)} byte")
    print(f"OK {DELTA_OUT.relative_to(ROOT)}: {delta_out.count(chr(10))} baris, {len(delta_out)} byte")


if __name__ == "__main__":
    main()
