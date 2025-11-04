from subprocess import check_call
from json import load as json_load
from refresh.util import unlink_safe, NIX_DIR, mtik_path, get_ipv4_netname

FILENAME = mtik_path("scripts/gen-dhcp.rsc")

# TODO: Use API and diff in Python and then synchronize stuff instead of generating a big script (use comment as id)

def refresh_dhcp():
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#dhcp.json.router"])
    with open("result", "r") as file:
        dhcp_leases = json_load(file)
    unlink_safe("result")

    header_lines = [
        "/ip/dhcp-server/lease/set [find dynamic=no] comment=__REFRESHING__",
        "/ipv6/dhcp-server/binding/set [find dynamic=no] comment=__REFRESHING__",
        ":local prev",
    ]
    trailer_lines = [
        "/ip/dhcp-server/lease/remove [find comment=__REFRESHING__]",
        "/ipv6/dhcp-server/binding/remove [find comment=__REFRESHING__]"
    ]
    v4lines = []
    v6lines = []
    for lease in dhcp_leases:
        netname = get_ipv4_netname(lease["ipv4"])
        if "ipv4" not in lease:
            raise ValueError(f"Lease {lease} has no ipv4 address")

        addr_attrib = f'address={lease["ipv4"]}'
        id_attrib = f'mac-address={lease["mac"].upper()}'
        attribs = f'{id_attrib} {addr_attrib} comment="{lease["name"]}" lease-time=1d server=dhcp-{netname}'
        v4lines.append(f':set prev [find {addr_attrib}]\n' + \
                    f':if ([:len $prev] > 0)' + \
                    f' do={{\n  set $prev {attribs}\n}}' + \
                    f' else={{\n  remove [find ({addr_attrib} || {id_attrib})]\n  add {attribs}\n}}')

        if "ipv6" in lease:
            duid = lease["dhcpv6"]["duid"]
            iaid = lease["dhcpv6"]["iaid"]
            if duid is None or iaid is None:
                raise ValueError(f"Lease {lease} has incomplete dhcpv6 info")
            addr_attrib = f'address={lease["ipv6"]}'
            id_attrib = f'duid={duid} iaid={iaid}'
            attribs = f'{id_attrib} {addr_attrib} ia-type=na comment="{lease["name"]}" life-time=1d prefix-pool="" server=dhcp-{netname}'
            v6lines.append(f':set prev [find {addr_attrib}]\n' + \
                        f':if ([:len $prev] > 0)' + \
                        f' do={{\n  set $prev {attribs}\n}}' + \
                        f' else={{\n  remove [find ({addr_attrib} || {id_attrib})]\n  add {attribs}\n}}')

    with open(FILENAME, "w") as file:
        file.write(("\n".join(header_lines + ["/ip/dhcp-server/lease"] + sorted(v4lines) + ["/ipv6/dhcp-server/binding"] + sorted(v6lines) + trailer_lines)) + "\n")
