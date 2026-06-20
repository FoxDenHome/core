:local ipaddrfind [ /ip/address/find interface=wan ]
:if ([:len $ipaddrfind] < 1) do={
    :log warning "No WAN IPv4 address found"
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
:local ip6addr ([:toip6 ([:deserialize value=$ip6addrcidr from=dsv delimiter="/" options=dsv.plain]->0->0)] & ffff:ffff:ffff:ffff:fff0::)

# BEGIN update hairpins
:local ip6ptnet "$ip6addr/60"
:local ip6vpnaddr ($ip6addr | ::a64:ffff)
:local ip6vpnnet "$ip6vpnaddr/128"
/ip/firewall/nat/set [ find comment="Hairpin" dst-address!=$ipaddr ] dst-address=$ipaddr

:for ip6idx from=0 to=15 do={
    :local ip6idxhex [:pick "0123456789abcdef" $ip6idx]
    :local ip6idxaddr ($ip6addr | [:toip6 "::$ip6idxhex:0:0:0:0"])
    :local ip6idxnet "$ip6idxaddr/112"
    :local ip6idxcmt "PT Net $ip6idx"
    :local ip6idxnetfind [ /ipv6/firewall/address-list/find list=ipv6-dhcp-ranges comment=$ip6idxcmt ]
    :if ([:len $ip6idxnetfind] != 1) do={
        :if ([:len $ip6idxnetfind] > 0) do={
            /ipv6/firewall/address-list/remove $ip6idxnetfind
        }
        /ipv6/firewall/address-list/add list=ipv6-dhcp-ranges comment=$ip6idxcmt address=$ip6idxnet
    } else={
        :if ([/ipv6/firewall/address-list/get ($ip6idxnetfind->0) address] != $ip6idxnet) do={
            /ipv6/firewall/address-list/set address=$ip6idxnet $ip6idxnetfind
        }
    }
}

/ipv6/firewall/nat/set [ find comment="Egress PT" to-address!=$ip6ptnet ] to-address=$ip6ptnet
/ipv6/firewall/nat/set [ find comment="VPN Masq" to-address!=$ip6vpnnet ] to-address=$ip6vpnnet
# END update hairpins

:local isprimary 0
#[ /interface/vrrp/get vrrp-mgmt-gateway master ]
:if ([/system/identity/get name] = "router") do={
    :set isprimary 1
}

:local dyndnsUpdate do={
    :local dyndnsUpdateOne do={
        :local logputerror do={
            :log error $1
            :put $1
        }

        :delay 1s
        :put ("[DynDNS] Beginning update of $host $dnstype to $ipaddr")
        :do {
            :local srvip [:resolve "ns1.he.net" type=$dnstype]
            :local dnsip [:resolve $host type=$dnstype server=$srvip]
            if ($dnsip=$ipaddr) do={
                :put ("[DynDNS] IP address already up to date for $host $dnstype")
                :return ""
            }
        } on-error={
            $logputerror ("[DynDNS] Unable to resolve current IP for $host $dnstype")
            :return ""
        }

        :delay 5s

        :do {
            :local result [/tool/fetch mode=https user="$host" password="$key" url="https://dyn.dns.he.net/nic/update?hostname=$host&myip=$ipaddr" as-value output=user]
            :put ("[DynDNS] Result of $host $dnstype to $ipaddr: " . ($result->"data"))
        } on-error={
            $logputerror ("[DynDNS] Unable to update $host $dnstype to $ipaddr")
        }
    }

    $dyndnsUpdateOne host=$host key=$key dnstype=ipv4 ipaddr=$ipaddr dns="ns1.he.net"
    if ([:len $priv6addr] > 0) do={
        :local masked6 ([:toip6 $priv6addr] & ::ffff:ffff:ffff:ffff:ffff)
        $dyndnsUpdateOne host=$host key=$key dnstype=ipv6 ipaddr=($ip6addr|$masked6) dns="ns1.he.net"
    }
}

# SPECIAL HOSTS #

if ($isprimary) do={
    # HOSTS #
}
