import json
from dataclasses import replace
from os import makedirs
from os.path import exists
from os.path import join as path_join
from shutil import copyfile, rmtree
from subprocess import check_output

from configure.dyndns import load_dyndns_hosts
from configure.util import ROUTERS, MTikContainer, MTikFirewallRule, mtik_path

OUT_PATH = mtik_path("out/dashboard")
CONFIG_PATH = mtik_path("../dashboard/config.json")
# Flat map of environment variables (SNMP_COMMUNITY, UNIFI_USERNAME, ...)
SECRETS_PATH = mtik_path("secrets/dashboard.yaml")
# dns.he.net dynamic TXT record the dashboard writes for DNS-01
ACME_TXT_HOST = "_acme-challenge.status.foxden.network"

CONTAINER = MTikContainer(
    name="dashboard",
    remote_image="git.foxden.network/foxden/dashboard:latest",
    subnet=2,
    mounts=("/dashboard:/config:ro", "/dashboard-data:/data:rw"),
)

FIREWALL_RULES = [
    # IPv4 only: the "Containers" masquerade hides that every router's dashboard
    # has the same address, IPv6 has no such NAT
    MTikFirewallRule(
        families=["ip"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "dashboard SNMP",
            "dst-port": "161",
            "in-interface": CONTAINER.interface,
            "out-interface-list": "zone-local",
            "protocol": "udp",
        },
    ),
    MTikFirewallRule(
        families=["ip"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "dashboard tape library telnet, UniFi, node_exporter, smartctl_exporter",
            "dst-port": "23,443,9100,9633",
            "in-interface": CONTAINER.interface,
            "out-interface-list": "zone-local",
            "protocol": "tcp",
        },
    ),
    # From the LAN and from foxIngress
    MTikFirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "dashboard HTTP(S)",
            "dst-port": "80,443",
            "in-interface-list": "zone-local",
            "out-interface": CONTAINER.interface,
            "protocol": "tcp",
        },
    ),
    # IPv6 from outside skips foxIngress: Ingress PT maps it straight to the container
    MTikFirewallRule(
        families=["ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "dashboard HTTP(S) (Pub)",
            "dst-port": "80,443",
            "in-interface-list": "zone-wan",
            "out-interface": CONTAINER.interface,
            "protocol": "tcp",
        },
    ),
]


def load_secrets() -> tuple[tuple[str, str], ...]:
    if not exists(SECRETS_PATH):
        raise FileNotFoundError(
            f"{SECRETS_PATH} is missing, create it with: sops {SECRETS_PATH}"
        )
    secrets = json.loads(
        check_output(["sops", "decrypt", "--output-type", "json", SECRETS_PATH])
    )
    for key, value in secrets.items():
        if not isinstance(value, str):
            raise TypeError(f"Dashboard secret {key} must be a string")
    return tuple(sorted(secrets.items()))


def load_acme_dns_key() -> tuple[tuple[str, str], ...]:
    host = load_dyndns_hosts().get(ACME_TXT_HOST)
    if host is None:
        # The dashboard serves plain HTTP only until terraform has made the record
        print(f"### WARNING: No DDNS key for {ACME_TXT_HOST}, HTTPS stays off")
        return ()
    return (("ACME_DNS_KEY", host["key"]),)


def refresh_dashboard():
    env = load_secrets() + load_acme_dns_key()
    container = replace(CONTAINER, env=tuple(sorted(env)))

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)
    copyfile(CONFIG_PATH, path_join(OUT_PATH, "config.json"))

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        router.containers.add(container)
        router.firewall_rules.extend(FIREWALL_RULES)
        changes = router.sync(OUT_PATH, "/dashboard")
        if changes:
            print("### Queueing dashboard container restart", changes)
            router.container_restarts.add(container.name)
