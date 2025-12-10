#!/usr/bin/env -S uv run

from configure.dyndns import refresh_dyndns
from configure.haproxy import refresh_haproxy
from configure.pdns import refresh_pdns
from configure.dhcp import refresh_dhcp
from configure.firewall import refresh_firewall
from configure.scripts import refresh_scripts
from configure.vrrp import refresh_vrrp
from configure.tftp import refresh_tftp
from configure.util import ROUTERS
from contextlib import contextmanager


@contextmanager
def mtik_router_admin():
    try:
        for router in ROUTERS:
            router.ensure_user()
        yield True
    finally:
        for router in ROUTERS:
            try:
                router.disable_user()
            except Exception as e:
                print("Failed to disable user on", router, "with error", e)


def main():
    with mtik_router_admin():
        print("# DynDNS configuration")
        refresh_dyndns()
        print("# HAProxy configuration")
        refresh_haproxy()
        print("# PowerDNS configuration")
        refresh_pdns()
        print("# DHCP configuration")
        refresh_dhcp()
        print("# Firewall configuration")
        refresh_firewall()
        print("# VRRP configuration")
        refresh_vrrp()
        print("# TFTP configuration")
        refresh_tftp()
        # This must remain last as previous steps may create scripts that need to be deployed
        print("# Scripts")
        refresh_scripts()


if __name__ == "__main__":
    main()
