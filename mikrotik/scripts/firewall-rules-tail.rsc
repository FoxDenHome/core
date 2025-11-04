/ip/firewall/filter
add action=accept chain=forward in-interface-list=zone-local out-interface-list=zone-wan
add action=accept chain=forward in-interface=oob
add action=accept chain=forward in-interface=wg-vpn
add action=accept chain=forward comment="DNS TCP" dst-port=53,530 in-interface-list=zone-local out-interface=veth-dns protocol=tcp
add action=accept chain=forward comment="DNS UDP" dst-port=53,530 in-interface-list=zone-local out-interface=veth-dns protocol=udp
add action=accept chain=forward comment="HAProxy TCP (Pub)" dst-port=80,443 out-interface=veth-haproxy protocol=tcp
add action=accept chain=forward comment="HAProxy UDP (Pub)" dst-port=443 out-interface=veth-haproxy protocol=udp
add action=accept chain=forward comment="HAProxy TCP" dst-port=9001 in-interface-list=zone-local out-interface=veth-haproxy protocol=tcp
add action=reject chain=forward reject-with=icmp-admin-prohibited

add action=accept chain=input connection-state=established,related
add action=accept chain=input protocol=ipv6-encap
add action=accept chain=input protocol=icmp
add action=accept chain=input comment="HTTP(S)" dst-port=80,443 protocol=tcp
add action=accept chain=input comment=BGP dst-port=179 protocol=tcp
add action=accept chain=input comment=WireGuard dst-port=13231-13232 protocol=udp
add action=accept chain=input in-interface=lo
add action=accept chain=input in-interface=oob
add action=accept chain=input in-interface-list=zone-local
add action=reject chain=input reject-with=icmp-admin-prohibited

/ipv6/firewall/filter
add action=accept chain=forward in-interface-list=zone-local out-interface-list=zone-wan
add action=accept chain=forward in-interface=oob
add action=accept chain=forward in-interface=wg-vpn
add action=accept chain=forward comment=DNS dst-port=53,530 in-interface-list=zone-local out-interface=veth-dns protocol=tcp
add action=accept chain=forward comment=DNS dst-port=53,530 in-interface-list=zone-local out-interface=veth-dns protocol=udp
add action=accept chain=forward comment=HAProxy dst-port=80,443 out-interface=veth-haproxy protocol=tcp
add action=accept chain=forward comment=HAProxy dst-port=443 out-interface=veth-haproxy protocol=udp
add action=reject chain=forward reject-with=icmp-admin-prohibited

add action=accept chain=input connection-state=established,related
add action=accept chain=input protocol=icmpv6
add action=accept chain=input comment="HTTP(S)" dst-port=80,443 protocol=tcp
add action=accept chain=input comment=BGP dst-port=179 protocol=tcp
add action=accept chain=input comment=WireGuard dst-port=13231-13232 protocol=udp
add action=accept chain=input in-interface=lo
add action=accept chain=input in-interface=oob
add action=accept chain=input in-interface-list=zone-local
add action=reject chain=input reject-with=icmp-admin-prohibited
