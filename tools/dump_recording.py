"""Extract Combat Helper recorder logs from the client's plugin database.

Usage: python dump_recording.py [output_dir] [--ui]
Reads the combat-helper data from every PluginData.db under the RuneScape-BETA folder (or RS3_BETA_ROOT) (read-only) and
writes one file per recorder slot: recording_slot<N>.log. The newest slot is
also written to recording.log. --ui also writes the last UI scan (taken when AUTO starts) to
ui_scan.log (it holds everything on screen: don't share it).
"""
import glob
import os
import re
import sqlite3
import struct
import sys

# Default beta client folder; set RS3_BETA_ROOT if yours is elsewhere
BETA_ROOT = os.environ.get("RS3_BETA_ROOT", r"C:\ProgramData\Jagex\RuneScape-BETA")
TYPE_FLOAT = 2  # DataStore.Type for numbers: 4-byte little-endian float
PLUGIN_ID = "combat-helper"  # plugin.json name; other plugins' data is skipped
SLOT_KEY = re.compile(r"^rec(\d+)_(\d+|chunks)$")
SCAN_PREFIX = "uiscan_"


def as_text(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def as_number(value_type, value):
    if value_type == TYPE_FLOAT and isinstance(value, bytes) and len(value) == 4:
        return struct.unpack("<f", value)[0]
    return float(as_text(value))


def read_store():
    """Yield (db_path, plugin_id, {key: (type, value)}) for each plugin."""
    for db_path in glob.glob(os.path.join(BETA_ROOT, "**", "PluginData.db"), recursive=True):
        uri = "file:" + db_path.replace("\\", "/") + "?mode=ro"
        try:
            conn = sqlite3.connect(uri, uri=True)
            rows = conn.execute("SELECT PluginID, Key, Type, Value FROM DataStore WHERE Key LIKE 'rec%' OR Key LIKE 'uiscan%'").fetchall()
        except sqlite3.Error as error:
            print(f"skip {db_path}: {error}")
            continue
        by_plugin = {}
        for plugin_id, key, value_type, value in rows:
            by_plugin.setdefault(plugin_id, {})[key] = (value_type, value)
        if PLUGIN_ID in by_plugin:
            yield db_path, PLUGIN_ID, by_plugin[PLUGIN_ID]


def main():
    args = [a for a in sys.argv[1:] if a != "--ui"]
    want_ui = "--ui" in sys.argv[1:]
    out_dir = args[0] if args else os.path.dirname(os.path.abspath(__file__))
    written = 0
    for db_path, plugin_id, keys in read_store():
        if want_ui and SCAN_PREFIX + "chunks" in keys:
            chunks = int(as_number(*keys[SCAN_PREFIX + "chunks"]))
            text = "\n".join(as_text(keys[f"{SCAN_PREFIX}{i}"][1]) for i in range(1, chunks + 1)
                             if f"{SCAN_PREFIX}{i}" in keys)
            with open(os.path.join(out_dir, "ui_scan.log"), "w", encoding="utf-8") as out:
                out.write(text + "\n")
            print(f"[{plugin_id}] UI scan: {text.count(chr(10)) + 1} lines -> ui_scan.log")
        newest = int(as_number(*keys["rec_last"])) if "rec_last" in keys else None
        slots = sorted({int(m.group(1)) for m in map(SLOT_KEY.match, keys) if m})
        for slot in slots:
            chunks = int(as_number(*keys[f"rec{slot}_chunks"])) if f"rec{slot}_chunks" in keys else 0
            text = "\n".join(as_text(keys[f"rec{slot}_{i}"][1]) for i in range(1, chunks + 1)
                             if f"rec{slot}_{i}" in keys)
            if not text:
                continue
            names = [f"recording_slot{slot}.log"] + (["recording.log"] if slot == newest else [])
            for name in names:
                with open(os.path.join(out_dir, name), "w", encoding="utf-8") as out:
                    out.write(text + "\n")
            tag = " (newest)" if slot == newest else ""
            print(f"[{plugin_id}] slot {slot}{tag}: {text.count(chr(10)) + 1} lines -> {names[0]}")
            written += 1
    if written == 0:
        print("no recording found")


if __name__ == "__main__":
    main()
