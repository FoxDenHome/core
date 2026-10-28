#!/usr/bin/env -S uv run

from contextlib import contextmanager
from subprocess import CalledProcessError

from configure.basics import refresh_basics
from configure.containers import refresh_containers
from configure.dashboard import refresh_dashboard
from configure.dhcp import refresh_dhcp
from configure.dns import refresh_dns
from configure.dyndns import refresh_dyndns
from configure.firewall import refresh_firewall
from configure.foxingress import refresh_foxingress
from configure.foxmail import refresh_foxmail
from configure.scripts import refresh_scripts
from configure.util import ROUTERS
from configure.vrrp import refresh_vrrp


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
            except CalledProcessError as e:
                print("Failed to disable user on", router, "with error", e)


def main():
    with mtik_router_admin():
        # Must run first as it creates the interfaces, lists and DHCP servers the others use
        print("# Basic configuration")
        refresh_basics()
        print("# DynDNS configuration")
        refresh_dyndns()
        print("# foxIngress configuration")
        refresh_foxingress()
        print("# foxMail configuration")
        refresh_foxmail()
        print("# Dashboard configuration")
        refresh_dashboard()
        # Must run after the modules above as they register containers
        print("# Container configuration")
        refresh_containers()
        print("# DNS configuration")
        refresh_dns()
        print("# DHCP configuration")
        refresh_dhcp()
        # Must run after the modules above as they register firewall rules
        print("# Firewall configuration")
        refresh_firewall()
        print("# VRRP configuration")
        refresh_vrrp()
        # This must remain last as previous steps may create scripts that need to be deployed
        print("# Scripts")
        refresh_scripts()


if __name__ == "__main__":
    main()
