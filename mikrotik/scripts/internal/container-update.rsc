# policy=read,write,policy,test

:global logputinfo

$logputinfo ("Disabling autoheal and waiting 10 seconds...")
/system/scheduler/disable container-autoheal
:delay 10s

/file/add name=container-update-all
/system/script/run container-autoheal

$logputinfo ("Waiting 10 seconds and re-enabling autoheal...")
:delay 10s
/system/scheduler/enable container-autoheal

# Recreate from sceatch:
#/container
#add name=haproxy root-dir=haproxy-root interface=veth-haproxy logging=yes mounts=haproxy-config start-on-boot=yes remote-image="ghcr.io/doridian/haproxytiny/haproxytiny:latest"
#add name=pdns root-dir=pdns-root interface=veth-dns logging=yes mounts=pdns-config,pdns-data start-on-boot=yes remote-image="ghcr.io/doridian/pdnstiny/pdnstiny:latest"
