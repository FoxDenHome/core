#!/usr/bin/env python3
"""Makes the public DNS match nix.

  cloudns  the public zones at ClouDNS (flake output dns.json, plus the
           routers' DKIM keys)
  ovh      the reverse DNS of the public IPs at OVH (flake output
           ipReverses.json)

Stateless: it reads what's live each run, adds what's missing, fixes what
differs and deletes what nix doesn't know. Zones are created but never
deleted.

  ./dns.py [plan] [--only P]          show what apply would change
  ./dns.py apply [--only P] [--yes]   change it
  ./dns.py dynamic-keys    JSON fqdn => {ipv4, ipv6, ipv6_suffix} for the routers
  ./dns.py acme-zones      JSON _acme-challenge.<name> => its ACME zone

ClouDNS needs CLOUDNS_AUTH_ID and CLOUDNS_PASSWORD (the main API user), except
for acme-zones. OVH needs OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET,
OVH_CONSUMER_KEY and OVH_ENDPOINT (default ovh-us).
"""

import argparse
import json
import sys

from dnssync.cloudns import desired, sync
from dnssync.cloudns.api import Client
from dnssync.ovh import api as ovh_api
from dnssync.ovh import reverses

PROVIDERS = ["cloudns", "ovh"]


def load(with_dkim: bool) -> dict[str, desired.Zone]:
    dns = desired.load_dns_json()
    dkim = desired.load_dkim() if with_dkim else {}
    return desired.build(dns, dkim)


def plan_cloudns() -> tuple[sync.Plan, Client, dict[str, desired.Zone]]:
    client = Client.from_env()
    zones = load(with_dkim=True)
    existing = client.list_zones()
    live = sync.fetch_live(client, zones, existing)
    plan = sync.plan(zones, live)
    for name in sorted(set(existing) - set(zones)):
        plan.warnings.append(f"zone {name} is not in nix, left alone")
    return plan, client, zones


def cmd_plan(args: argparse.Namespace, apply: bool) -> int:
    providers = [args.only] if args.only else PROVIDERS
    deletes = 0
    pending = 0
    cloudns = None
    ovh = None

    if "cloudns" in providers:
        cloudns = plan_cloudns()
        cl_plan = cloudns[0]
        print("== ClouDNS")
        for warning in cl_plan.warnings:
            print(f"! {warning}")
        for change in cl_plan.changes:
            print(change.describe())
        counts = ", ".join(f"{cl_plan.count(k)} {k}" for k in sync.ORDER)
        print(f"Plan: {counts}")
        deletes += cl_plan.count(sync.DELETE)
        pending += len(cl_plan.changes)

    if "ovh" in providers:
        ovh_client = ovh_api.Client.from_env()
        ovh_plan = reverses.load_plan(ovh_client)
        ovh = ovh_plan, ovh_client
        print("== OVH reverse DNS")
        for warning in ovh_plan.warnings:
            print(f"! {warning}")
        for change in ovh_plan.changes:
            print(change.describe())
        counts = ", ".join(
            f"{ovh_plan.count(k)} {k}" for k in (reverses.SET, reverses.DELETE)
        )
        print(f"Plan: {counts}")
        deletes += ovh_plan.count(reverses.DELETE)
        pending += len(ovh_plan.changes)

    if not apply or not pending:
        return 0
    if deletes > args.max_deletes:
        print(
            f"Refusing to delete {deletes} records (--max-deletes {args.max_deletes})"
        )
        return 1
    if not args.yes and input("Apply? [y/N] ").strip().lower() != "y":
        print("Aborted")
        return 1

    # Forward records first: OVH only takes a reverse whose name resolves
    if cloudns is not None:
        cl_plan, cl_client, zones = cloudns
        for name, zone in sorted(zones.items()):
            changes = [c for c in cl_plan.changes if c.zone == name]
            if changes:
                sync.apply_zone(cl_client, zone, changes)
    if ovh is not None:
        ovh_plan, ovh_client = ovh
        for change in ovh_plan.changes:
            print(change.describe())
            reverses.apply_change(ovh_client, change)
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
        description="Makes the public DNS (ClouDNS, OVH reverses) match nix"
    )
    sub = parser.add_subparsers(dest="cmd")
    p_plan = sub.add_parser("plan", help="show what apply would change")
    p_apply = sub.add_parser("apply", help="make it match nix")
    for p in (p_plan, p_apply):
        p.add_argument(
            "--only", choices=PROVIDERS, help="only this provider (default: all)"
        )
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
    args.only = getattr(args, "only", None)

    if args.cmd in (None, "plan"):
        return cmd_plan(args, apply=False)
    if args.cmd == "apply":
        return cmd_plan(args, apply=True)
    if args.cmd == "dynamic-keys":
        return cmd_dynamic_keys(args)
    return cmd_acme_zones(args)


if __name__ == "__main__":
    sys.exit(main())
