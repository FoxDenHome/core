{ ... }:
{
  systemd.tmpfiles.rules = [
    "f /sys/kernel/mm/transparent_hugepage/shmem_enabled 0644 root root 1 advise"
  ];
}
