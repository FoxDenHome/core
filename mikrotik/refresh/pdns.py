from subprocess import check_call
from json import load as json_load
from os.path import join as path_join
from refresh.util import unlink_safe, NIX_DIR, mtik_path
from yaml import safe_load as yaml_load, dump as yaml_dump

INTERNAL_RECORDS = None
ZONE_DIR = mtik_path("files/pdns")

def foreach_vlan(records: list[str]) -> list[str]:
    lines = []
    for vlan in range(0, 10):
        for record in records:
            lines.append(record % vlan)
    return lines
SPECIAL_ZONES = {}
SPECIAL_ZONES["foxden.network"] = lambda: [
    "$INCLUDE /etc/pdns/foxden.network.local.db",
]
SPECIAL_ZONES["10.in-addr.arpa"] = lambda: foreach_vlan([
    "1.0.%d IN PTR gateway.foxden.network.",
    "53.0.%d IN PTR dns.foxden.network.",
    "123.0.%d IN PTR ntp.foxden.network.",
    "1.1.%d IN PTR router.foxden.network.",
    "2.1.%d IN PTR router-backup.foxden.network.",
    "123.1.%d IN PTR ntpi.foxden.network.",
])
SPECIAL_ZONES["e.b.3.6.b.c.4.f.c.2.d.f.ip6.arpa"] = lambda: foreach_vlan([
    "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.%x.0.0.0 IN PTR gateway.foxden.network.",
    "5.3.0.0.0.0.0.0.0.0.0.0.0.0.0.0.%x.0.0.0 IN PTR dns.foxden.network.",
    "b.7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.%x.0.0.0 IN PTR ntp.foxden.network.",
    "1.0.1.0.0.0.0.0.0.0.0.0.0.0.0.0.%x.0.0.0 IN PTR router.foxden.network.",
    "2.0.1.0.0.0.0.0.0.0.0.0.0.0.0.0.%x.0.0.0 IN PTR router-backup.foxden.network.",
    "b.7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.%x.0.0.0 IN PTR ntpi.foxden.network.",
])
def find_record(name: str, type: str) -> dict:
    global INTERNAL_RECORDS
    name = name.removesuffix(".")
    for zone, records in INTERNAL_RECORDS.items():
        for record in records:
            recname = record["name"] + "." + zone if record["name"] != "@" else zone
            if recname == name and record["type"] == type:
                return record
    return None
RECORD_TYPE_HANDLERS = {}
RECORD_TYPE_HANDLERS["MX"] = lambda record: f"{record['priority']} {record['value']}"
RECORD_TYPE_HANDLERS["SRV"] = lambda record: f"{record['priority']} {record['weight']} {record['port']} {record['value']}"
RECORD_TYPE_HANDLERS["TXT"] = lambda record: f'"{record["value"]}"'
RECORD_TYPE_HANDLERS["ALIAS"] = lambda record: [find_record(record["value"], "A"), find_record(record["value"], "AAAA")]

def refresh_pdns():
    global INTERNAL_RECORDS
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#dns.json"])
    with open("result", "r") as file:
        INTERNAL_RECORDS = json_load(file)["records"]["internal"]
    unlink_safe("result")

    bind_conf = []

    print("## Reading recursor-template.conf")
    with open(path_join(ZONE_DIR, "recursor-template.conf"), "r") as file:
        recursor_data = yaml_load(file)

    if "recursor" not in recursor_data:
        recursor_data["recursor"] = {}

    if "forward_zones" not in recursor_data["recursor"]:
        recursor_data["recursor"]["forward_zones"] = []

    print("## Writing zone files")
    for zone in sorted(INTERNAL_RECORDS.keys()):
        print(f"### Processing zone {zone}")
        records = INTERNAL_RECORDS[zone]
        zone_file = path_join(ZONE_DIR, f"gen-{zone}.db")

        fixed_lines = [
            "$TTL 300",
            "$INCLUDE /etc/pdns/authority.db"
        ]

        if zone in SPECIAL_ZONES:
            fixed_lines += SPECIAL_ZONES[zone]()

        lines = []
        for record in records:
            value = record["value"]
            if record["type"] in RECORD_TYPE_HANDLERS:
                value = RECORD_TYPE_HANDLERS[record["type"]](record)
            if not isinstance(value, list):
                value = [value]
            for val in value:
                if isinstance(val, dict):
                    lines.append(f"{record['name']} {record['ttl']} IN {val['type']} {val['value']}")
                else:
                    lines.append(f"{record['name']} {record['ttl']} IN {record['type']} {val}")
        data = "\n".join(fixed_lines + sorted(list(set(lines)))) + "\n"

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

    print("## Writing bind.conf")
    with open(path_join(ZONE_DIR, "bind.conf"), "w") as file:
        file.write("\n".join(bind_conf) + "\n")

    print("## Writing recursor.conf")
    with open(path_join(ZONE_DIR, "recursor.conf"), "w") as file:
        yaml_dump(recursor_data, file)
