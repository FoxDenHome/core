"""Makes the reverse DNS of the public IPs at OVH match nix (flake output
ipReverses.json, its "ovh" part)

Stateless like the ClouDNS sync: in every OVH IP block that holds an IP nix
names, it sets the reverses nix wants and deletes the ones it doesn't know.
Blocks without any IP from nix are left alone.
"""

import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from ipaddress import IPv4Network, IPv6Network, ip_address, ip_network

from dnssync import nix
from dnssync.ovh.api import ApiError, Client

SET = "set"
DELETE = "delete"
SYMBOLS = {SET: "+", DELETE: "-"}

# OVH refuses a reverse until the name resolves to the IP, which can take a bit
# right after the ClouDNS sync added the record
SET_ATTEMPTS = 7
SET_RETRY_DELAY = 10


@dataclass(frozen=True)
class Change:
    kind: str
    block: str
    ip: str
    reverse: str | None = None  # what it becomes (set)
    live: str | None = None  # what it was (set over an existing one, delete)

    def describe(self) -> str:
        if self.kind == DELETE:
            return f"- reverse {self.ip}: {self.live}"
        if self.live is None:
            return f"+ reverse {self.ip}: {self.reverse}"
        return f"~ reverse {self.ip}: {self.live}\n    => {self.reverse}"


@dataclass
class Plan:
    changes: list[Change]
    warnings: list[str]

    def count(self, kind: str) -> int:
        return sum(1 for c in self.changes if c.kind == kind)


def normalize_ip(ip: str) -> str:
    return str(ip_address(ip))


def normalize_name(name: str) -> str:
    return name.lower().rstrip(".") + "."


def load_desired() -> dict[str, str]:
    """Public IP => reverse, from nix"""
    reverses = nix.load_json("ipReverses.json").get("ovh", {})
    return desired_from(reverses)


def desired_from(reverses: dict[str, str]) -> dict[str, str]:
    """Drops private IPs (only nix and the routers serve those) and normalizes"""
    return {
        normalize_ip(ip): normalize_name(name)
        for ip, name in reverses.items()
        if ip_address(ip).is_global
    }


def block_of(ip: str, blocks: list[IPv4Network | IPv6Network]) -> str | None:
    """The smallest block that contains ip"""
    addr = ip_address(ip)
    found = [b for b in blocks if b.version == addr.version and addr in b]
    if not found:
        return None
    return str(max(found, key=lambda b: b.prefixlen))


def assign_blocks(
    desired: dict[str, str], blocks: list[str]
) -> tuple[dict[str, str], list[str]]:
    """IP => its block, and warnings for IPs that aren't in any"""
    nets = [ip_network(b, strict=False) for b in blocks]
    assigned: dict[str, str] = {}
    warnings: list[str] = []
    for ip in sorted(desired):
        block = block_of(ip, nets)
        if block is None:
            warnings.append(f"reverse {ip}: not in any OVH IP block, left alone")
        else:
            # Use OVH's spelling of the block in the API path
            assigned[ip] = next(
                b for b in blocks if str(ip_network(b, strict=False)) == block
            )
    return assigned, warnings


def plan(
    desired: dict[str, str],
    assigned: dict[str, str],
    live: dict[str, dict[str, str]],
) -> Plan:
    """Changes that make the live reverses (block => IP => reverse) of the
    blocks in assigned match desired"""
    changes: list[Change] = []
    for block in sorted(set(assigned.values())):
        have = {
            normalize_ip(ip): normalize_name(name)
            for ip, name in live.get(block, {}).items()
        }
        want = {ip: desired[ip] for ip, b in assigned.items() if b == block}
        for ip in sorted(want):
            if have.get(ip) != want[ip]:
                changes.append(Change(SET, block, ip, want[ip], have.get(ip)))
        for ip in sorted(set(have) - set(want)):
            changes.append(Change(DELETE, block, ip, live=have[ip]))
    return Plan(changes, [])


def fetch_live(client: Client, blocks: set[str]) -> dict[str, dict[str, str]]:
    with ThreadPoolExecutor(4) as pool:
        return dict(zip(blocks, pool.map(client.list_reverses, blocks)))


def load_plan(client: Client) -> Plan:
    desired = load_desired()
    assigned, warnings = assign_blocks(desired, client.list_blocks())
    live = fetch_live(client, set(assigned.values()))
    result = plan(desired, assigned, live)
    result.warnings = warnings + result.warnings
    return result


def apply_change(
    client: Client,
    change: Change,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    if change.kind == DELETE:
        client.delete_reverse(change.block, change.ip)
        return
    assert change.reverse is not None
    for attempt in range(SET_ATTEMPTS):
        try:
            client.set_reverse(change.block, change.ip, change.reverse)
            return
        except ApiError as e:
            if e.status != 400 or attempt == SET_ATTEMPTS - 1:
                raise
            print(f"  {e}, retrying in {SET_RETRY_DELAY}s")
            sleep(SET_RETRY_DELAY)
