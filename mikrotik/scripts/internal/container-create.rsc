/container
add dns=172.17.0.1 name=haproxy root-dir=haproxy-root interface=veth-haproxy logging=yes mount=/haproxy:/etc/haproxy:ro start-on-boot=yes remote-image="git.foxden.network/foxden/haproxytiny:latest"
add dns=127.0.0.1 name=pdns root-dir=pdns-root interface=veth-dns logging=yes mount=/pdns:/etc/pdns:ro,/pdns-data:/var/lib/powerdns:rw start-on-boot=yes remote-image="git.foxden.network/foxden/pdnstiny:latest"
