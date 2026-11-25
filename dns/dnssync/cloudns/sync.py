"""Compares the desired zones with ClouDNS and makes ClouDNS match"""

import re
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any

from dnssync.cloudns.api import Client
from dnssync.cloudns.desired import Zone
from dnssync.cloudns.records import LiveRecord, Record

# Change kinds, in the order they are applied
CREATE_ZONE = "create-zone"
ADD = "add"
MODIFY = "modify"
DELETE = "delete"
ORDER = [CREATE_ZONE, ADD, MODIFY, DELETE]
SYMBOLS = {CREATE_ZONE: "+", ADD: "+", MODIFY: "~", DELETE: "-"}


@dataclass(frozen=True)
class Change:
    kind: str
    zone: str
    record: Record | None = None  # what it becomes (create, add, modify)
    live: LiveRecord | None = None  # what it was (modify, delete)

    def describe(self) -> str:
        sym = SYMBOLS[self.kind]
        if self.kind == CREATE_ZONE:
            return f"{sym} zone {self.zone}"
        if self.kind == MODIFY:
            assert self.record is not None and self.live is not None
            return (
                f"{sym} {self.zone}: {self.live.record.describe()}\n"
                f"    => {self.record.describe()}"
            )
        rec = self.record if self.record is not None else self.live
        assert rec is not None
        if isinstance(rec, LiveRecord):
            rec = rec.record
        return f"{sym} {self.zone}: {rec.describe()}"


@dataclass
class Plan:
    changes: list[Change]
    warnings: list[str]

    def count(self, kind: str) -> int:
        return sum(1 for c in self.changes if c.kind == kind)


def plan_zone(zone: Zone, live: list[LiveRecord] | None) -> Plan:
    """Changes that make the live records (None: zone missing) match zone"""
    changes: list[Change] = []
    warnings: list[str] = []
    if live is None:
        changes.append(Change(CREATE_ZONE, zone.name))
        live = []
    if not zone.managed:
        return Plan(changes, warnings)

    remaining = list(live)

    def take(by: Callable[[Record], object], want: Record) -> LiveRecord | None:
        """Removes and returns the first live record with by(record) == by(want)"""
        for i, rec in enumerate(remaining):
            if by(rec.record) == by(want):
                return remaining.pop(i)
        return None

    for want in zone.records:
        have = take(Record.key, want)
        if have is None:
            changes.append(Change(ADD, zone.name, record=want))
        elif have.record.attrs() != want.attrs():
            changes.append(Change(MODIFY, zone.name, record=want, live=have))

    for ns in zone.apex_ns:
        # ClouDNS makes these itself when it creates the zone. Their TTL is
        # theirs to pick.
        if take(Record.key, ns) is None:
            changes.append(Change(ADD, zone.name, record=ns))

    for dyn in zone.dynamic:
        want = dyn.record
        # The value is the routers' to keep
        have = take(Record.slot, want)
        if have is None:
            changes.append(Change(ADD, zone.name, record=want))
        elif have.record.attrs() != want.attrs():
            changes.append(
                Change(
                    MODIFY,
                    zone.name,
                    record=want.with_value(have.record.value),
                    live=have,
                )
            )

    for have in remaining:
        if have.record.type == "NS" and have.record.host == "":
            warnings.append(
                f"{zone.name}: apex NS {have.record.value} is not in nix, left alone"
            )
            continue
        changes.append(Change(DELETE, zone.name, live=have))

    return Plan(changes, warnings)


def fetch_live(
    client: Client, zones: dict[str, Zone], existing: list[str]
) -> dict[str, list[LiveRecord] | None]:
    """Live records of each zone, None if it doesn't exist. Not fetched for
    zones whose records aren't managed."""

    def fetch(zone: Zone) -> list[LiveRecord] | None:
        if zone.name not in existing:
            return None
        if not zone.managed:
            return []
        return [LiveRecord.from_api(r) for r in client.list_records(zone.name)]

    with ThreadPoolExecutor(4) as pool:
        results = pool.map(fetch, zones.values())
        return dict(zip(zones.keys(), results))


def plan(zones: dict[str, Zone], live: dict[str, list[LiveRecord] | None]) -> Plan:
    total = Plan([], [])
    for name, zone in sorted(zones.items()):
        p = plan_zone(zone, live[name])
        total.changes += p.changes
        total.warnings += p.warnings
    total.changes.sort(key=lambda c: ORDER.index(c.kind))
    return total


def apply_change(client: Client, change: Change) -> None:
    if change.kind == CREATE_ZONE:
        raise ValueError("Zones are created by apply_zone")
    if change.kind == ADD:
        assert change.record is not None
        client.add_record(change.zone, change.record.params())
    elif change.kind == MODIFY:
        assert change.record is not None and change.live is not None
        client.modify_record(change.zone, change.live.id, change.record.params())
    elif change.kind == DELETE:
        assert change.live is not None
        client.delete_record(change.zone, change.live.id)


def apply_zone(client: Client, zone: Zone, changes: list[Change]) -> None:
    if any(c.kind == CREATE_ZONE for c in changes):
        print(f"+ zone {zone.name}")
        client.register_zone(zone.name, zone.nameservers)
        # ClouDNS adds records of its own to a new zone, so plan again
        live = [LiveRecord.from_api(r) for r in client.list_records(zone.name)]
        changes = [c for c in plan_zone(zone, live).changes if c.kind != CREATE_ZONE]
    # Apex NS records last: ns3.foxden.network needs its ALIAS first
    changes.sort(
        key=lambda c: (
            ORDER.index(c.kind),
            c.record is not None and c.record.type == "NS" and c.record.host == "",
        )
    )
    for change in changes:
        print(change.describe())
        apply_change(client, change)


def dynamic_keys(
    client: Client,
    zones: dict[str, Zone],
    live: dict[str, list[LiveRecord] | None],
) -> dict[str, dict[str, Any]]:
    """fqdn => {ipv4, ipv6, ipv6_suffix}: DynamicURL keys for the routers.
    Records that don't exist yet are left out."""
    jobs: list[tuple[str, str, str]] = []  # fqdn, type, record id
    suffixes: dict[str, str] = {}
    for name, zone in zones.items():
        by_slot = {r.record.slot(): r for r in live.get(name) or []}
        for dyn in zone.dynamic:
            have = by_slot.get(dyn.record.slot())
            if dyn.record.type == "AAAA":
                suffixes[dyn.fqdn] = dyn.suffix
            if have is not None:
                jobs.append((dyn.fqdn, dyn.record.type, have.id))

    zone_of = {dyn.fqdn: zone.name for zone in zones.values() for dyn in zone.dynamic}

    def fetch(job: tuple[str, str, str]) -> str:
        fqdn, _, record_id = job
        url = client.dynamic_url(zone_of[fqdn], record_id)
        # https://ipv4.cloudns.net/api/dynamicURL/?q=<key>. The routers send
        # the key to ipv4.cloudns.net or ipv6.cloudns.net themselves.
        match = re.search(r"[?&]q=([^&]+)", url)
        if match is None:
            raise ValueError(f"No key in the DynamicURL of {fqdn}")
        return match.group(1)

    with ThreadPoolExecutor(4) as pool:
        urls = list(pool.map(fetch, jobs))

    keys: dict[str, dict[str, Any]] = {}
    for (fqdn, rtype, _), key in zip(jobs, urls):
        entry = keys.setdefault(
            fqdn, {"ipv4": None, "ipv6": None, "ipv6_suffix": suffixes.get(fqdn)}
        )
        entry["ipv4" if rtype == "A" else "ipv6"] = key
    return keys
