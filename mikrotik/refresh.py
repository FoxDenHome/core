#!/usr/bin/env python3

from refresh.dyndns import refresh_dyndns
from refresh.haproxy import refresh_haproxy
from refresh.pdns import refresh_pdns
from refresh.dhcp import refresh_dhcp
from refresh.firewall import refresh_firewall
from refresh.scripts import refresh_scripts
from refresh.util import MTikUser
from contextlib import contextmanager
import uuid

ROUTERS = [
    "router.foxden.network",
    "router-backup.foxden.network",
]

@contextmanager
def mtik_admin_user():
    user = MTikUser(username="refresh-py", password=str(uuid.v4()))
    try:
        for router in ROUTERS:
            user.ensure(router)
        yield user
    finally:
        for router in ROUTERS:
            try:
                user.disable(router)
            except Exception as e:
                print("Failed to disable user on", router, "with error", e)

def main():
    with mtik_admin_user() as user:
        print("# DynDNS configuration")
        refresh_dyndns()
        print("# HAProxy configuration")
        refresh_haproxy()
        print("# PowerDNS configuration")
        refresh_pdns()
        print("# DHCP configuration")
        refresh_dhcp(user=user)
        print("# Firewall configuration")
        refresh_firewall(user=user)
        print("# Scripts")
        refresh_scripts(user=user)

if __name__ == "__main__":
    main()
