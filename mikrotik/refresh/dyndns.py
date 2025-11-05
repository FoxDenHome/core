import re
from subprocess import check_output
from json import loads as json_loads
from urllib.parse import parse_qs, urlparse
from refresh.util import mtik_path, ROUTERS

TEMPLATE = mtik_path("scripts/templates/dyndns-update.rsc")
FILENAME = mtik_path("scripts/dyndns-update.rsc")

SPECIAL_HOSTS = list(ROUTERS) + [f"v4-{router}" for router in ROUTERS]

_dyndns_hosts_value = None
def load_dyndns_hosts():
    global _dyndns_hosts_value
    if _dyndns_hosts_value is not None:
        return _dyndns_hosts_value

    output = check_output(["tofu", "output", "-show-sensitive", "-json"], cwd="../terraform/domains").decode("utf-8")
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

def get_dyndns_url(host: str, record_type: str) -> str:
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
            lines.append(f'{indent}$dyndnsUpdate host="{host}" priv6addr={ipv6} key6="{key6}" key="{key4}" ip6addr=$ip6addr ipaddr=$ipaddr\n')
        else:
            lines.append(f'{indent}$dyndnsUpdate host="{host}" key="{key4}" ip6addr=$ip6addr ipaddr=$ipaddr\n')
    return lines

def write_dyndns_script():
    with open(TEMPLATE, "r") as file:
        lines = file.readlines()
    
    outlines = []
    found_hosts = False
    for line in lines:
        line_strip = line.strip()
        if line_strip == "# HOSTS #":
            if found_hosts:
                raise RuntimeError("Multiple # HOSTS # found in script")
            indent = re.match(r"^(\s*)", line).group(1)
            found_hosts = True
            outlines += write_all_hosts(indent)
            continue
        outlines.append(line)

    if not found_hosts:
        raise RuntimeError("No # BEGIN HOSTS found in script")

    with open(FILENAME, "w") as file:
        file.writelines(outlines)

#$dyndnsUpdate host=$DynDNSHost key=$DynDNSKey key6=$DynDNSKey6
#$dyndnsUpdate host=$DynDNSHost4 key=$DynDNSKey4 
#$dyndnsUpdate host=$DynDNSHostDNS key=$DynDNSKeyDNS key6=$DynDNSKeyDNS6
def print_local_dyndns_settings(host: str):
    host_4 = f"v4-{host}"

    print(f":global DynDNSHost \"{host}\"")
    print(f":global DynDNSKey \"{get_dyndns_key(host, 'A')}\"")
    print(f":global DynDNSKey6 \"{get_dyndns_key(host, 'AAAA')}\"")

    print(f":global DynDNSHost4 \"{host_4}\"")
    print(f":global DynDNSKey4 \"{get_dyndns_key(host_4, 'A')}\"")

def refresh_dyndns():
    write_dyndns_script()
    for router in ROUTERS:
        print(f"## {router}")
        print_local_dyndns_settings(router)
        print()
