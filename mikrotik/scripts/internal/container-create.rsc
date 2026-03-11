/container
add auto-restart-interval=15s dns=172.17.0.1 interface=veth-haproxy logging=yes mount=/haproxy:/etc/haproxy:ro name=haproxy \
    remote-image=git.foxden.network/foxden/haproxytiny:latest root-dir=/haproxy-root start-on-boot=yes tmpfs=/dest:64.0MiB:0755 workdir=/
add auto-restart-interval=15s dns=127.0.0.1 interface=veth-dns logging=yes mount=\
    /pdns:/dest/etc/pdns:ro,/pdns-data:/dest/var/lib/powerdns:rw name=pdns remote-image=git.foxden.network/foxden/pdnstiny:latest root-dir=\
    /pdns-root start-on-boot=yes tmpfs=/dest:64.0MiB:0755 workdir=/
