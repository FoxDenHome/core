import re
from subprocess import check_output
from json import loads as json_loads
from configure.util import mtik_path, ROUTERS, MTikRouter, MTikScript

MAIN_SCRIPT = "dynamic-ip-update"
TEMPLATE = mtik_path(f"files/dyndns/{MAIN_SCRIPT}.rsc")

router_hosts = [router.host for router in ROUTERS]
SPECIAL_HOSTS = router_hosts + [f"v4-{router}" for router in router_hosts]

_dyndns_hosts_value = None

# TODO: Auto-generate this somehow
with open(mtik_path("files/dyndns/secrets.json"), "r") as file:
    SECRETS = json_loads(file.read())


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
    val = load_dyndns_hosts()
    lines = []
    for host in sorted(val.keys()):
        if host in SPECIAL_HOSTS:
            continue
        hostCfg = val[host]
        if hostCfg.get("ipv6") is not None:
            lines.append(
                f'{indent}$dyndnsUpdate host="{host}" key="{hostCfg["key"]}" priv6addr="{hostCfg["ipv6"]}" ip6addr=$ip6addr ipaddr=$ipaddr\n'
            )
        else:
            lines.append(
                f'{indent}$dyndnsUpdate host="{host}" key="{hostCfg["key"]}" ip6addr=$ip6addr ipaddr=$ipaddr\n'
            )
    return lines


def make_dyndns_script() -> MTikScript:
    with open(TEMPLATE, "r") as file:
        lines = file.readlines()

    outlines: list[str] = []
    found_hosts = False
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
        outlines.append(line)

    if not found_hosts:
        raise RuntimeError("No # BEGIN HOSTS found in script")

    return MTikScript(
        name=MAIN_SCRIPT,
        source="".join(outlines),
        schedule="5m",
    )


def make_local_onboot(router: MTikRouter) -> None:
    host = router.host
    host_v4 = f"v4-{router.host}"

    result: list[str] = []

    hosts = load_dyndns_hosts()

    result.append(f':global DynDNSSuffix6 "{router.dyndns_suffix_ipv6}"')
    result.append(f':global DynDNSHost "{host}"')
    result.append(f':global DynDNSKey "{hosts[host]["key"]}"')
    result.append(f':global DynDNSHost4 "{host_v4}"')
    result.append(f':global DynDNSKey4 "{hosts[host_v4]["key"]}"')

    result.append(f':global IPv6Host "{router.ipv6_tunnel_id}"')
    result.append(f':global IPv6Key "{SECRETS[host]["ipv6Key"]}"')

    script = MTikScript(
        name="onboot-dyndns-config",
        source="\n".join(result),
        run_on_change=True,
        schedule="startup",
    )
    router.scripts.add(script)


def refresh_dyndns():
    main_script = make_dyndns_script()
    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        router.scripts.add(main_script)
        make_local_onboot(router)
