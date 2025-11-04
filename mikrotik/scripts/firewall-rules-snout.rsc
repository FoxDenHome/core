/ip/firewall/filter
add action=reject chain=forward comment=invalid connection-state=invalid reject-with=icmp-admin-prohibited
add action=fasttrack-connection chain=forward comment="related, established" connection-state=established,related hw-offload=yes
add action=accept chain=forward comment="related, established" connection-state=established,related
add action=accept chain=forward protocol=icmp

/ipv6/firewall/filter
add action=reject chain=forward comment=invalid connection-state=invalid reject-with=icmp-admin-prohibited
add action=fasttrack-connection chain=forward comment="related, established" connection-state=established,related
add action=accept chain=forward comment="related, established" connection-state=established,related
add action=accept chain=forward protocol=icmpv6

/ip/firewall/nat
add disabled=yes action=endpoint-independent-nat chain=srcnat out-interface=wan protocol=udp randomise-ports=yes
add action=masquerade chain=srcnat comment=WAN out-interface=wan
add action=masquerade chain=srcnat comment=cghmn dst-address=!100.96.41.0/24 out-interface-list=iface-cghmn src-address=!100.96.41.0/24
add action=masquerade chain=srcnat comment=Containers src-address=172.17.0.0/16
add action=jump chain=dstnat comment=Hairpin dst-address=127.1.1.1 jump-target=port-forward
add action=jump chain=dstnat comment="Local forward" dst-address-list=local-ip in-interface-list=zone-local jump-target=local-port-forward
add action=jump chain=dstnat comment=External in-interface-list=zone-wan jump-target=port-forward
add action=dst-nat chain=local-port-forward comment="DNS TCP" dst-port=53,530 protocol=tcp to-addresses=172.17.2.2
add action=dst-nat chain=local-port-forward comment="DNS UDP" dst-port=53,530 protocol=udp to-addresses=172.17.2.2
add action=dst-nat chain=local-port-forward comment="HAProxy TCP" dst-port=9001 protocol=tcp to-addresses=172.17.0.2
add action=dst-nat chain=port-forward comment="HAProxy TCP (Pub)" dst-port=80,443 protocol=tcp to-addresses=172.17.0.2
add action=dst-nat chain=port-forward comment="HAProxy UDP (Pub)" dst-port=443 protocol=udp to-addresses=172.17.0.2

/ipv6/firewall/nat
add action=jump chain=dstnat comment="Local forward" dst-address-list=local-ip in-interface-list=zone-local jump-target=local-port-forward
add action=src-nat chain=srcnat comment="VPN Masq" dst-address=!fd2c:f4cb:63be::/60 in-interface=wg-vpn to-address=fd2d::ffff/128
add action=netmap chain=dstnat comment="Ingress PT" dst-address=fd2d::/60 to-address=fd2c:f4cb:63be::/60
add action=netmap chain=srcnat comment="Egress PT" dst-address=!fd2c:f4cb:63be::/60 in-interface-list=zone-local src-address=fd2c:f4cb:63be::/60 to-address=fd2d::/60
add action=dst-nat chain=local-port-forward comment="DNS TCP" dst-port=53,530 protocol=tcp to-address=fd2c:f4cb:63be::ac11:0202/128
add action=dst-nat chain=local-port-forward comment="DNS UDP" dst-port=53,530 protocol=udp to-address=fd2c:f4cb:63be::ac11:0202/128
add action=dst-nat chain=local-port-forward comment="HAProxy TCP" dst-port=9001 protocol=tcp to-address=fd2c:f4cb:63be::ac11:0002/12
