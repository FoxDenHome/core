from subprocess import check_call, check_output
from json import load as json_load, loads as json_loads
from os.path import join as path_join
from os import makedirs
from configure.util import unlink_safe, NIX_DIR, mtik_path, ROUTERS
from yaml import safe_load as yaml_load, dump as yaml_dump
from shutil import copytree, rmtree
from typing import Any, cast
from time import time

INTERNAL_RECORDS: dict[str, Any] | None = None
ROOT_PATH = mtik_path("files/pdns")
OUT_PATH = mtik_path("out/pdns")


def find_record(name: str, type: str) -> dict | None:
    global INTERNAL_RECORDS
    assert INTERNAL_RECORDS is not None
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


def handle_alias(record: dict[str, Any]) -> list[dict[str, Any] | None]:
    results = [find_record(record["value"], "A"), find_record(record["value"], "AAAA")]
    for result in results:
        if result is not None:
            return results
    record["type"] = "CNAME"
    return [record]


RECORD_TYPE_HANDLERS = {}
RECORD_TYPE_HANDLERS["MX"] = lambda record: f"{record['priority']} {record['value']}"
RECORD_TYPE_HANDLERS["SRV"] = (
    lambda record: f"{record['priority']} {record['weight']} {record['port']} {record['value']}"
)
RECORD_TYPE_HANDLERS["SSHFP"] = (
    lambda record: f"{record['algorithm']} {record['fptype']} {record['value']}"
)
RECORD_TYPE_HANDLERS["TXT"] = quote_record
RECORD_TYPE_HANDLERS["LUA"] = quote_record
RECORD_TYPE_HANDLERS["CNAME"] = lambda record: f"{record['value'].removesuffix('.')}."
RECORD_TYPE_HANDLERS["ALIAS"] = handle_alias
RECORD_TYPE_HANDLERS["SOA"] = disallow_apex_record
RECORD_TYPE_HANDLERS["NS"] = disallow_apex_record

def remap_ipv6(private: str, public: str) -> str:
    public_spl = public.split(":")
    prefix = f"{public_spl[0]}:{public_spl[1]}:{public_spl[2]}:{public_spl[3][:-1]}"
    suffix = private.removeprefix("fd2c:f4cb:63be:")
    return f"{prefix}{suffix}"

def resolve_record(record: dict[str, Any]) -> str:
    if 'zone' not in record:
        return record['name']
    if record["name"] == "@":
        return record["zone"]
    return f"{record['name']}.{record['zone']}"

def refresh_pdns():
    global INTERNAL_RECORDS
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#dns.json"])
    with open("result", "r") as file:
        INTERNAL_RECORDS = cast(dict[str, list[Any]], json_load(file)["records"]["internal"])
    unlink_safe("result")

    additional_records = json_loads(check_output(
        ["tofu", "output", "-show-sensitive", "-json"], cwd="../terraform"
    ).decode("utf-8"))["generated_records"]["value"]
    for zone, records in additional_records.items():
        # Assume zone exists, makes no sense otherwise
        INTERNAL_RECORDS[zone] += records

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)
    copytree(ROOT_PATH, OUT_PATH, dirs_exist_ok=True)

    bind_conf = []

    mikrotik_records = []

    for zone in sorted(INTERNAL_RECORDS.keys()):
        records = INTERNAL_RECORDS[zone]

        lines = ["$INCLUDE /etc/pdns/base-rendered.db"]

        for record in records:
            value = record["value"]
            rec_type_spl = record["type"].upper().split(" ")
            rec_type = rec_type_spl[0]

            if rec_type in RECORD_TYPE_HANDLERS:
                value = RECORD_TYPE_HANDLERS[rec_type](record)

            if not isinstance(value, list):
                value = [value]

            for val in value:
                if val is None:
                    continue
                if isinstance(val, dict):
                    lines.append(
                        f"{record['name']} {record['ttl']} IN {val['type']} {val['value']}"
                    )
                else:
                    lines.append(
                        f"{record['name']} {record['ttl']} IN {record['type']} {val}"
                    )

        data = "\n".join(sorted(list(set(lines)))) + "\n"
        with open(path_join(OUT_PATH, f"gen-{zone}.db"), "w") as file:
            file.write(data)

        bind_conf.append('zone "%s" IN {' % zone)
        bind_conf.append("    type native;")
        bind_conf.append('    file "/etc/pdns/gen-%s.db";' % zone)
        bind_conf.append("};")

        mikrotik_records.append({
            "type": "FWD",
            "forward-to": "pdns",
            "name": zone,
            "match-subdomain": "true"
        })

    with open(path_join(ROOT_PATH, "base.db"), "r") as file:
        soa_db = file.read()
    soa_db = soa_db.replace("1111111111", str(int(time())))
    with open(path_join(OUT_PATH, "base-rendered.db"), "w") as file:
        file.write(soa_db)

    with open(path_join(OUT_PATH, "bind.conf"), "w") as file:
        file.write("\n".join(bind_conf) + "\n")

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

        connection = router.connection()
        api = connection.get_api()
        api_dns = api.get_resource("/ip/dns/static")
        existing_static_dns = api_dns.get()
        existing_static_dns_map = {}
        for existing_record in existing_static_dns:
            key = f"{existing_record['type']}|{resolve_record(existing_record)}"
            if key in existing_static_dns_map:
                print("Removing duplicate DNS entry", existing_record)
                api_dns.remove(id=existing_record["id"])
            else:
                existing_static_dns_map[key] = existing_record

        stray_static_dns = set(existing_static_dns_map.keys())

        for record in mikrotik_records:
            key = f"{record['type']}|{record['name']}"
            stray_static_dns.discard(key)

            if key in existing_static_dns_map:
                existing_entry = existing_static_dns_map[key]
                for attr, val in record.items():
                    existing_val = existing_entry.get(attr)
                    if existing_val != val:
                        print(f"Updating DNS entry {record} due to changed attribute {attr}: {existing_val} -> {val}")
                        api_dns.set(id=existing_entry["id"], **record)
                        break
            else:
                print(f"Adding DNS entry {record}")
                api_dns.add(**record)

        for key in stray_static_dns:
            print(f"Removing stale DNS entry {existing_static_dns_map[key]}")
            api_dns.remove(id=existing_static_dns_map[key]["id"])
