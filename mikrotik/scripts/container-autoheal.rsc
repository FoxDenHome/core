# policy=read,write,policy,test
# schedule=1m

:global logputinfo
:global logputerror

:local needrestart ([:len [/file/find name=container-restart-all]] > 0)
:local needupdate ([:len [/file/find name=container-update-all]] > 0)
:local clearrestart $needrestart
:local clearupdate $needupdate
:local hidestartok true
:local maxtries 0

:if ($needupdate) do={
  $logputinfo ("Need update!")
  :set needrestart true
}

:if ($needrestart) do={
  $logputinfo ("Need restart!")
}

/container
:foreach ct in=[find] do={
  :local ctneedstop $needrestart
  :if (![get $ct running]) do={
    :set ctneedstop true
  }
  :if ([get $ct stopped]) do={
    :set ctneedstop false
  }

  :if ($ctneedstop) do={
    $logputinfo ("STOPPING container " . [get $ct name])
    stop $ct

    :set maxtries 50
    :while ($maxtries > 0) do={
      :delay 100ms
      :set maxtries ($maxtries - 1)
      :if ([get $ct stopped]) do={
        :set maxtries -999
      }
    }
    :if ($maxtries != -999) do={
      $logputerror ("FAILED STOPPING container " . [get $ct name])
    } else={
      $logputinfo ("STOPPED container " . [get $ct name])
    }
  }

  :if ([get $ct stopped]) do={
    $logputinfo ("STARTING container " . [get $ct name])

    :if ($needupdate) do={
      :local ctinfo [get $ct]

      $logputinfo ("UPDATING/REPULL container " . ($ctinfo->"name"))
      repull $ct

      :set maxtries 600
      :while ($maxtries > 0) do={
        :delay 100ms
        :set maxtries ($maxtries - 1)
        :if ([get $ct stopped]) do={
          :set maxtries -999
        }
      }
      :if ($maxtries != -999) do={
        $logputerror ("FAILED UPDATING container " . ($ctinfo->"name"))
      } else={
        $logputinfo ("UPDATED container " . ($ctinfo->"name"))
      }
    }

    :set hidestartok false
    start $ct
  }

  :set maxtries 50
  :while ($maxtries > 0) do={
    :delay 100ms
    :set maxtries ($maxtries - 1)
    :if ([get $ct running]) do={
      :set maxtries -999
    }
  }
  :if ($maxtries != -999) do={
    $logputerror ("FAILED STARTING container " . [get $ct name])
    :set clearrestart false
  } else={
    :if (!$hidestartok) do={
      $logputinfo ("STARTED container " . [get $ct name])
    }
  }
}

:if ($clearrestart) do={
  /file/remove container-restart-all
  $logputinfo ("Cleared container-restart-all")
}

:if ($clearupdate) do={
  /file/remove container-update-all
  $logputinfo ("Cleared container-update-all")
}
