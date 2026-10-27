from os import makedirs
from os.path import join as path_join
from shutil import rmtree
from subprocess import check_output

from configure.util import (
    CONTAINER_HOST,
    NIX_DIR,
    ROUTERS,
    MTikContainer,
    MTikFirewallRule,
    mtik_path,
)

OUT_PATH = mtik_path("out/foxingress")

CONTAINER = MTikContainer(
    name="foxingress",
    remote_image="git.foxden.network/foxden/foxingress:latest",
    subnet=0,
    mounts=("/foxingress:/config:ro",),
)

FIREWALL_RULES = [
    MTikFirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "foxIngress TCP (Priv)",
            "dst-port": "9001",
            "protocol": "tcp",
            "to-addresses": CONTAINER.ipv4(CONTAINER_HOST),
        },
    ),
    MTikFirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "port-forward",
            "comment": "foxIngress TCP (Pub)",
            "dst-port": "80,443",
            "protocol": "tcp",
            "to-addresses": CONTAINER.ipv4(CONTAINER_HOST),
        },
    ),
    MTikFirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "foxIngress TCP (Priv)",
            "dst-port": "9001",
            "protocol": "tcp",
            "to-address": f"{CONTAINER.ipv6(CONTAINER_HOST)}/128",
        },
    ),
    MTikFirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "foxIngress TCP (Pub)",
            "dst-port": "80,443",
            "out-interface": CONTAINER.interface,
            "protocol": "tcp",
        },
    ),
    MTikFirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "foxIngress TCP (Priv)",
            "dst-port": "9001",
            "in-interface-list": "zone-local",
            "out-interface": CONTAINER.interface,
            "protocol": "tcp",
        },
    ),
]


def refresh_foxingress():
    result = (
        check_output(
            [
                "nix",
                "build",
                f"{NIX_DIR}#foxIngress.json.router",
                "--no-link",
                "--print-out-paths",
            ]
        )
        .strip()
        .decode("utf-8")
    )
    with open(result, "r") as file:
        config = file.read()

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)

    with open(path_join(OUT_PATH, "config.yml"), "w") as out_file:
        out_file.write(config)

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        router.containers.add(CONTAINER)
        router.firewall_rules.extend(FIREWALL_RULES)
        changes = router.sync(OUT_PATH, "/foxingress")
        if changes:
            print("### Queueing foxIngress container restart", changes)
            router.container_restarts.add(CONTAINER.name)
