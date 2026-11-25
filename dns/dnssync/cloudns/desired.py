"""What ClouDNS should hold, built from the nix flake output dns.json and DKIM keys"""

import json
import re
from dataclasses import dataclass, field
from typing import Any
from urllib.request import urlopen

from dnssync import nix
from dnssync.cloudns.records import VALID_TTLS, Record

# ACME DNS-01: every dynamic TXT record _acme-challenge.<name> becomes a CNAME
# to _acme-challenge.<name>.<group>.acme.foxden.network. Each group is a zone of
# its own, so an API sub-user delegated only that zone can answer the
# challenges of its group and nothing else. lego follows the CNAME.
ACME_PARENT = "foxden.network"
ACME_DELEGATION_TTL = 3600

APEX_NS_TTL = 86400

DKIM_TTL = 3600
# Each router publishes the DKIM keys of the domains it signs for
DKIM_URLS = [
    "http://router.foxden.network:9002/dkim.json",
    "http://router-backup.foxden.network:9002/dkim.json",
    "http://icefox.foxden.network:9002/dkim.json",
]


@dataclass(frozen=True)
class DynamicRecord:
    """An A or AAAA record the routers keep up to date through its DynamicURL"""

    record: Record  # value is a placeholder until the routers update it
    fqdn: str
    suffix: str  # value from nix: the host part the routers OR onto their prefix


@dataclass
class Zone:
    name: str
    # Given to ClouDNS when it creates the zone, which makes them apex NS records
    nameservers: list[str]
    # Records are only managed in managed zones. ACME zones hold whatever the
    # challenges put there.
    managed: bool = True
    records: list[Record] = field(default_factory=list)
    # Apex NS records: added when missing, otherwise left alone
    apex_ns: list[Record] = field(default_factory=list)
    dynamic: list[DynamicRecord] = field(default_factory=list)


def load_dns_json() -> dict[str, Any]:
    return nix.load_json("dns.json")


def load_dkim() -> dict[str, str]:
    """<selector>._domainkey.<zone> => TXT value. Fails if any router does,
    as its records would otherwise be deleted."""
    keys: dict[str, str] = {}
    for url in DKIM_URLS:
        with urlopen(url, timeout=5) as res:
            keys.update(json.load(res))
    return keys


def public_zones(dns: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {k: v for k, v in dns["zones"].items() if v["registrar"] != "local"}


def _fqdn(zone: str, name: str) -> str:
    return zone if name == "@" else f"{name}.{zone}"


def acme_challenges(dns: dict[str, Any]) -> dict[str, str]:
    """_acme-challenge.<name> => ClouDNS zone its TXT record goes into"""
    challenges: dict[str, str] = {}
    for zone in public_zones(dns):
        for r in dns["records"]["external"].get(zone, []):
            if not (r.get("dynDns") and r["type"].upper() == "TXT"):
                continue
            fqdn = _fqdn(zone, r["name"])
            group = r.get("acmeGroup") or (
                fqdn.removeprefix("_acme-challenge.").replace(".", "-")
            )
            challenges[fqdn] = f"{group}.acme.{ACME_PARENT}"
    return challenges


def _check_ttl(zone: str, record: Record) -> None:
    if record.ttl not in VALID_TTLS:
        raise ValueError(
            f"ClouDNS does not accept TTL {record.ttl} "
            f"({record.host or '@'}.{zone} {record.type})"
        )


def build(dns: dict[str, Any], dkim: dict[str, str]) -> dict[str, Zone]:
    zones_json = public_zones(dns)
    upstream = [
        ns.removesuffix(".") for ns in dns["authorities"]["upstream"]["nameservers"]
    ]
    challenges = acme_challenges(dns)
    acme_zones = sorted(set(challenges.values()))

    zones: dict[str, Zone] = {}
    for name, info in zones_json.items():
        nameservers = [ns.removesuffix(".") for ns in info["nameserverList"]]
        zone = Zone(
            name=name,
            # ClouDNS drops nameservers inside the zone itself (ns3.foxden.network
            # in foxden.network) when it creates the zone, as their ALIASes don't
            # exist yet. They get added as records afterwards.
            nameservers=[ns for ns in nameservers if not ns.endswith(f".{name}")],
            apex_ns=[Record.make("NS", "", ns, APEX_NS_TTL) for ns in nameservers],
        )
        zones[name] = zone

        for r in dns["records"]["external"].get(name, []):
            rtype = r["type"].upper()
            host = "" if r["name"] == "@" else r["name"]
            fqdn = _fqdn(name, r["name"])
            if rtype == "NS" and host == "":
                continue  # apex_ns
            record = Record.make(
                rtype,
                host,
                r["value"],
                r["ttl"],
                priority=r.get("priority"),
                weight=r.get("weight"),
                port=r.get("port"),
                algorithm=r.get("algorithm"),
                fptype=r.get("fptype"),
            )
            if not r.get("dynDns"):
                zone.records.append(record)
            elif rtype == "TXT":
                zone.records.append(
                    Record.make("CNAME", host, f"{fqdn}.{challenges[fqdn]}", r["ttl"])
                )
            elif rtype in ("A", "AAAA"):
                placeholder = "127.0.0.1" if rtype == "A" else "::1"
                zone.dynamic.append(
                    DynamicRecord(record.with_value(placeholder), fqdn, r["value"])
                )

    parent = zones[ACME_PARENT]
    for acme_zone in acme_zones:
        host = acme_zone.removesuffix(f".{ACME_PARENT}")
        for ns in upstream:
            parent.records.append(Record.make("NS", host, ns, ACME_DELEGATION_TTL))
        zones[acme_zone] = Zone(name=acme_zone, nameservers=upstream, managed=False)

    for fqdn, value in dkim.items():
        zone_name = re.sub(r"^.*\._domainkey\.", "", fqdn)
        if zone_name not in zones:
            raise ValueError(f"DKIM key {fqdn} is not in a public zone")
        host = fqdn.removesuffix(f".{zone_name}")
        zones[zone_name].records.append(Record.make("TXT", host, value, DKIM_TTL))

    for zone in zones.values():
        for record in zone.records + [d.record for d in zone.dynamic]:
            _check_ttl(zone.name, record)
        zone.records = _dedupe(zone.name, zone.records)

    return zones


def _dedupe(zone: str, records: list[Record]) -> list[Record]:
    by_key: dict[tuple[str, str, str], Record] = {}
    for record in records:
        other = by_key.setdefault(record.key(), record)
        if other != record:
            raise ValueError(
                f"Conflicting records in {zone}: {other.describe()} / {record.describe()}"
            )
    return list(by_key.values())
