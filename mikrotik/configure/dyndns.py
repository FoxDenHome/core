import re
from subprocess import check_output
from json import loads as json_loads
from configure.util import mtik_path, ROUTERS, MTikRouter, MTikScript

MAIN_SCRIPT = "dynamic-ip-update"
TEMPLATE = mtik_path(f"files/dyndns/{MAIN_SCRIPT}.rsc")

router_hosts = [router.host for router in ROUTERS]
SPECIAL_HOSTS = router_hosts + [f"v4-{router}" for router in router_hosts]

_dyndns_hosts_value = None


def load_dyndns_hosts():
    global _dyndns_hosts_value
    if _dyndns_hosts_value is not None:
        return _dyndns_hosts_value

    output = check_output(
        ["tofu", "output", "-show-sensitive", "-json"], cwd="../terraform"
    ).decode("utf-8")
    raw_output = json_loads(output)
    _dyndns_hosts_value = raw_output["he_dynamic_keys"]["value"]
    return _dyndns_hosts_value


def write_all_hosts(indent: str) -> list[str]:
    hosts = load_dyndns_hosts()
    lines = []
    for host in sorted(hosts.keys()):
        if host in SPECIAL_HOSTS:
            continue
        hostCfg = hosts[host]
        if hostCfg.get("ipv6") is not None:
            lines.append(
                f'{indent}$dyndnsUpdate host="{host}" key="{hostCfg["key"]}" priv6addr="{hostCfg["ipv6"]}" ip6addr=$ip6addr ipaddr=$ipaddr\n'
            )
        else:
            lines.append(
                f'{indent}$dyndnsUpdate host="{host}" key="{hostCfg["key"]}" ipaddr=$ipaddr\n'
            )
    return lines


def make_dyndns_script(router: MTikRouter) -> None:
    with open(TEMPLATE, "r") as file:
        lines = file.readlines()

    hosts = load_dyndns_hosts()
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
            host = hosts[router.host]
            outlines += [
                f'{indent}$dyndnsUpdate host="{router.host}" key="{host["key"]}" priv6addr="{router.dyndns_suffix_ipv6}" ip6addr=$ip6addr ipaddr=$ipaddr\n',
                f'{indent}$dyndnsUpdate host="v4-{router.host}" key="{hosts[f"v4-{router.host}"]["key"]}" ipaddr=$ipaddr\n',
            ]
            continue
        outlines.append(line)

    if not found_hosts:
        raise RuntimeError("No # HOSTS # found in script")

    router.scripts.add(MTikScript(
        name=MAIN_SCRIPT,
        source="".join(outlines),
        schedule="5m",
    ))


def refresh_dyndns():
    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        make_dyndns_script(router)
