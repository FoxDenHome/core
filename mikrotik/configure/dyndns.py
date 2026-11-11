import re
from json import loads as json_loads
from subprocess import check_output
from typing import Any

from configure.util import ROUTERS, MTikRouter, MTikScript, mtik_path

MAIN_SCRIPT = "dynamic-ip-update"
TEMPLATE = mtik_path(f"files/dyndns/{MAIN_SCRIPT}.rsc")

router_hosts = [router.host for router in ROUTERS]
SPECIAL_HOSTS = router_hosts + [f"v4-{router}" for router in router_hosts]

_tofu_outputs_value: dict[str, Any] | None = None


def load_tofu_outputs() -> dict[str, Any]:
    global _tofu_outputs_value
    if _tofu_outputs_value is not None:
        return _tofu_outputs_value

    # tf.sh sets up access to the state backend on islandfox
    output = check_output(
        [mtik_path("../terraform/tf.sh"), "output", "-show-sensitive", "-json"]
    ).decode("utf-8")
    raw_output = json_loads(output)
    _tofu_outputs_value = {key: value["value"] for key, value in raw_output.items()}
    return _tofu_outputs_value


def load_cloudns_hosts() -> dict[str, dict[str, Any]]:
    """fqdn => {ipv4, ipv6, ipv6_suffix}: ClouDNS dynamic URL keys"""
    return load_tofu_outputs().get("cloudns_dynamic_keys") or {}


def load_acme_zones() -> dict[str, str]:
    """_acme-challenge.<name> => ClouDNS zone its TXT record goes into"""
    return load_tofu_outputs().get("acme_zones") or {}


def update_line(indent: str, host: str, priv6addr: str | None = None) -> str | None:
    """$dyndnsUpdate call for host, or None if ClouDNS doesn't have it"""
    cloudns = load_cloudns_hosts().get(host)
    if cloudns is None:
        return None

    args = [f'host="{host}"']
    if cloudns.get("ipv4") is not None:
        args.append(f'key4="{cloudns["ipv4"]}"')
    if cloudns.get("ipv6") is not None:
        args.append(f'key6="{cloudns["ipv6"]}"')
    if priv6addr is None:
        priv6addr = cloudns.get("ipv6_suffix")
    if priv6addr is not None:
        args.append(f'priv6addr="{priv6addr}" ip6addr=$ip6addr')
    args.append("ipaddr=$ipaddr")
    return f"{indent}$dyndnsUpdate {' '.join(args)}\n"


def write_all_hosts(indent: str) -> list[str]:
    hosts = load_cloudns_hosts().keys()
    lines = []
    for host in sorted(hosts):
        if host in SPECIAL_HOSTS:
            continue
        line = update_line(indent, host)
        if line is not None:
            lines.append(line)
    return lines


def write_special_hosts(indent: str, router: MTikRouter) -> list[str]:
    lines = [
        update_line(indent, router.host, router.dyndns_suffix_ipv6),
        update_line(indent, f"v4-{router.host}"),
    ]
    return [line for line in lines if line is not None]


def make_dyndns_script(router: MTikRouter) -> None:
    with open(TEMPLATE, "r") as file:
        lines = file.readlines()

    outlines: list[str] = []
    found_hosts = False
    found_special_hosts = False
    for line in lines:
        line_strip = line.strip()
        if line_strip == "# HOSTS #":
            if found_hosts:
                raise RuntimeError("Multiple # HOSTS # found in script")
            match = re.match(r"^(\s*)# HOSTS #", line)
            assert match is not None
            indent = match.group(1)
            found_hosts = True
            outlines += write_all_hosts(indent)
            continue
        elif line_strip == "# SPECIAL HOSTS #":
            if found_special_hosts:
                raise RuntimeError("Multiple # SPECIAL HOSTS # found in script")
            match = re.match(r"^(\s*)# SPECIAL HOSTS #", line)
            assert match is not None
            indent = match.group(1)
            found_special_hosts = True
            outlines += write_special_hosts(indent, router)
            continue
        outlines.append(line)

    if not found_hosts:
        raise RuntimeError("No # HOSTS # found in script")

    router.scripts.add(
        MTikScript(
            name=MAIN_SCRIPT,
            source="".join(outlines),
            schedule="5m",
        )
    )


def refresh_dyndns():
    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        make_dyndns_script(router)
