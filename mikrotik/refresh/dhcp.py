from subprocess import check_call
from json import load as json_load
from refresh.util import unlinkSafe, NIX_DIR, getIPv4NetName, MTikRouter, ROUTERS, parseMTikBool, formatMTikBool, formatWeirdMTikIP
from typing import Any

IGNORE_CHANGES = {"id", "active-server", "active-address", "class-id", "host-name", "active-client-id", "expires-after", "last-seen", "status", "client-address", "active-mac-address", "dynamic", "invalid", "radius", "blocked"}

def refresh_dhcp_router(dhcp_leases: list[dict[str, Any]], router: MTikRouter) -> None:
    print(f"## {router.host}")
    connection = router.connection()
    api = connection.get_api()
    api_dhcpv4 = api.get_resource('/ip/dhcp-server/lease')
    api_dhcpv6 = api.get_resource('/ipv6/dhcp-server/binding')

    dhcpv4_leases = api_dhcpv4.get()
    dhcpv4_leases_map = {lease['id']: lease for lease in dhcpv4_leases}
    stray_dhcpv4_leases = set([lease["id"] for lease in dhcpv4_leases])

    dhcpv6_bindings = api_dhcpv6.get()
    dhcpv6_bindings_map = {binding['id']: binding for binding in dhcpv6_bindings}
    stray_dhcpv6_bindings = set([binding["id"] for binding in dhcpv6_bindings])

    for lease in dhcp_leases:
        if "ipv4" not in lease:
            raise ValueError(f"Lease {lease} has no IPv4 address")

        netname = getIPv4NetName(lease["ipv4"])

        attribs = {
            "address": formatWeirdMTikIP(lease["ipv4"]),
            "mac-address": lease["mac"].upper(),
            "comment": lease["name"],
            "lease-time": "1d",
            "dhcp-option": "",
            "address-lists": "",
            "server": f"dhcp-{netname}",
            "disabled": formatMTikBool(False),
        }

        matches = []
        for mtik_lease in dhcpv4_leases:
            if mtik_lease["server"] != attribs["server"]:
                continue

            if (mtik_lease["address"] == attribs["address"]) or \
                (mtik_lease["mac-address"].upper() == attribs["mac-address"]) or \
                (mtik_lease.get("comment", "") == attribs["comment"]):
                matches.append(mtik_lease)
                stray_dhcpv4_leases.discard(mtik_lease["id"])

        match = None
        if len(matches) == 1:
            match = matches[0]
        elif len(matches) > 1:
            match = matches[0]
            for m in matches[1:]:
                print("Removing duplicate DHCPv4 lease", m)
                api_dhcpv4.remove(id=m['id'])

        if match is None:
            print("Adding new DHCPv4 lease", attribs)
            api_dhcpv4.add(**attribs)
        elif parseMTikBool(match.get("dynamic", "false")):
            print("Re-creating new DHCPv4 lease over dynamic", attribs)
            api_dhcpv4.remove(id=match['id'])
            api_dhcpv4.add(**attribs)
        else:
            all_keys = set(match.keys()).union(set(attribs.keys()))

            for match_key in all_keys:
                if match_key in IGNORE_CHANGES or match_key[0] == ".":
                    continue

                if match.get(match_key, "") == attribs.get(match_key, ""):
                    continue

                print("Updating DHCPv4 lease", match, "to", attribs, "on", match_key)
                api_dhcpv4.set(id=match['id'], **attribs)
                break

        if "ipv6" not in lease:
            continue

        attribs = {
            "address": formatWeirdMTikIP(lease["ipv6"]),
            "duid": lease["dhcpv6"]["duid"].lower(),
            "iaid": str(lease["dhcpv6"]["iaid"]),
            "life-time": "1d",
            "prefix-pool": "",
            "dhcp-option": "",
            "address-lists": "",
            "ia-type": "na",
            "comment": lease["name"],
            "server": f"dhcp-{netname}",
            "disabled": formatMTikBool(False),
        }

        matches = []
        for mtik_binding in dhcpv6_bindings:
            if mtik_binding["server"] != attribs["server"]:
                continue

            if (mtik_binding["address"] == attribs["address"]) or \
                ((mtik_binding["duid"].lower() == attribs["duid"]) and (mtik_binding["iaid"] == attribs["iaid"])) or \
                (mtik_binding.get("comment", "") == attribs["comment"]):
                matches.append(mtik_binding)
                stray_dhcpv6_bindings.discard(mtik_binding["id"])

        match = None
        if len(matches) == 1:
            match = matches[0]
        elif len(matches) > 1:
            match = matches[0]
            for m in matches[1:]:
                print("Removing duplicate DHCPv6 binding", m)
                api_dhcpv6.remove(id=m['id'])

        if match is None:
            print("Adding new DHCPv6 binding", attribs)
            api_dhcpv6.add(**attribs)
        elif parseMTikBool(match.get("dynamic", "false")):
            print("Re-creating new DHCPv6 binding over dynamic", attribs)
            api_dhcpv6.remove(id=match['id'])
            api_dhcpv6.add(**attribs)
        else:
            all_keys = set(match.keys()).union(set(attribs.keys()))
            for match_key in all_keys:
                if match_key in IGNORE_CHANGES or match_key[0] == ".":
                    continue
                if match.get(match_key, "") == attribs.get(match_key, ""):
                    continue

                print("Updating DHCPv6 binding", match, "to", attribs, "on", match_key)
                api_dhcpv6.set(id=match['id'], **attribs)
                break

    for lease_id in stray_dhcpv4_leases:
        lease = dhcpv4_leases_map[lease_id]
        if not parseMTikBool(lease.get("dynamic", "false")):
            print("Removing stray DHCPv4 lease", lease)
            api_dhcpv4.remove(id=lease_id)

    for binding_id in stray_dhcpv6_bindings:
        binding = dhcpv6_bindings_map[binding_id]
        if not parseMTikBool(binding.get("dynamic", "false")):
            print("Removing stray DHCPv6 binding", binding)
            api_dhcpv6.remove(id=binding_id)

def refresh_dhcp() -> None:
    unlinkSafe("result")
    check_call(["nix", "build", f"{NIX_DIR}#dhcp.json.router"])
    with open("result", "r") as file:
        dhcp_leases = json_load(file)
    unlinkSafe("result")

    for router in ROUTERS:
        refresh_dhcp_router(dhcp_leases, router)
