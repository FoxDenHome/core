from subprocess import check_call
from json import load as json_load
from os.path import join as path_join, exists
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
RECORD_TYPE_HANDLERS["ALIAS"] = handle_alias
RECORD_TYPE_HANDLERS["SOA"] = disallow_apex_record
RECORD_TYPE_HANDLERS["NS"] = disallow_apex_record

MTIK_RECORD_TYPE_HANDLERS = {}
MTIK_RECORD_TYPE_HANDLERS["A"] = lambda record: {"address": record["value"]}
MTIK_RECORD_TYPE_HANDLERS["AAAA"] = MTIK_RECORD_TYPE_HANDLERS["A"]
MTIK_RECORD_TYPE_HANDLERS["CNAME"] = lambda record: {"cname": record["value"].removesuffix(".")}

def remap_ipv6(private: str, public: str) -> str:
    public_spl = public.split(":")
    prefix = f"{public_spl[0]}:{public_spl[1]}:{public_spl[2]}:{public_spl[3][:-1]}"
    suffix = private.removeprefix("fd2c:f4cb:63be:")
    return f"{prefix}{suffix}"

def record_key(record: dict[str, Any]) -> str:
    return f"{record['type']}|{resolve_record(record)}"

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
        INTERNAL_RECORDS = cast(dict[str, Any], json_load(file)["records"]["internal"])
    unlink_safe("result")

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)
    copytree(ROOT_PATH, OUT_PATH, dirs_exist_ok=True)

    bind_conf = []

    with open(path_join(ROOT_PATH, "recursor.conf"), "r") as file:
        recursor_data = yaml_load(file)

    if "recursor" not in recursor_data:
        recursor_data["recursor"] = {}

    if "forward_zones" not in recursor_data["recursor"]:
        recursor_data["recursor"]["forward_zones"] = []

    for zone in sorted(INTERNAL_RECORDS.keys()):
        records = INTERNAL_RECORDS[zone]

        lines = ["$INCLUDE /etc/pdns/base-rendered.db"]
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

        recursor_data["recursor"]["forward_zones"].append(
            {"zone": zone, "forwarders": ["127.0.0.1:530"]}
        )

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
            router.run_in_container("pdns", "pdnsutil secure-zone '" + zone + "'")

        connection = router.connection()
        api = connection.get_api()
        api_dns = api.get_resource("/ip/dns/static")
        existing_static_dns = api_dns.get()
        existing_static_dns_map = {}
        for existing_record in existing_static_dns:
            key = record_key(existing_record)
            if key in existing_static_dns_map:
                print("Removing duplicate DNS entry", existing_record)
                api_dns.remove(id=existing_record["id"])
            else:
                existing_static_dns_map[key] = existing_record

        stray_static_dns = set(existing_static_dns_map.keys())

        for zone in sorted(INTERNAL_RECORDS.keys()):
            records = INTERNAL_RECORDS[zone]
            for record in records:
                if not record["critical"]:
                    continue
                if record["type"] == "PTR":
                    # We skip PTR records, MTik creates those on its own anyway and they are not critical for us
                    continue

                handler = MTIK_RECORD_TYPE_HANDLERS.get(record["type"])
                if handler is None:
                    raise ValueError(f"No MTik handler for record type {record['type']} for critical record {record['name']} in zone {zone}")
                key = record_key(record)
                stray_static_dns.discard(key)

                attribs = handler(record)
                attribs["ttl"] = f"{record['ttl']}"
                attribs["type"] = record["type"]
                attribs["name"] = resolve_record(record)

                if key in existing_static_dns_map:
                    existing_entry = existing_static_dns_map[key]
                    for attr, val in attribs.items():
                        if existing_entry[attr] != val:
                            print(f"Updating DNS entry {record}")
                            api_dns.set(id=existing_entry["id"], **attribs)
                            break
                else:
                    print(f"Adding DNS entry {record}")
                    api_dns.add(**attribs)

        for key in stray_static_dns:
            print(f"Removing stale DNS entry {existing_static_dns_map[key]}")
            api_dns.remove(id=existing_static_dns_map[key]["id"])
