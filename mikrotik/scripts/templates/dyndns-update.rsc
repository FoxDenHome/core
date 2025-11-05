# dontrequireperms=yes
# policy=ftp,read,write,policy,test
# schedule=00:05:00

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
:local ip6addr ([:toip6 ([:deserialize value=$ip6addrcidr from=dsv delimiter="/" options=dsv.plain]->0->0)] & ffff:ffff:ffff:ffff:fff0::)

:global DynDNSHost
:global DynDNSHost4
:global DynDNSKey
:global DynDNSKey4
:global DynDNSKey6
:global DynDNSSuffix6
:global DynDNSHostDNS
:global DynDNSKeyDNS
:global DynDNSKeyDNS6

:local isprimary 0
#[ /interface/vrrp/get vrrp-mgmt-gateway master ]
:if ($DynDNSHost = "router.foxden.network") do={
    :set isprimary 1
}

/system/script/run firewall-update

:global dyndnsUpdateOne do={
    :global logputdebug
    :global logputinfo
    :global logputerror

    $logputdebug ("[DynDNS] Beginning update of $updatehost $host")
    :if ($dns!="") do={
        :delay 1s
        :do {
            :local dnsip [:resolve $host type=$dnstype server=$dns]
            if ($dnsip=$ipaddr) do={
                $logputdebug ("[DynDNS] No change in IP address for $updatehost $host is $ipaddr")
                :return ""
            }
        } on-error={
            $logputerror ("[DynDNS] Unable to resolve $host using $dns type $dnstype")
            :return ""
        }
    }

    :delay 5s

    :do {
        :local result [/tool/fetch mode=$mode http-auth-scheme=basic url="$mode://$updatehost/api/dynamicURL/?q=$key&ip=$ipaddr" as-value output=user]
        $logputdebug ("[DynDNS] Result of $updatehost update for $host to $ipaddr: " . ($result->"data"))
    } on-error={
        $logputerror ("[DynDNS] Unable to update $updatehost update for $host to $ipaddr")
    }
}

:local dyndnsUpdate do={
  :global dyndnsUpdateOne
  $dyndnsUpdateOne host=$host key=$key dnstype=ipv4 updatehost="ipv4.cloudns.net" mode=https ipaddr=$ipaddr dns="pns41.cloudns.net"
  if ([:len $key6] > 0) do={
    :local masked6 ([:toip6 $priv6addr] & ::ffff:ffff:ffff:ffff:ffff)
    $dyndnsUpdateOne host=$host key=$key6 dnstype=ipv6 updatehost="ipv6.cloudns.net" mode="https" ipaddr=($ip6addr|$masked6) dns="pns41.cloudns.net"
  }
}

$dyndnsUpdate host=$DynDNSHost key=$DynDNSKey key6=$DynDNSKey6 priv6addr=$DynDNSSuffix6 ip6addr=$ip6addr ipaddr=$ipaddr
$dyndnsUpdate host=$DynDNSHost4 key=$DynDNSKey4 ipaddr=$ipaddr

if ($isprimary) do={
    # HOSTS #
}
