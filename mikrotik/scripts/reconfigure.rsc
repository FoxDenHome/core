/system/script/run firewall-update
:put Done

:do {
    /file/add name=container-restart-all
} on-error={}
