# dont-require-permissions=true
# policy=read,write,policy,test
# run-on-change=true
# schedule=startup

:global wakehost do={
    :local host $1
    :local lease [/ip/dhcp-server/lease/find comment=$host]
    :local macaddr [/ip/dhcp-server/lease/get $lease mac-address]
    :local server [/ip/dhcp-server/lease/get $lease server]
    :local iface [/ip/dhcp-server/get $server interface]

    :put "Host: $host; MAC: $macaddr; Interface: $iface"
    /tool/wol mac=$macaddr interface=$iface
}
