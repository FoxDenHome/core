# dont-require-permissions=true
# policy=read,write,policy,test
# schedule=15m

:local isprimary 0
:if ([ /interface/vrrp/get vrrp-mgmt-gateway master ]) do={
    :set isprimary 1
}

:local emlbody "Found the following Matter-ULA prefixes:\r\n"
:local foundissue 0
# Note that this is my specific ExtPANID
:foreach neigh in=[/ipv6/neighbor/find where address in fd6e:50bc:0340:4bde::/64] do={
    :local neighobj [/ipv6/neighbor/get $neigh]
    :local neighstr ("IPv6: " . $neighobj->"address" . "; MAC: " . $neighobj->"mac-address" . "; INTF: " . $neighobj->"interface")
    :set emlbody "$emlbody$neighstr\r\n"
    :set foundissue 1
}

:if ($foundissue > 0) do={
    :log warn "$emlbody"
    :if ($isprimary) do={
        /tool/e-mail/send to=alerts@doridian.net subject="Matter-ULA prefix prefix(es) found" body="$emlbody"
    }
}
