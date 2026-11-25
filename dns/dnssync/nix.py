"""Reads the JSON flake outputs of ../nix"""

import json
from pathlib import Path
from subprocess import check_output
from typing import Any

NIX_DIR = Path(__file__).resolve().parent.parent.parent / "nix"


def load_json(output: str) -> Any:
    """Builds the flake output <output> (e.g. dns.json) and parses it"""
    path = check_output(
        ["nix", "build", f"{NIX_DIR}#{output}", "--no-link", "--print-out-paths"],
        text=True,
    ).strip()
    with open(path) as f:
        return json.load(f)
