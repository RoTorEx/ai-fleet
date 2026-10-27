#!/usr/bin/env python3
"""Require byte-for-byte upstream sources; integration belongs in the adapter."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "SessionEngine"
pin = json.loads((root / "upstream.json").read_text())
for name, expected in pin["files"].items():
    actual = hashlib.sha256((root / "vendor" / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"Vendored upstream changed: {name}. Update the pin from reviewed Hub sources.")
print(f"Session Hub source pin verified: {pin['revision']}")
