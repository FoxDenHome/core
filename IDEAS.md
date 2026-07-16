# Ideas

Random things that might be useful to implement, so they don't go forgotten

## List

- **idlecachefs**: FS for CIFS which gets stuck when server goes away. FS would passthru but unmount underlfying FS if not in use, maintaining cache via VFS cache

- **nagios-ish**: Deploy good alerting / alter-monitoring, like nagios. Maybe alertmanager + telegram?

- **nginx-mailproxy**: Runs on router, allows each host to send as host-RDNS@host.foxden.network (host-bengalfox@foxden.network), proxy via SES

- **video sync**: Browser extensions + self-contained Go websocket relay (stateless) to synchronize main video (or maybe multiple/all) video elements on a given tab, also synchronize the URL with the "host"
