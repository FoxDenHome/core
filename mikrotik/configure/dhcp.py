from json import load as json_load
from subprocess import check_output
from typing import Any

from configure.util import (
    NIX_DIR,
    ROUTERS,
    MTikRouter,
    format_mtik_bool,
    format_weird_mtik_ip,
    get_ipv4_netname,
    parse_mtik_bool,
)

IGNORE_CHANGES = {
    "id",
    "active-server",
    "active-address",
    "class-id",
    "host-name",
    "active-client-id",
    "expires-after",
    "last-seen",
    "status",
    "client-address",
    "active-mac-address",
    "dynamic",
    "invalid",
    "radius",
    "blocked",
}


def refresh_dhcp_router(dhcp_leases: list[dict[str, Any]], router: MTikRouter) -> None:
    print(f"## {router.host}")
    connection = router.connection()
    api = connection.get_api()
    api_dhcpv4 = api.get_resource("/ip/dhcp-server/lease")

    dhcpv4_leases = api_dhcpv4.get()
    dhcpv4_leases_map = {lease["id"]: lease for lease in dhcpv4_leases}
    stray_dhcpv4_leases = {lease["id"] for lease in dhcpv4_leases}

    for lease in dhcp_leases:
        if "ipv4" not in lease:
            raise ValueError(f"Lease {lease} has no IPv4 address")

        netname = get_ipv4_netname(lease["ipv4"])

        attribs = {
            "address": format_weird_mtik_ip(lease["ipv4"]),
            "mac-address": lease["mac"].upper(),
            "comment": lease["name"],
            "lease-time": "1d",
            "dhcp-option": "",
            "address-lists": "",
            "server": f"dhcp-{netname}",
            "disabled": format_mtik_bool(False),
        }

        matches = []
        for mtik_lease in dhcpv4_leases:
            if mtik_lease["server"] != attribs["server"]:
                continue

            if (
                (mtik_lease["address"] == attribs["address"])
                or (mtik_lease["mac-address"].upper() == attribs["mac-address"])
                or (mtik_lease.get("comment", "") == attribs["comment"])
            ):
                matches.append(mtik_lease)
                stray_dhcpv4_leases.discard(mtik_lease["id"])

        match = None
        if len(matches) == 1:
            match = matches[0]
        elif len(matches) > 1:
            match = matches[0]
            for m in matches[1:]:
                print("Removing duplicate DHCPv4 lease", m)
                api_dhcpv4.remove(id=m["id"])

        if match is None:
            print("Adding new DHCPv4 lease", attribs)
            api_dhcpv4.add(**attribs)
        elif parse_mtik_bool(match.get("dynamic", "false")):
            print("Re-creating new DHCPv4 lease over dynamic", attribs)
            api_dhcpv4.remove(id=match["id"])
            api_dhcpv4.add(**attribs)
        else:
            all_keys = set(match.keys()).union(set(attribs.keys()))

            for match_key in all_keys:
                if match_key in IGNORE_CHANGES or match_key[0] == ".":
                    continue

                if match.get(match_key, "") == attribs.get(match_key, ""):
                    continue

                print("Updating DHCPv4 lease", match, "to", attribs, "on", match_key)
                api_dhcpv4.set(id=match["id"], **attribs)
                break

    for lease_id in stray_dhcpv4_leases:
        lease = dhcpv4_leases_map[lease_id]
        if not parse_mtik_bool(lease.get("dynamic", "false")):
            print("Removing stray DHCPv4 lease", lease)
            api_dhcpv4.remove(id=lease_id)


def refresh_dhcp() -> None:
    result = (
        check_output(
            [
                "nix",
                "build",
                f"{NIX_DIR}#dhcp.json.router",
                "--no-link",
                "--print-out-paths",
            ]
        )
        .strip()
        .decode("utf-8")
    )
    with open(result, "r") as file:
        dhcp_leases = json_load(file)

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        refresh_dhcp_router(dhcp_leases, router)
