/container
add auto-restart-interval=15s dns=172.17.0.1 interface=veth-foxingress logging=yes mount=/foxingress:/config:ro name=foxingress \
    remote-image=git.foxden.network/foxden/foxingress:latest root-dir=/foxingress-root start-on-boot=yes workdir=/
