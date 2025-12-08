import re
from subprocess import check_output
from json import loads as json_loads
from urllib.parse import ParseResult, parse_qs, urlparse
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
        ["tofu", "output", "-show-sensitive", "-json"], cwd="../terraform/domains"
    ).decode("utf-8")
    raw_output = json_loads(output)
    raw_value = raw_output["dynamic_urls"]["value"]

    value = {}
    for zone, records in raw_value.items():
        for rec in records:
            rec_host = rec["name"] + "." + zone
            if rec["name"] == "@":
                rec_host = zone

            if rec_host not in value:
                value[rec_host] = {}
            value[rec_host][rec["type"]] = rec
    _dyndns_hosts_value = value

    return _dyndns_hosts_value


def get_dyndns_url(host: str, record_type: str) -> ParseResult:
    val = load_dyndns_hosts()
    return urlparse(val[host][record_type]["url"])


def get_dyndns_key(host: str, record_type: str) -> str:
    url = get_dyndns_url(host, record_type)
    qs = parse_qs(url.query)
    return qs["q"][0]


def write_all_hosts(indent: str) -> list[str]:
    val = load_dyndns_hosts()
    lines = []
    for host in sorted(val.keys()):
        if host in SPECIAL_HOSTS:
            continue
        hostCfg = val[host]
        key4 = get_dyndns_key(host, "A")
        if "AAAA" in hostCfg:
            key6 = get_dyndns_key(host, "AAAA")
            ipv6 = hostCfg["AAAA"]["value"]
            lines.append(
                f'{indent}$dyndnsUpdate host="{host}" priv6addr={ipv6} key6="{key6}" key="{key4}" ip6addr=$ip6addr ipaddr=$ipaddr\n'
            )
        else:
            lines.append(
                f'{indent}$dyndnsUpdate host="{host}" key="{key4}" ip6addr=$ip6addr ipaddr=$ipaddr\n'
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

    result.append(f':global DynDNSSuffix6 "{router.dyndns_suffix_ipv6}"')
    result.append(f':global DynDNSHost "{host}"')
    result.append(f':global DynDNSKey "{get_dyndns_key(host, "A")}"')
    result.append(f':global DynDNSKey6 "{get_dyndns_key(host, "AAAA")}"')
    result.append(f':global DynDNSHost4 "{host_v4}"')
    result.append(f':global DynDNSKey4 "{get_dyndns_key(host_v4, "A")}"')

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
