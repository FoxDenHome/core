from subprocess import check_call
from json import load as json_load
from os.path import join as path_join, exists
from os import makedirs
from configure.util import unlink_safe, NIX_DIR, mtik_path, ROUTERS
from yaml import safe_load as yaml_load, dump as yaml_dump
from shutil import copytree, rmtree
from typing import Any
from time import time

INTERNAL_RECORDS = None
ROOT_PATH = mtik_path("files/pdns")
OUT_PATH = mtik_path("out/pdns")

def find_record(name: str, type: str) -> dict:
    global INTERNAL_RECORDS
    name = name.removesuffix(".")
    for zone, records in INTERNAL_RECORDS.items():
        for record in records:
            recname = record["name"] + "." + zone if record["name"] != "@" else zone
            if recname == name and record["type"] == type:
                return record
    return None
def quote_record(record: dict[str, Any]) -> str:
    return f'"{record["value"]}"'
def disallow_apex_record(record: dict[str, Any]) -> list[None] | dict[str, Any]:
    if record["name"] == "@":
        return []
    return record
RECORD_TYPE_HANDLERS = {}
RECORD_TYPE_HANDLERS["MX"] = lambda record: f"{record['priority']} {record['value']}"
RECORD_TYPE_HANDLERS["SRV"] = lambda record: f"{record['priority']} {record['weight']} {record['port']} {record['value']}"
RECORD_TYPE_HANDLERS["TXT"] = quote_record
RECORD_TYPE_HANDLERS["LUA"] = quote_record
RECORD_TYPE_HANDLERS["ALIAS"] = lambda record: [find_record(record["value"], "A"), find_record(record["value"], "AAAA")]
RECORD_TYPE_HANDLERS["SOA"] = disallow_apex_record
RECORD_TYPE_HANDLERS["NS"] = disallow_apex_record

def remap_ipv6(private: str, public: str) -> str:
    public_spl = public.split(":")
    prefix = f"{public_spl[0]}:{public_spl[1]}:{public_spl[2]}:{public_spl[3][:-1]}"
    suffix = private.removeprefix("fd2c:f4cb:63be:")
    return f"{prefix}{suffix}"

def refresh_pdns():
    global INTERNAL_RECORDS
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#dns.json"])
    with open("result", "r") as file:
        INTERNAL_RECORDS = json_load(file)["records"]["internal"]
    unlink_safe("result")

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)
    copytree(ROOT_PATH, OUT_PATH, dirs_exist_ok=True)

    bind_conf = []

    has_recursor = exists(path_join(ROOT_PATH, "recursor.conf"))

    if has_recursor:
        with open(path_join(ROOT_PATH, "recursor.conf"), "r") as file:
            recursor_data = yaml_load(file)

        if "recursor" not in recursor_data:
            recursor_data["recursor"] = {}

        if "forward_zones" not in recursor_data["recursor"]:
            recursor_data["recursor"]["forward_zones"] = []

    for zone in sorted(INTERNAL_RECORDS.keys()):
        records = INTERNAL_RECORDS[zone]

        lines = [ "$INCLUDE /etc/pdns/base-rendered.db" ]
        if exists(path_join(ROOT_PATH, f"{zone}.local.db")):
            lines.append(f"$INCLUDE /etc/pdns/{zone}.local.db")
        for record in records:
            value = record["value"]
            rec_type_spl = record["type"].upper().split(" ")
            rec_type = rec_type_spl[0]

            if rec_type in RECORD_TYPE_HANDLERS:
                value = RECORD_TYPE_HANDLERS[rec_type](record)

            if not isinstance(value, list):
                value = [value]
            for val in value:
                if isinstance(val, dict):
                    lines.append(f"{record['name']} {record['ttl']} IN {val['type']} {val['value']}")
                else:
                    lines.append(f"{record['name']} {record['ttl']} IN {record['type']} {val}")

        data = "\n".join(sorted(list(set(lines)))) + "\n"
        with open(path_join(ROOT_PATH, f"gen-{zone}.db"), "w") as file:
            file.write(data)

        bind_conf.append('zone "%s" IN {' % zone)
        bind_conf.append('    type native;')
        bind_conf.append('    file "/etc/pdns/gen-%s.db";' % zone)
        bind_conf.append('};')

        if has_recursor:
            recursor_data["recursor"]["forward_zones"].append({
                "zone": zone,
                "forwarders": ["127.0.0.1:530"]
            })

    with open(path_join(ROOT_PATH, "base.db"), "r") as file:
        soa_db = file.read()
    soa_db = soa_db.replace("1111111111", str(int(time())))
    with open(path_join(OUT_PATH, "base-rendered.db"), "w") as file:
        file.write(soa_db)

    with open(path_join(OUT_PATH, "bind.conf"), "w") as file:
        file.write("\n".join(bind_conf) + "\n")

    with open(path_join(OUT_PATH, "recursor.conf"), "w") as file:
        yaml_dump(recursor_data, file)

    for router in ROUTERS:
        if router.horizon != "internal":
            continue

        print(f"## {router.host}")
        changes = router.sync(OUT_PATH, "/pdns")
        try:
            changes.remove("base-rendered.db")
        except ValueError:
            pass

        if changes:
            print("### Restarting PowerDNS container", changes)
            router.restart_container("pdns")

        for zone in sorted(INTERNAL_RECORDS.keys()):
            router.run_in_container("pdns", "pdnsutil secure-zone \'" + zone + "\'")
