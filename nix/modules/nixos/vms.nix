{
  config,
  pkgs,
  lib,
  utils,
  ...
}:
let
  eSA = lib.strings.escapeShellArg;

  qemu = pkgs.qemu_kvm;
  vmUser = "qemu-vm";
  persistDir = "/nix/persist/vms";
  stateRoot = "/var/lib/vms";

  vms = lib.attrsets.mapAttrs (name: vmCfg: {
    inherit name;
    config = vmCfg;
  }) config.foxDen.vms;
  vmList = lib.attrsets.attrValues vms;

  networkType =
    with lib.types;
    submodule {
      options = {
        type = lib.mkOption {
          type = enum [
            "macvtap"
            "sriov"
          ];
        };
        parent = lib.mkOption {
          type = nullOr str;
          default = null;
          description = "macvtap: host interface to attach to";
        };
        root = lib.mkOption {
          type = nullOr str;
          default = null;
          description = "sriov: PF to take the VF from";
        };
        vf = lib.mkOption {
          type = nullOr ints.unsigned;
          default = null;
        };
        vlan = lib.mkOption {
          type = ints.unsigned;
          default = 0;
        };
      };
    };

  vmType =
    with lib.types;
    submodule {
      options = {
        rootDiskSize = lib.mkOption { type = str; };
        autostart = lib.mkOption {
          type = bool;
          default = true;
        };
        hardware = {
          uuid = lib.mkOption { type = str; };
          memory = lib.mkOption { type = str; };
          smp = lib.mkOption { type = str; };
          cpuAffinity = lib.mkOption {
            type = nullOr str;
            default = null;
          };
          # Host CPU per vCPU index, so the SMT topology the guest sees in
          # smp matches the cores it actually runs on. Everything else
          # (main loop, iothread) floats on cpuAffinity.
          vcpuPinning = lib.mkOption {
            type = nullOr (listOf ints.unsigned);
            default = null;
          };
          vga = lib.mkOption {
            type = bool;
            default = false;
          };
          # Keyed by the interface name in foxDen.hosts.hosts.<vm>, which
          # supplies the MAC
          network = lib.mkOption {
            type = attrsOf networkType;
            default = { };
          };
          shares = lib.mkOption {
            type = listOf (submodule {
              options = {
                tag = lib.mkOption { type = str; };
                source = lib.mkOption { type = str; };
              };
            });
            default = [ ];
          };
        };
        devices = {
          usb = lib.mkOption {
            type = listOf (submodule {
              options = {
                vendorId = lib.mkOption { type = str; };
                productId = lib.mkOption { type = str; };
              };
            });
            default = [ ];
          };
          pci = lib.mkOption {
            type = listOf (submodule {
              options = {
                host = lib.mkOption { type = str; };
              };
            });
            default = [ ];
          };
        };
      };
    };

  # Every device sits alone on its own root port. Units 1-6 are fixed, so
  # guests keep their NIC names, the rest count up from 7 in hwDynamic order.
  units = {
    network = 1;
    disk = 2;
    usbController = 3;
    virtioSerial = 4;
    balloon = 5;
    rng = 6;
  };
  firstDynamicUnit = 7;
  # Spare ports for hotplug
  minRootPorts = 16;

  mkAddr = unit: "bus=pci.${toString unit},addr=0x0";

  mkRootPorts =
    count:
    lib.concatMap (
      i:
      let
        portSlot = 1 + i / 8;
        func = lib.mod i 8;
      in
      [
        "-device"
        "pcie-root-port,id=pci.${toString (i + 1)},chassis=${toString (i + 1)},port=${toString (portSlot * 8 + func)},bus=pcie.0,addr=0x${lib.toHexString portSlot}.${toString func}${
          lib.optionalString (func == 0) ",multifunction=on"
        }"
      ]
    ) (lib.range 0 (count - 1));

  # macvtap names, short enough for IFNAMSIZ
  mkTapName =
    vm: ifName: "vm${lib.substring 0 12 (builtins.hashString "sha256" "${vm.name}/${ifName}")}";

  vmNetworks =
    vm:
    lib.attrsets.mapAttrsToList (ifName: net: net // { inherit ifName; }) (vm.config.hardware.network);

  # Hotplugged NICs (e.g. thunderbolt) can show up long after boot, so the VM
  # follows the device it sits on rather than racing it
  rootDeviceUnits =
    vm:
    lib.lists.unique (
      map (
        net:
        "sys-subsystem-net-devices-${
          utils.escapeSystemdPath (if net.type == "macvtap" then net.parent else net.root)
        }.device"
      ) (vmNetworks vm)
    );

  fsSocketName = vm: share: "vm-${vm.name}-fs-${share.tag}";
  fsSocketPath = vm: share: "/run/vm-${vm.name}-fs/${share.tag}.sock";

  bindVfioScript = pkgs.writeShellScript "vm-bind-vfio.sh" ''
    set -euo pipefail
    dev="/sys/bus/pci/devices/$1"
    ${pkgs.kmod}/bin/modprobe vfio-pci
    echo vfio-pci > "$dev/driver_override"
    if [ -e "$dev/driver" ] && [ "$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/readlink -f "$dev/driver")")" != vfio-pci ]; then
      echo "$1" > "$dev/driver/unbind"
    fi
    if [ ! -e "$dev/driver" ]; then
      echo "$1" > /sys/bus/pci/drivers_probe
    fi
    group="/dev/vfio/$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/readlink -f "$dev/iommu_group")")"
    maxtries=100
    while [ ! -c "$group" ]; do
      maxtries=$((maxtries - 1))
      if [ $maxtries -le 0 ]; then
        echo "Timeout waiting for $group" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    ${pkgs.coreutils}/bin/chown ${vmUser}:${vmUser} "$group"
  '';

  # Same VF bookkeeping as the sriov host driver (and under its lock), so
  # the two never hand out the same VF
  assignVfScript = pkgs.writeShellScript "vm-assign-vf.sh" ''
    set -euo pipefail
    root="$1"
    numvfs_file="/sys/class/net/$root/device/sriov_numvfs"
    if [ "$(${pkgs.coreutils}/bin/cat "$numvfs_file")" -eq 0 ]; then
      echo 0 > "/sys/class/net/$root/device/sriov_drivers_autoprobe"
      ${pkgs.coreutils}/bin/cat "/sys/class/net/$root/device/sriov_totalvfs" > "$numvfs_file"
    fi
    ${pkgs.iproute2}/bin/ip link set dev "$root" vf "$2" spoofchk on mac "$3" vlan "$4"
  '';

  mkNetSetup =
    vm: fd: unit: net:
    let
      mac = config.foxDen.hosts.hosts.${vm.name}.interfaces.${net.ifName}.mac;
    in
    if net.type == "macvtap" then
      let
        tap = mkTapName vm net.ifName;
      in
      {
        setup = ''
          ip link del ${tap} 2>/dev/null || true
          ip link add link ${eSA net.parent} name ${tap} address ${mac} type macvtap mode bridge
          ip link set ${tap} up
          tapdev="/dev/tap$(cat /sys/class/net/${tap}/ifindex)"
          maxtries=100
          while [ ! -c "$tapdev" ]; do
            maxtries=$((maxtries - 1))
            if [ $maxtries -le 0 ]; then
              echo "Timeout waiting for $tapdev" >&2
              exit 1
            fi
            sleep 0.1
          done
          exec ${toString fd}<>"$tapdev"
        '';
        cleanup = "ip link del ${tap} 2>/dev/null || true";
        args = [
          "-netdev"
          "tap,id=net-${net.ifName},fd=${toString fd},vhost=on"
          "-device"
          "virtio-net-pci,netdev=net-${net.ifName},mac=${mac},${mkAddr unit}"
        ];
      }
    else if net.type == "sriov" then
      let
        vfVar = "vf_${lib.replaceStrings [ "-" ] [ "_" ] net.ifName}";
      in
      {
        setup = ''
          flock -x /run/foxden-sriov.lock ${assignVfScript} ${eSA net.root} ${toString net.vf} ${mac} ${toString net.vlan}
          ${vfVar}="$(basename "$(readlink -f /sys/class/net/${eSA net.root}/device/virtfn${toString net.vf})")"
          ${bindVfioScript} "${"$"}${vfVar}"
        '';
        cleanup = "";
        args = [
          "-device"
          "vfio-pci,host=${"$"}${vfVar},${mkAddr unit}"
        ];
      }
    else
      throw "VM ${vm.name}: unknown network type ${net.type}";

  mkVm =
    vm:
    let
      hw = vm.config.hardware;
      stateDir = "${stateRoot}/${vm.name}";
      runDir = "/run/vm-${vm.name}";
      shares = hw.shares;
      networks = vmNetworks vm;

      # Devices without a fixed unit, in placement order
      hwDynamic =
        map (net: {
          kind = "network";
          value = net;
        }) (lib.drop 1 networks)
        ++ map (dev: {
          kind = "pci";
          value = dev;
        }) vm.config.devices.pci
        ++ map (share: {
          kind = "share";
          value = share;
        }) shares
        ++ lib.lists.optional hw.vga {
          kind = "vga";
          value = null;
        };
      placed = lib.imap0 (i: d: d // { unit = firstDynamicUnit + i; }) hwDynamic;
      placedOf = kind: lib.filter (d: d.kind == kind) placed;
      rootPortCount = lib.max minRootPorts (firstDynamicUnit - 1 + lib.length placed);

      netUnits =
        lib.lists.optional (networks != [ ]) units.network ++ map (d: d.unit) (placedOf "network");
      nets = lib.imap0 (i: net: mkNetSetup vm (3 + i) (lib.elemAt netUnits i) net) networks;

      # Shell words: dynamic ones (VF addresses) expand at start
      qemuArgs = [
        "-name"
        "guest=${vm.name},debug-threads=on"
        "-uuid"
        hw.uuid
        "-machine"
        "q35,usb=off,vmport=off,dump-guest-core=off,hpet=off,acpi=on${
          lib.optionalString (shares != [ ]) ",memory-backend=mem"
        }"
        "-accel"
        "kvm"
        # Passthrough devices rule out migration anyway, and this keeps
        # invtsc so the guest can trust its TSC
        "-cpu"
        "host,migratable=off"
        "-m"
        hw.memory
        "-smp"
        hw.smp
        "-drive"
        "if=pflash,format=raw,readonly=on,file=${qemu}/share/qemu/edk2-x86_64-code.fd"
        "-drive"
        "if=pflash,format=raw,file=${stateDir}/vars.fd"
        "-nodefaults"
        "-no-user-config"
        "-rtc"
        "base=utc,driftfix=slew"
        "-global"
        "kvm-pit.lost_tick_policy=delay"
        "-global"
        "ICH9-LPC.disable_s3=1"
        "-global"
        "ICH9-LPC.disable_s4=1"
        "-global"
        "ICH9-LPC.noreboot=off"
        "-action"
        "watchdog=reset"
        "-boot"
        "strict=on"
        "-qmp"
        "unix:${runDir}/qmp.sock,server=on,wait=off"
        "-chardev"
        "socket,id=serial0,path=${runDir}/serial.sock,server=on,wait=off"
        "-serial"
        "chardev:serial0"
      ]
      ++ mkRootPorts rootPortCount
      ++ [
        # Disk I/O off the main loop
        "-object"
        "iothread,id=iothread0"
        "-device"
        "virtio-blk-pci,drive=disk0,iothread=iothread0,bootindex=1,${mkAddr units.disk}"
        "-drive"
        "if=none,id=disk0,file=${stateDir}/disk.qcow2,format=qcow2,cache=none,aio=native,discard=unmap"
        "-device"
        "virtio-serial-pci,id=virtio-serial0,${mkAddr units.virtioSerial}"
        "-chardev"
        "socket,id=qga0,path=${runDir}/qga.sock,server=on,wait=off"
        "-device"
        "virtserialport,bus=virtio-serial0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0"
        "-device"
        "qemu-xhci,id=usb,p2=15,p3=15,${mkAddr units.usbController}"
        "-device"
        "virtio-balloon-pci,id=balloon0,${mkAddr units.balloon}"
        "-object"
        "rng-random,id=rng0,filename=/dev/urandom"
        "-device"
        "virtio-rng-pci,rng=rng0,${mkAddr units.rng}"
      ]
      ++ (
        if hw.vga then
          lib.concatMap (d: [
            "-device"
            "VGA,vgamem_mb=16,${mkAddr d.unit}"
            "-device"
            "usb-tablet,bus=usb.0"
            "-vnc"
            "unix:${runDir}/vnc.sock"
          ]) (placedOf "vga")
        else
          [
            "-display"
            "none"
          ]
      )
      # By ID rather than bus address: QEMU then picks the stick up again
      # whenever it is replugged, or shows up after the VM started
      ++ lib.concatMap (dev: [
        "-device"
        "usb-host,bus=usb.0,vendorid=0x${dev.vendorId},productid=0x${dev.productId}"
      ]) vm.config.devices.usb
      ++ lib.concatMap (d: [
        "-device"
        "vfio-pci,host=${d.value.host},${mkAddr d.unit}"
      ]) (placedOf "pci")
      ++ lib.concatMap (d: [
        "-chardev"
        "socket,id=fs-${d.value.tag},path=${fsSocketPath vm d.value}"
        "-device"
        "vhost-user-fs-pci,chardev=fs-${d.value.tag},tag=${d.value.tag},queue-size=1024,${mkAddr d.unit}"
      ]) (placedOf "share")
      ++ lib.lists.optionals (shares != [ ]) [
        # vhost-user needs guest RAM it can map
        "-object"
        "memory-backend-memfd,id=mem,size=${hw.memory},share=on"
      ]
      ++ lib.concatMap (net: net.args) nets
      ++ [
        "-sandbox"
        "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"
        "-msg"
        "timestamp=on"
      ];

      # Dynamic words are already double-quoted shell, the rest gets escaped
      shellWord = arg: if lib.hasInfix "$" arg then "\"${arg}\"" else eSA arg;

      startScript = pkgs.writeShellScript "vm-${vm.name}-start" ''
        set -euo pipefail

        mkdir -p ${stateDir}
        chown root:${vmUser} ${stateDir}
        chmod 0750 ${stateDir}
        if [ ! -e ${stateDir}/disk.qcow2 ]; then
          echo "Creating root disk for ${vm.name}"
          qemu-img create -f qcow2 ${stateDir}/disk.qcow2 ${vm.config.rootDiskSize}
        fi
        if [ ! -e ${stateDir}/vars.fd ]; then
          cp ${qemu}/share/qemu/edk2-i386-vars.fd ${stateDir}/vars.fd
        fi
        chown ${vmUser}:${vmUser} ${stateDir}/disk.qcow2 ${stateDir}/vars.fd
        chmod 0600 ${stateDir}/disk.qcow2 ${stateDir}/vars.fd
        chown ${vmUser}:${vmUser} ${runDir}

        ${lib.concatMapStringsSep "\n" (dev: "${bindVfioScript} ${eSA dev.host}") vm.config.devices.pci}
        ${lib.concatMapStringsSep "\n" (net: net.setup) nets}

        exec setpriv --reuid=${vmUser} --regid=${vmUser} --init-groups --inh-caps=-all --bounding-set=-all -- \
          ${qemu}/bin/qemu-system-x86_64 ${lib.concatMapStringsSep " " shellWord qemuArgs}
      '';

      stopScript = pkgs.writeShellScript "vm-${vm.name}-stop" ''
        set -uo pipefail
        printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n' |
          socat -t5 - UNIX-CONNECT:${runDir}/qmp.sock >/dev/null || exit 0
        # TimeoutStopSec kills QEMU if the guest ignores the power button
        while kill -0 "$MAINPID" 2>/dev/null; do
          sleep 1
        done
      '';

      # debug-threads names vCPU threads "CPU <index>/KVM"; QEMU only
      # spawns them after mapping guest RAM, which can take a while
      pinScript = pkgs.writeShellScript "vm-${vm.name}-pin" ''
        set -euo pipefail
        pins=(${lib.concatMapStringsSep " " toString hw.vcpuPinning})
        maxtries=600
        while [ "$(grep -lE '^CPU [0-9]+/KVM$' /proc/"$MAINPID"/task/*/comm 2>/dev/null | wc -l)" -lt ''${#pins[@]} ]; do
          maxtries=$((maxtries - 1))
          if [ $maxtries -le 0 ]; then
            echo "Timeout waiting for vCPU threads" >&2
            exit 1
          fi
          sleep 0.1
        done
        for comm in /proc/"$MAINPID"/task/*/comm; do
          if [[ "$(cat "$comm")" =~ ^CPU\ ([0-9]+)/KVM$ ]] && [ -n "''${pins[''${BASH_REMATCH[1]}]:-}" ]; then
            tid="$(basename "$(dirname "$comm")")"
            taskset -pc "''${pins[''${BASH_REMATCH[1]}]}" "$tid" >/dev/null
          fi
        done
      '';

      cleanupScript = pkgs.writeShellScript "vm-${vm.name}-cleanup" ''
        ${lib.concatMapStringsSep "\n" (net: net.cleanup) nets}
        true
      '';

      devUnits = rootDeviceUnits vm;
      fsSockets = map (share: "${fsSocketName vm share}.socket") shares;
    in
    {
      services = {
        "vm-${vm.name}" = {
          description = "VM ${vm.name}";
          wantedBy = lib.lists.optionals vm.config.autostart ([ "multi-user.target" ] ++ devUnits);
          # Stops with its NIC and comes back (via wantedBy) when it reappears
          bindsTo = devUnits;
          requires = fsSockets;
          after = [ "network.target" ] ++ devUnits ++ fsSockets;
          startLimitIntervalSec = 0;
          # Rebooting the guest on every QEMU bump is worse than picking
          # changes up on the next restart
          restartIfChanged = false;

          path = with pkgs; [
            coreutils
            iproute2
            util-linux
            socat
            qemu-utils
          ];

          serviceConfig = {
            Type = "simple";
            ExecStart = startScript;
            ExecStop = stopScript;
            ExecStopPost = cleanupScript;
            Restart = "always";
            RestartSec = "5s";
            RestartSteps = 5;
            RestartMaxDelaySec = "1min";
            TimeoutStopSec = "3min";
            KillMode = "mixed";
            # vfio pins all of guest RAM
            LimitMEMLOCK = "infinity";
            RuntimeDirectory = "vm-${vm.name}";
            RuntimeDirectoryMode = "0750";
          }
          // lib.attrsets.optionalAttrs (hw.cpuAffinity != null) {
            CPUAffinity = hw.cpuAffinity;
          }
          // lib.attrsets.optionalAttrs (hw.vcpuPinning != null) {
            # Unpinned beats a VM stuck in a restart loop
            ExecStartPost = "-${pinScript}";
          };
        };
      }
      // lib.attrsets.listToAttrs (
        map (share: {
          name = fsSocketName vm share;
          value = {
            description = "virtiofsd ${share.tag} for VM ${vm.name}";
            serviceConfig = {
              # Serves one connection and exits with it, the socket brings
              # it back for the next VM start
              ExecStart = "${pkgs.virtiofsd}/bin/virtiofsd --fd=3 --shared-dir=${eSA share.source}";
            };
          };
        }) shares
      );

      sockets = lib.attrsets.listToAttrs (
        map (share: {
          name = fsSocketName vm share;
          value = {
            wantedBy = [ "sockets.target" ];
            listenStreams = [ (fsSocketPath vm share) ];
            socketConfig = {
              SocketUser = "root";
              SocketGroup = vmUser;
              SocketMode = "0660";
              DirectoryMode = "0755";
            };
          };
        }) shares
      );
    };

  vmUnits = map mkVm vmList;

  # virsh console analog: attach to a VM's serial socket
  vmConsole = pkgs.writeShellApplication {
    name = "vm-console";
    runtimeInputs = [ pkgs.socat ];
    text = ''
      if [ $# -ne 1 ]; then
        echo "Usage: vm-console <vm>" >&2
        echo "VMs: ${lib.concatStringsSep " " (lib.attrsets.attrNames vms)}" >&2
        exit 1
      fi
      sock="/run/vm-$1/serial.sock"
      if [ ! -S "$sock" ]; then
        echo "No console for VM $1 (is vm-$1.service running?)" >&2
        exit 1
      fi
      echo "Connected to $1 (escape with ^])" >&2
      socat -,raw,echo=0,escape=0x1d "UNIX-CONNECT:$sock"
      echo >&2
    '';
  };

  mkUSBUdevRule =
    dev:
    "SUBSYSTEM==\"usb\", ENV{DEVTYPE}==\"usb_device\", ATTR{idVendor}==\"${dev.vendorId}\", ATTR{idProduct}==\"${dev.productId}\", GROUP=\"${vmUser}\", MODE=\"0660\"";
in
{
  options.foxDen.vms = lib.mkOption {
    type = lib.types.attrsOf vmType;
    default = { };
    description = ''
      QEMU VMs on this machine. Each one also needs a foxDen.hosts.hosts
      entry of the same name, whose interfaces (matching hardware.network)
      give the MACs, addresses and DNS.
    '';
  };

  config = lib.mkIf (vmList != [ ]) {
    assertions = lib.concatMap (
      vm:
      map (net: {
        assertion =
          (config.foxDen.hosts.hosts.${vm.name}.interfaces.${net.ifName}.mac or null) != null
          && (if net.type == "macvtap" then net.parent != null else net.root != null && net.vf != null);
        message = "VM ${vm.name}: network ${net.ifName} needs foxDen.hosts.hosts.${vm.name}.interfaces.${net.ifName}.mac and ${
          if net.type == "macvtap" then "parent" else "root and vf"
        }";
      }) (vmNetworks vm)
    ) vmList;

    users.users.${vmUser} = {
      isSystemUser = true;
      group = vmUser;
      extraGroups = [ "kvm" ];
    };
    users.groups.${vmUser} = { };

    boot.kernelModules = [ "vfio-pci" ];

    environment.systemPackages = [ vmConsole ];

    systemd.services = lib.mkMerge (map (u: u.services) vmUnits);
    systemd.sockets = lib.mkMerge (map (u: u.sockets) vmUnits);

    systemd.tmpfiles.rules = [
      "f+ ${stateRoot}/CACHEDIR.TAG 0644 root root - Signature: 8a477f597d28d172789f06886806bc55"
    ];

    environment.persistence.${persistDir} = {
      hideMounts = true;
      directories = [
        {
          directory = stateRoot;
          user = "root";
          group = vmUser;
          mode = "u=rwx,g=rx,o=";
        }
      ];
    };

    services.udev.extraRules = lib.concatMapStringsSep "\n" mkUSBUdevRule (
      lib.concatMap (vm: vm.config.devices.usb) vmList
    );

    # VM NICs are QEMU's to set up, the guest picks its address up via DHCP
    foxDen.hosts.hosts = lib.attrsets.mapAttrs (_: vm: {
      interfaces = lib.attrsets.mapAttrs (_: _: {
        driver.name = lib.mkDefault "null";
        useDHCP = lib.mkDefault true;
      }) vm.config.hardware.network;
    }) vms;
  };
}
