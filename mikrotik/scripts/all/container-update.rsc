:local gitip [:resolve type=ipv4 "git.foxden.network"]

:put "Adding static DNS entry for git.foxden.network to $gitip, disabling FWD"
/ip/dns/static/add name="git.foxden.network" address=$gitip type=A comment=container-update
/ip/dns/static/disable [ find type=FWD ]

:foreach container in=[/container/find] do={
    :local ctname [/container/get $container name]
    :put "Updating container: $ctname"
    /container/update $container
    :put "Waiting for container state to be running"
    :while (![/container/get $container running]) do={
        :delay 1
    }
}

:put "Removing static DNS entry for git.foxden.network, enabling FWD"
/ip/dns/static/enable [ find type=FWD ]
/ip/dns/static/remove [ find comment=container-update ]
