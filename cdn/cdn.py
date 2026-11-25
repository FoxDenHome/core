#!/usr/bin/env python3
"""Makes the FoxDen CDN at Fastly (cdn.foxden.network) match this directory.

Stateless: it reads the service from Fastly each run and changes what
differs. Versioned config (backend, foxden-cdn.vcl, dictionaries, settings)
goes into a clone of the active version, which is validated and activated.
The static_root dictionary gets the files under static/. The vpn_peers
dictionary's items belong to foxden-vpn-portal and are left alone. Domains
and the TLS subscription are kept as listed in cdnsync/desired.py.

  ./cdn.py [plan] [--no-nix]          show what apply would change
  ./cdn.py apply [--no-nix] [--yes]   change it

Needs FASTLY_API_KEY. Unless --no-nix, it also checks that the DNS records
in nix point the domains at Fastly's CNAME.
"""

import argparse
import sys

from cdnsync import desired, sync
from cdnsync.api import Client


def main() -> int:
    parser = argparse.ArgumentParser(description="Makes the Fastly CDN match core")
    sub = parser.add_subparsers(dest="cmd")
    p_plan = sub.add_parser("plan", help="show what apply would change")
    p_apply = sub.add_parser("apply", help="make it match")
    for p in (p_plan, p_apply):
        p.add_argument(
            "--no-nix", action="store_true", help="skip the check of the nix DNS"
        )
    p_apply.add_argument("--yes", action="store_true", help="don't ask")
    args = parser.parse_args()
    args.no_nix = getattr(args, "no_nix", False)

    svc = desired.load()
    client = Client.from_env()
    nix_targets = None
    if not args.no_nix:
        nix_targets = desired.nix_targets(desired.load_dns_json(), svc.domains)
    plan = sync.make_plan(client, svc, nix_targets)

    for warning in plan.warnings:
        print(f"! {warning}")
    for change in plan.changes:
        print(change.describe())
    counts = ", ".join(f"{plan.count(k)} {k}" for k in sync.ORDER)
    print(f"Plan: {counts}")

    if args.cmd != "apply" or not plan.changes:
        return 0
    if not args.yes and input("Apply? [y/N] ").strip().lower() != "y":
        print("Aborted")
        return 1
    sync.apply(client, svc, plan)
    return 0


if __name__ == "__main__":
    sys.exit(main())
