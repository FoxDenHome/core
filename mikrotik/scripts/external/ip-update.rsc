# policy=read,write,policy,test,sensitive
# schedule=15s

:local IPRouter [ /interface/wireguard/peers/get [ find name="router" ] current-endpoint-address ]
:local IPRouterBackup [ /interface/wireguard/peers/get [ find name="router-backup" ] current-endpoint-address ]

:if ( $IPRouterBackup != "" ) do={
    /interface/6to4/set [ find comment="router-backup" remote-address!="$IPRouterBackup" ] remote-address="$IPRouterBackup"
    :put "Set router-backup to $IPRouterBackup"
}

:if ( $IPRouter != "" ) do={
    /interface/6to4/set [ find comment="router" remote-address!="$IPRouter" ] remote-address="$IPRouter"
    :put "Set router to $IPRouter"
}
