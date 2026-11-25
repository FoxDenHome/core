#!/usr/bin/env python3
"""Makes the public DNS zones at ClouDNS match nix (flake output dns.json).

Stateless: it reads the zones from ClouDNS each run, adds what's missing,
fixes what differs and deletes records nix doesn't know. Zones are created
but never deleted.

  ./cloudns.py [plan]          show what apply would change
  ./cloudns.py apply [--yes]   change it
  ./cloudns.py dynamic-keys    JSON fqdn => {ipv4, ipv6, ipv6_suffix} for the routers
  ./cloudns.py acme-zones      JSON _acme-challenge.<name> => its ACME zone

Needs CLOUDNS_AUTH_ID and CLOUDNS_PASSWORD (the main API user), except for
acme-zones.
"""

import argparse
import json
import sys

from dnssync import desired, sync
from dnssync.api import Client


def load(with_dkim: bool) -> dict[str, desired.Zone]:
    dns = desired.load_dns_json()
    dkim = desired.load_dkim() if with_dkim else {}
    return desired.build(dns, dkim)


def cmd_plan(args: argparse.Namespace, apply: bool) -> int:
    client = Client.from_env()
    zones = load(with_dkim=True)
    existing = client.list_zones()
    live = sync.fetch_live(client, zones, existing)
    plan = sync.plan(zones, live)

    for name in sorted(set(existing) - set(zones)):
        plan.warnings.append(f"zone {name} is not in nix, left alone")
    for warning in plan.warnings:
        print(f"! {warning}")
    for change in plan.changes:
        print(change.describe())
    counts = ", ".join(f"{plan.count(k)} {k}" for k in sync.ORDER)
    print(f"Plan: {counts}")

    if not apply or not plan.changes:
        return 0
    deletes = plan.count(sync.DELETE)
    if deletes > args.max_deletes:
        print(
            f"Refusing to delete {deletes} records (--max-deletes {args.max_deletes})"
        )
        return 1
    if not args.yes and input("Apply? [y/N] ").strip().lower() != "y":
        print("Aborted")
        return 1

    for name, zone in sorted(zones.items()):
        changes = [c for c in plan.changes if c.zone == name]
        if changes:
            sync.apply_zone(client, zone, changes)
    return 0


def cmd_dynamic_keys(_: argparse.Namespace) -> int:
    client = Client.from_env()
    zones = load(with_dkim=False)
    live = sync.fetch_live(client, zones, client.list_zones())
    json.dump(sync.dynamic_keys(client, zones, live), sys.stdout, sort_keys=True)
    return 0


def cmd_acme_zones(_: argparse.Namespace) -> int:
    json.dump(
        desired.acme_challenges(desired.load_dns_json()), sys.stdout, sort_keys=True
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Makes the public DNS zones at ClouDNS match nix"
    )
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("plan", help="show what apply would change")
    p_apply = sub.add_parser("apply", help="make ClouDNS match nix")
    p_apply.add_argument("--yes", action="store_true", help="don't ask")
    p_apply.add_argument(
        "--max-deletes",
        type=int,
        default=20,
        help="refuse to apply if it deletes more records (default: %(default)s)",
    )
    sub.add_parser("dynamic-keys", help="DynamicURL keys for the routers (JSON)")
    sub.add_parser("acme-zones", help="ACME challenge => zone (JSON)")
    args = parser.parse_args()

    if args.cmd in (None, "plan"):
        return cmd_plan(args, apply=False)
    if args.cmd == "apply":
        return cmd_plan(args, apply=True)
    if args.cmd == "dynamic-keys":
        return cmd_dynamic_keys(args)
    return cmd_acme_zones(args)


if __name__ == "__main__":
    sys.exit(main())
