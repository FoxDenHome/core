from subprocess import check_call
from json import load as json_load
from os.path import join as path_join, exists
from refresh.util import unlink_safe, NIX_DIR, makeMTikPath, ROUTERS
from yaml import safe_load as yaml_load, dump as yaml_dump
from typing import Any

INTERNAL_RECORDS = None
ROOTPATH = makeMTikPath("files/pdns")

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
RECORD_TYPE_HANDLERS = {}
RECORD_TYPE_HANDLERS["MX"] = lambda record: f"{record['priority']} {record['value']}"
RECORD_TYPE_HANDLERS["SRV"] = lambda record: f"{record['priority']} {record['weight']} {record['port']} {record['value']}"
RECORD_TYPE_HANDLERS["TXT"] = quote_record
RECORD_TYPE_HANDLERS["LUA"] = quote_record
RECORD_TYPE_HANDLERS["ALIAS"] = lambda record: [find_record(record["value"], "A"), find_record(record["value"], "AAAA")]

def refresh_pdns():
    global INTERNAL_RECORDS
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#dns.json"])
    with open("result", "r") as file:
        INTERNAL_RECORDS = json_load(file)["records"]["internal"]
    unlink_safe("result")

    bind_conf = []

    with open(path_join(ROOTPATH, "recursor-template.conf"), "r") as file:
        recursor_data = yaml_load(file)

    if "recursor" not in recursor_data:
        recursor_data["recursor"] = {}

    if "forward_zones" not in recursor_data["recursor"]:
        recursor_data["recursor"]["forward_zones"] = []

    for zone in sorted(INTERNAL_RECORDS.keys()):
        records = INTERNAL_RECORDS[zone]
        zone_file = path_join(ROOTPATH, f"gen-{zone}.db")

        lines = []
        if exists(makeMTikPath(f"files/pdns/{zone}.local.db")):
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

        with open(zone_file, "w") as file:
            file.write(data)

        bind_conf.append('zone "%s" IN {' % zone)
        bind_conf.append('    type native;')
        bind_conf.append('    file "/etc/pdns/gen-%s.db";' % zone)
        bind_conf.append('};')

        recursor_data["recursor"]["forward_zones"].append({
            "zone": zone,
            "forwarders": ["127.0.0.1:530"]
        })

    with open(path_join(ROOTPATH, "bind.conf"), "w") as file:
        file.write("\n".join(bind_conf) + "\n")

    with open(path_join(ROOTPATH, "recursor.conf"), "w") as file:
        yaml_dump(recursor_data, file)

    for router in ROUTERS:
        print(f"## {router.host}")
        changes = router.sync(ROOTPATH, "/pdns")
        if changes:
            print("### Restarting PowerDNS container")
            router.restartContainer("pdns")
