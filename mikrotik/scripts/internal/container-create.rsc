/container
add auto-restart-interval=15s dns=172.17.0.1 interface=veth-foxingress logging=yes mount=/foxingress:/config:ro name=foxingress \
    remote-image=git.foxden.network/foxden/foxingress:latest root-dir=/foxingress-root start-on-boot=yes workdir=/
add auto-restart-interval=15s dns=127.0.0.1 interface=veth-dns logging=yes mount=\
    /pdns:/etc/pdns:ro,/pdns-data:/var/lib/powerdns:rw name=pdns remote-image=git.foxden.network/foxden/pdnstiny:latest root-dir=\
    /pdns-root start-on-boot=yes tmpfs=/dest:64.0MiB:0755 workdir=/
