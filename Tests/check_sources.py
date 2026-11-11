#!/usr/bin/env python3
"""Check source registration and stale localizations without touching app data."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "FixBridge"
SOURCES = [p for p in APP.rglob("*") if p.suffix in {".swift", ".c", ".h", ".m"}]
LITERAL = r'"((?:[^"\\\n]|\\.)*)"'


def normalized(value):
    value = re.sub(r"\\\([^)]*\)", "{value}", value)
    return re.sub(r"%(?:\d+\$)?(?:lld|ld|d|@)", "{value}", value)


literals = {normalized(value) for path in SOURCES for value in re.findall(LITERAL, path.read_text())}
RESOURCES = APP / "Resources"
LANGUAGES = ("zh-Hans", "zh-HK", "zh-TW")
STRING_ENTRY = rf"^{LITERAL}\s*=\s*{LITERAL}\s*;"
FORMAT_ARGUMENT = r"%(?:\d+\$)?(?:lld|ld|d|@)"
URL = r"https?://[^)\s]+"


def read_strings(path):
    pairs = re.findall(STRING_ENTRY, path.read_text(), re.M)
    entries = dict(pairs)
    assert len(entries) == len(pairs), f"Duplicate localization keys: {path}"
    assert entries, f"No localization entries found: {path}"
    return entries


for table in ("Localizable", "InfoPlist"):
    filename = f"{table}.strings"
    reference = read_strings(RESOURCES / "zh-Hans.lproj" / filename)
    for language in LANGUAGES:
        path = RESOURCES / f"{language}.lproj" / filename
        entries = read_strings(path)
        missing = reference.keys() - entries.keys()
        extra = entries.keys() - reference.keys()
        assert not (missing or extra), f"{path}: missing {sorted(missing)}, extra {sorted(extra)}"
        for key, value in entries.items():
            assert value.strip(), f"{path}: empty translation for {key!r}"
            assert re.findall(FORMAT_ARGUMENT, key) == re.findall(FORMAT_ARGUMENT, value), \
                f"{path}: format arguments differ for {key!r}"
            assert re.findall(URL, key) == re.findall(URL, value), f"{path}: links differ for {key!r}"

keys = read_strings(RESOURCES / "zh-Hans.lproj" / "Localizable.strings")
unused = [key for key in keys if normalized(key) not in literals]
assert not unused, f"Unreferenced localization keys: {unused}"
project = (ROOT / "FixBridge.xcodeproj/project.pbxproj").read_text()
source_files = {p.name for p in SOURCES}
for path in SOURCES:
    assert path.name in project, f"Source missing from Xcode: {path}"
    if path.suffix in {".swift", ".c"}:
        assert f"{path.name} in Sources" in project, f"Source not compiled: {path}"
for name in re.findall(r"path = ([\w]+\.(?:swift|m|h|c));", project):
    assert name in source_files, f"Stale Xcode reference: {name}"
for path in SOURCES:
    assert not re.search(r"IOBluetoothDevicePair|IOBluetoothPairingController|BluetoothPairingPanel", path.read_text()), \
        f"Abandoned pairing implementation returned: {path}"
print(f"Source checks passed: {len(SOURCES)} registered files, {len(keys)} referenced localization keys across {len(LANGUAGES)} locales.")
