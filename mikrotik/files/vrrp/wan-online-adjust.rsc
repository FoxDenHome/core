# This script may not depend on globals as netwatch doesn't seem to be able to see them...

:local VRRPPriorityCurrent # VRRP PRIORITY OFFLINE #

if ([/system/script/find name=local-maintenance-mode ]) do={
    :log warning "Maintenance mode ON"
    :put "Maintenance mode ON"
} else={
    :local defgwidx [ /ip/route/find dynamic active dst-address=0.0.0.0/0 ]
    if ([:len $defgwidx] > 0) do={
        :local status [ /tool/netwatch/get [ /tool/netwatch/find comment="monitor-default" ] status ]
        if ($status = "up") do={
            :set VRRPPriorityCurrent # VRRP PRIORITY ONLINE #
        }
    }
}

:put "Set VRRP priority $VRRPPriorityCurrent"
/interface/vrrp/set [ /interface/vrrp/find priority!=$VRRPPriorityCurrent ] priority=$VRRPPriorityCurrent
