# dont-require-permissions=true
# policy=read,write,policy,test
# run-on-change=true
# schedule=startup

:global logputdebug do={
    :log debug $1
    :put $1
}
:global logputinfo do={
    :log info $1
    :put $1
}
:global logputwarning do={
    :log warning $1
    :put $1
}
:global logputerror do={
    :log error $1
    :put $1
}

:global wakehost do={
    :local host $1
    :local lease [/ip/dhcp-server/lease/find comment=$host]
    :local macaddr [/ip/dhcp-server/lease/get $lease mac-address]
    :local server [/ip/dhcp-server/lease/get $lease server]
    :local iface [/ip/dhcp-server/get $server interface]

    :put "Host: $host; MAC: $macaddr; Interface: $iface"
    /tool/wol mac=$macaddr interface=$iface
}
