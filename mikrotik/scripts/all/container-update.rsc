:local git4 [:resolve type=ipv4 "git.foxden.network"]
:local git6 [:resolve type=ipv6 "git.foxden.network"]

:put "Adding static DNS entries for git.foxden.network to $git4 and $git6"
/ip/dns/static/add name="git.foxden.network" address=$git4 type=A comment=container-update
/ip/dns/static/add name="git.foxden.network" address=$git6 type=AAAA comment=container-update

:foreach container in=[/container/find] do={
    :local ctname [/container/get $container name]
    :put "Updating container: $ctname"
    /container/update $container
    :put "Waiting for container state to be running"
    :while (![/container/get $container running]) do={
        :delay 1
    }
}

:put "Removing static DNS entries for git.foxden.network"
/ip/dns/static/remove [ find comment=container-update ]
