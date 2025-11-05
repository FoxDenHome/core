# dontrequireperms=yes
# policy=read,write,policy,test
# schedule=00:01:00

:global logputwarning

:global VRRPPriorityOffline
:global VRRPPriorityOnline
:local VRRPPriorityCurrent $VRRPPriorityOffline

if ([/system/script/find name=local-maintenance-mode ]) do={
    $logputwarning "Maintenance mode ON"
} else={
    :local defgwidx [ /ip/route/find dynamic active dst-address=0.0.0.0/0 ]
    if ([:len $defgwidx] > 0) do={
        :local status [ /tool/netwatch/get [ /tool/netwatch/find comment="monitor-default" ] status ]
        if ($status = "up") do={
            :set VRRPPriorityCurrent $VRRPPriorityOnline
        }
    }
}

:put "Set VRRP priority $VRRPPriorityCurrent"
/interface/vrrp/set [ /interface/vrrp/find priority!=$VRRPPriorityCurrent ] priority=$VRRPPriorityCurrent
