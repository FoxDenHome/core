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
