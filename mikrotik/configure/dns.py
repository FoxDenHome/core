from subprocess import check_output
from json import load as json_load
from configure.util import format_mtik_duration, NIX_DIR, ROUTERS
from typing import Any, cast

INTERNAL_RECORDS: dict[str, Any] | None = None

FIXED_RECORDS = [
    {"type": "NXDOMAIN", "name": zone, "match-subdomain": "true"}
    for zone in [
        "lunapixel.gg",
        "playstation.net",
        "playstation.com",
        "playstation.org",
        "scea.com",
        "sie-rd.com",
        "sonyentertainmentnetwork.com",
    ]
] + [
    {
        "type": "FWD",
        "name": cfg[0],
        "match-subdomain": "true",
        "forward-to": cfg[1],
    }
    for cfg in [
        ("check.getflix.com.au", "getflix"),
        ("check.getflix.com", "getflix"),
        ("zattoo.com", "getflix"),
        ("zahs.tv", "getflix"),
        ("cghmn", "cghmn"),
        ("retro", "cghmn"),
    ]
]

FIXED_FORWARDERS = [
    {
        "name": "getflix",
        "dns-servers": "54.187.61.200,169.55.51.86",
    },
    {
        "name": "cghmn",
        "dns-servers": "100.64.12.1",
    },
]

INTERNAL_ZONES = [
    "foxden.network",
]


def mtik_key(record: dict[str, Any]) -> str:
    additional_fields = MTIK_RECORD_TYPE_UNIQUE_FIELDS.get(record["type"], set())
    key_parts = [record["type"], resolve_record_name(record)]
    for field in additional_fields:
        if field in record:
            key_parts.append(f"{field}:{record[field]}")
    return "|".join(key_parts)


def find_record(name: str, rectype: str) -> dict | None:
    global INTERNAL_RECORDS
    assert INTERNAL_RECORDS is not None
    name = name.removesuffix(".")
    for zone, records in INTERNAL_RECORDS.items():
        for record in records:
            recname = record["name"] + "." + zone if record["name"] != "@" else zone
            if recname == name and record["type"] == rectype:
                return record
    return None


def mtik_process(record_raw: dict[str, Any]) -> dict[str, Any]:
    rec_type = record_raw["type"].upper()
    records = MTIK_RECORD_TYPE_HANDLERS[rec_type](record_raw)

    if not isinstance(records, list):
        records = [records]

    for record in records:
        if "type" not in record:
            record["type"] = rec_type
        if "ttl" not in record:
            record["ttl"] = format_mtik_duration(record_raw["ttl"])
        record["name"] = resolve_record_name(record_raw)

    return records


def handle_alias(raw_record: dict[str, Any]) -> list[dict[str, Any] | None]:
    records = [
        find_record(raw_record["value"], "A"),
        find_record(raw_record["value"], "AAAA"),
    ]
    results = []

    for record in records:
        if record is not None:
            results += mtik_process(record)

    if results:
        return results

    return {"type": "CNAME", "cname": raw_record["value"].removesuffix(".")}


def remap_ipv6(private: str, public: str) -> str:
    public_spl = public.split(":")
    prefix = f"{public_spl[0]}:{public_spl[1]}:{public_spl[2]}:{public_spl[3][:-1]}"
    suffix = private.removeprefix("fd2c:f4cb:63be:")
    return f"{prefix}{suffix}"


def resolve_record_name(record: dict[str, Any]) -> str:
    if "zone" not in record:
        return record["name"]
    if record["name"] == "@":
        return record["zone"]
    return f"{record['name']}.{record['zone']}"


MTIK_IGNORED_RECORD_TYPES = {"PTR", "SSHFP", "SOA"}

MTIK_RECORD_TYPE_HANDLERS = {}
MTIK_RECORD_TYPE_HANDLERS["A"] = lambda record: {"address": record["value"]}
MTIK_RECORD_TYPE_HANDLERS["AAAA"] = MTIK_RECORD_TYPE_HANDLERS["A"]
MTIK_RECORD_TYPE_HANDLERS["CNAME"] = lambda record: {
    "type": "CNAME",
    "cname": record["value"].removesuffix("."),
}
MTIK_RECORD_TYPE_HANDLERS["ALIAS"] = handle_alias
MTIK_RECORD_TYPE_HANDLERS["SRV"] = lambda record: {
    "srv-port": str(record["port"]),
    "srv-weight": str(record["weight"]),
    "srv-priority": str(record["priority"]),
    "srv-target": record["value"].removesuffix("."),
}
MTIK_RECORD_TYPE_HANDLERS["TXT"] = lambda record: {
    "type": "TXT",
    "text": record["value"],
}
MTIK_RECORD_TYPE_HANDLERS["MX"] = lambda record: {
    "type": "MX",
    "mx-preference": str(record["priority"]),
    "mx-exchange": record["value"].removesuffix("."),
}
MTIK_RECORD_TYPE_HANDLERS["NS"] = lambda record: {
    "type": "NS",
    "ns": record["value"].removesuffix("."),
}

MTIK_RECORD_TYPE_UNIQUE_FIELDS = {}
MTIK_RECORD_TYPE_UNIQUE_FIELDS["A"] = {"address"}
MTIK_RECORD_TYPE_UNIQUE_FIELDS["AAAA"] = {"address"}
MTIK_RECORD_TYPE_UNIQUE_FIELDS["CNAME"] = {"cname"}
MTIK_RECORD_TYPE_UNIQUE_FIELDS["SRV"] = {"srv-port", "srv-target"}
MTIK_RECORD_TYPE_UNIQUE_FIELDS["TXT"] = {"text"}
MTIK_RECORD_TYPE_UNIQUE_FIELDS["MX"] = {"mx-exchange"}
MTIK_RECORD_TYPE_UNIQUE_FIELDS["NS"] = {"ns"}


def refresh_dns():
    global INTERNAL_RECORDS
    result = (
        check_output(
            ["nix", "build", f"{NIX_DIR}#dns.json", "--no-link", "--print-out-paths"]
        )
        .strip()
        .decode("utf-8")
    )
    with open(result, "r") as file:
        INTERNAL_RECORDS = cast(
            dict[str, list[Any]], json_load(file)["records"]["internal"]
        )

    mikrotik_records = []
    mikrotik_forwarders = []

    for zone in INTERNAL_ZONES:
        for record_raw in INTERNAL_RECORDS[zone]:
            rec_type = record_raw["type"].upper()
            if rec_type in MTIK_IGNORED_RECORD_TYPES:
                # MTik does not support those atm, also PTR is auto-created, so we got those
                continue

            for record in mtik_process(record_raw):
                mikrotik_records.append(record)

    mikrotik_records += FIXED_RECORDS
    mikrotik_forwarders += FIXED_FORWARDERS

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")

        connection = router.connection()
        api = connection.get_api()
        api_dns = api.get_resource("/ip/dns/static")
        api_forwarders = api.get_resource("/ip/dns/forwarders")

        existing_static_dns = api_dns.get()
        existing_static_dns_map = {}
        for existing_record in existing_static_dns:
            key = mtik_key(existing_record)
            if key in existing_static_dns_map:
                print("Removing duplicate DNS entry", existing_record)
                api_dns.remove(id=existing_record["id"])
            else:
                existing_static_dns_map[key] = existing_record

        existing_forwarders = api_forwarders.get()
        existing_forwarders_map = {}
        for existing_forwarder in existing_forwarders:
            key = existing_forwarder["name"]
            existing_forwarders_map[key] = existing_forwarder

        stray_forwarders = set(existing_forwarders_map.keys())
        stray_static_dns = set(existing_static_dns_map.keys())
        handled_static_records = set()

        for forwarder in mikrotik_forwarders:
            key = forwarder["name"]

            stray_forwarders.discard(key)

            if key in existing_forwarders_map:
                existing_entry = existing_forwarders_map[key]
                for attr, val in forwarder.items():
                    existing_val = existing_entry.get(attr)
                    if existing_val != val:
                        print(
                            f"Updating forwarder entry {forwarder} due to changed attribute {attr}: {existing_val} -> {val}"
                        )
                        api_forwarders.set(id=existing_entry["id"], **forwarder)
                        break
            else:
                print(f"Adding forwarder entry {forwarder}")
                api_forwarders.add(**forwarder)

        for record in mikrotik_records:
            key = mtik_key(record)
            if key in handled_static_records:
                continue

            stray_static_dns.discard(key)
            handled_static_records.add(key)

            if key in existing_static_dns_map:
                existing_entry = existing_static_dns_map[key]
                for attr, val in record.items():
                    existing_val = existing_entry.get(attr)
                    if existing_val != val:
                        print(
                            f"Updating DNS entry {record} due to changed attribute {attr}: {existing_val} -> {val}"
                        )
                        api_dns.set(id=existing_entry["id"], **record)
                        break
            else:
                print(f"Adding DNS entry {record}")
                api_dns.add(**record)

        for key in stray_static_dns:
            print(f"Removing stale DNS entry {existing_static_dns_map[key]}")
            api_dns.remove(id=existing_static_dns_map[key]["id"])

        for key in stray_forwarders:
            print(f"Removing stale forwarder entry {existing_forwarders_map[key]}")
            api_forwarders.remove(id=existing_forwarders_map[key]["id"])
