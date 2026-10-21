#!/usr/bin/env python3
"""Render an immutable application release without reading credentials."""
import json
import re
import sys
from pathlib import Path

image = sys.argv[1] if len(sys.argv) == 2 else ""
if not re.fullmatch(r"ghcr\.io/jeethsuresh/spacetime@sha256:[a-f0-9]{64}", image):
    sys.exit("usage: render.py ghcr.io/jeethsuresh/spacetime@sha256:<64 hex digits>")
resources = json.loads(Path(__file__).with_name("resources.json").read_text())
for item in resources["items"]:
    if item["kind"] == "Deployment":
        item["spec"]["template"]["spec"]["containers"][0]["image"] = image
json.dump(resources, sys.stdout, indent=2)
print()
