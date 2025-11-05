from subprocess import check_call
from json import load as json_load
from refresh.util import unlink_safe, NIX_DIR, mtik_path, MTikUser

FILENAME = mtik_path("scripts/gen-firewall.rsc")

# TODO: Use API and diff in Python and then synchronize stuff instead of generating a big script (use comment as id)

def is_ipv6(addr: str) -> bool:
    return "." not in addr

def refresh_firewall(user: MTikUser) -> None:
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#firewall.json.router"])
    with open("result", "r") as file:
        firewall_rules = json_load(file)
    unlink_safe("result")

    snout_lines = [
        '/ip/firewall/filter/remove [find dynamic=no]',
        '/ip/firewall/mangle/remove [find dynamic=no]',
        '/ip/firewall/nat/remove [find dynamic=no]',
        '/ipv6/firewall/filter/remove [find dynamic=no]',
        '/ipv6/firewall/mangle/remove [find dynamic=no]',
        '/ipv6/firewall/nat/remove [find dynamic=no]',
        '/system/script/run firewall-rules-snout',
    ]
    tail_lines = [
        '/system/script/run firewall-rules-tail',
    ]
    lines = []
    for rule in firewall_rules:
        def optval(name: str, valname: str) -> str:
            val = rule.get(valname, "")
            return f' {name}={val}' if val else ''
        addr = rule.get("source", rule.get("destination", rule.get("toAddresses", None)))
        if addr is not None:
            families = ["ipv6" if is_ipv6(addr) else "ip"]
        else:
            families = ["ip", "ipv6"]

        chain = rule["chain"]
        if chain == "postrouting":
            chain = "srcnat"
        elif chain == "prerouting":
            chain = "dstnat"
        action = rule["action"]
        if action == "dnat":
            action = "dst-nat"
        elif action == "snat":
            action = "src-nat"

        for family in families:
            lines.append(f'/{family}/firewall/{rule["table"]}/add chain="{chain}" comment="{rule.get("comment","")}"{optval("dst-address", "destination")}{optval("dst-port", "dstport")}{optval("protocol", "protocol")}{optval("src-address", "source")}{optval("src-port", "srcport")}{optval("jump-target", "jumpTarget")}{optval("to-addresses", "toAddresses")}{optval("to-ports", "toPorts")}{optval("reject-with", "rejectWith")} action={action}')
    with open(FILENAME, "w") as file:
        file.write(("\n".join(snout_lines + lines + tail_lines)) + "\n")
