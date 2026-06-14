#!/usr/bin/env python3
import json
from urllib import request
from os import path

# This script is used to enhance the mod-list.json file with hashes for each mod, so that we can download the correct version of each mod when installing them.
FILE = path.join(path.dirname(__file__), "mod-list.json")

INTERNAL_MODS = {
    "base",
    "elevated-rails",
    "quality",
    "space-age"
}

with open(FILE, "r") as f:
    mod_list = json.load(f)

def get_mod_info(mod_name):
    url = f"https://mods.factorio.com/api/mods/{mod_name}"
    with request.urlopen(url) as response:
        return json.loads(response.read())

def get_mod_latest_release(mod_info):
    return mod_info["releases"][-1]

for mod in mod_list["mods"]:
    if mod["name"] in INTERNAL_MODS:
        continue

    if not mod["enabled"]:
        continue

    mod_info = get_mod_info(mod["name"])
    release = get_mod_latest_release(mod_info)
    mod["sha1"] = release["sha1"]
    mod["url"] = f"https://mods.factorio.com{release['download_url']}"
    mod["version"] = release["version"]

with open(FILE, "w") as f:
    json.dump(mod_list, f, indent=4)
