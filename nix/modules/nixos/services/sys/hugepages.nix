{ ... }:
{
  systemd.tmpfiles.rules = [
    "w /sys/kernel/mm/transparent_hugepage/shmem_enabled 0644 root root 10d advise"
  ];
}
