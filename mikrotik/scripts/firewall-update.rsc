# dontrequireperms=yes
# policy=read,write,policy,test

:local ipaddrfind [ /ip/address/find interface=wan ]
:if ([:len $ipaddrfind] < 1) do={
    :log warning "No WAN IP address found"
    :exit
}
:local ipaddrcidr [/ip/address/get ($ipaddrfind->0) address]
:local ipaddr ([:deserialize value=$ipaddrcidr from=dsv delimiter="/" options=dsv.plain]->0->0)

:local ip6addrfind [ /ipv6/address/find interface=wan !(address in fe80::/64) !(address in fc00::/7) ]
:if ([:len $ip6addrfind] < 1) do={
    :log warning "No WAN IPv6 address found"
    :exit
}
:local ip6addrcidr [/ipv6/address/get ($ip6addrfind->0) address]
:local ip6addr ([:deserialize value=$ip6addrcidr from=dsv delimiter="/" options=dsv.plain]->0->0)

/ip/firewall/nat/set [ find comment="Hairpin" dst-address!=$ipaddr ] dst-address=$ipaddr

:local ip6ptaddr ([:toip6 $ip6addr] & ffff:ffff:ffff:ffff:fff0::)
:local ip6ptnet "$ip6ptaddr/60"

:local ip6vpnaddr ($ip6ptaddr | ::a64:ffff)
:local ip6vpnnet "$ip6vpnaddr/128"

/ipv6/firewall/nat/set [ find comment="Ingress PT" dst-address!=$ip6ptnet ] dst-address=$ip6ptnet
/ipv6/firewall/nat/set [ find comment="Egress PT" to-address!=$ip6ptnet ] to-address=$ip6ptnet
/ipv6/firewall/nat/set [ find comment="VPN Masq" to-address!=$ip6vpnnet ] to-address=$ip6vpnnet
