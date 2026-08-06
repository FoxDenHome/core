/container
add restart-policy=always restart-interval=15s dns=172.17.0.1 interface=veth-foxingress logging=yes mount=/foxingress:/config:ro name=foxingress \
    remote-image=git.foxden.network/foxden/foxingress:latest root-dir=/foxingress-root start-on-boot=yes workdir=/
add restart-policy=always restart-interval=15s dns=172.18.0.1 interface=veth-foxmail logging=yes mount=/foxmail:/config:ro,/foxmail-data:/data:rw name=foxmail \
    remote-image=git.foxden.network/foxden/foxmail:latest root-dir=/foxmail-root start-on-boot=yes workdir=/
