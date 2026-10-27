import json
from os import makedirs
from os.path import join as path_join
from shutil import rmtree
from subprocess import check_output

from configure.util import (
    CONTAINER_HOST,
    NIX_DIR,
    ROUTER_HOST,
    ROUTERS,
    MTikContainer,
    MTikFirewallRule,
    mtik_path,
)

OUT_PATH = mtik_path("out/foxmail")

CONTAINER = MTikContainer(
    name="foxmail",
    remote_image="git.foxden.network/foxden/foxmail:latest",
    subnet=1,
    mounts=("/foxmail:/config:ro", "/foxmail-data:/data:rw"),
)

FIREWALL_RULES = [
    MTikFirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "foxMail TCP (Priv)",
            "dst-port": "2525,9002",
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
            "comment": "foxMail TCP (Priv)",
            "dst-port": "2525,9002",
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
            "in-interface": CONTAINER.interface,
            "out-interface": "wg-s2s",
        },
    ),
    MTikFirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "foxMail TCP (Priv)",
            "dst-port": "2525,9002",
            "in-interface-list": "zone-local",
            "out-interface": CONTAINER.interface,
            "protocol": "tcp",
        },
    ),
]


def refresh_foxmail():
    result = (
        check_output(
            [
                "nix",
                "build",
                f"{NIX_DIR}#foxMail.json.router",
                "--no-link",
                "--print-out-paths",
            ]
        )
        .strip()
        .decode("utf-8")
    )
    with open(result, "r") as file:
        config = json.load(file)

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        router.containers.add(CONTAINER)
        router.firewall_rules.extend(FIREWALL_RULES)

        config["sender"]["proxy"] = "socks5://10.99.10.1:1080"
        config["sender"]["domain"] = "redfox.doridian.net"
        config["sender"]["dkim"]["selector"] = router.host.split(".")[0]
        config["receiver"]["smtp"]["domain"] = router.host

        subnets = config["receiver"]["auth"]["subnets"]
        router_ip = f"{CONTAINER.ipv4(ROUTER_HOST)}/32"
        subnets["router@foxden.network"] = [router_ip]
        subnets["router-backup@foxden.network"] = [router_ip]

        with open(path_join(OUT_PATH, "config.yml"), "w") as out_file:
            json.dump(config, out_file)

        changes = router.sync(OUT_PATH, "/foxmail")
        if changes:
            print("### Queueing foxMail container restart", changes)
            router.container_restarts.add(CONTAINER.name)
