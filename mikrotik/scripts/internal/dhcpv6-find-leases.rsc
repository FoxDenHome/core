:foreach bid in=[/ipv6/dhcp-server/binding/find dynamic] do={
    :local binding [/ipv6/dhcp-server/binding/get $bid]
    :local macfind [/ipv6/neighbor/find address=$binding->"client-address"]
    :if ([:len $macfind] > 0) do={
        :local macaddr [/ipv6/neighbor/get ($macfind->0)  mac-address]
        :local dhcpfind [/ip/dhcp-server/lease/find mac-address=$macaddr dynamic=no]
        :if ([:len $dhcpfind] > 0) do={
            :put ("mac=".$macaddr." duid=".$binding->"duid"." iaid=".$binding->"iaid")
        }
    }
}
