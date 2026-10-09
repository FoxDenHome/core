# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Monorepo controlling the FoxDen homelab. Four independent subprojects, all driven by one source of truth: the NixOS flake in `nix/`.

- `nix/` — NixOS configs for all Linux hosts (bengalfox, islandfox, icefox, …), plus flake outputs (`dns`, `dhcp`, `firewall`, `foxIngress`, `foxMail`, `ipReverses`, …) that the other subprojects consume.
- `mikrotik/` — Python (uv) tool that pushes the generated config to the RouterOS routers (`router`, `router-backup`, `redfox`) over the RouterOS API.
- `terraform/` — Public DNS (OVH, dns.he.net), DKIM, reverse DNS and the Fastly CDN. The `*.sh` scripts are `external` data sources that `nix build` the flake JSON outputs.
- `vpn/` — Go WireGuard client daemon/tray (`foxden-vpnd`), self-service portal and expose edge. See `vpn/README.md` for the design. Packaged into nix as `nix/packages/foxden-vpn`.

## Commands

```sh
# Nix (run from nix/)
nix run 'nixpkgs#nixfmt-tree' -- --ci            # lint (CI); drop --ci to format
nix build .#nixosConfigurations.<host>.config.system.build.toplevel   # build a host
nix build .#dns.json --no-link --print-out-paths   # inspect a generated output (also dhcp.json.router, firewall.json.router, …)
./repl.sh                                          # nix repl on the flake

# MikroTik (run from mikrotik/)
uv run ruff check
uv run pyright
uv run python -m unittest                          # all tests (unittest, not pytest)
uv run python -m unittest tests.test_dns           # single module; append .Class.test_name for one test
./configure.py                                     # APPLIES config to the live routers
./backup.sh [mirror_dir]                           # pull RouterOS backups/exports

# Terraform
tflint -c "$PWD/terraform/.tflint.hcl" --recursive -f compact   # from repo root (CI)

# VPN (run from vpn/)
make            # go build ./cmd/... into bin/
make test       # go vet + go test
go test ./internal/<pkg> -run <TestName>

./update-all.sh   # flake update + factorio mod list + mikrotik configure
```

CI (`.forgejo/workflows/lint.yml`) runs nixfmt, ruff and tflint. `main` is protected and changes land through PRs on Forgejo. Open them from a branch pushed to `origin` (e.g. `git push origin HEAD:<branch>` then `fj pr create --head <branch> --base main`), not with AGit (`refs/for/main/...`): Forgejo treats AGit PRs as fork PRs and withholds secrets (like `EXT_GITHUB_TOKEN`) from their CI runs. Merges to `main` touching `nix/**` trigger `deploy.yml`, which SSHes into each host as `nixpush`. The hosts then run `nixos-rebuild switch` against `git+https://git.foxden.network/FoxDen/core?dir=nix#<hostname>`, so **merging to main deploys to production**.

## Nix architecture

`nix/outputs.nix` auto-discovers everything. Nothing is listed by hand:

- **Systems**: every `.nix` file under `systems/<arch>/<hostname>/` becomes part of `nixosConfigurations.<hostname>`. To add config to a host, drop a file in its directory.
- **NixOS modules**: every `.nix` under `modules/nixos/` is imported into **every** host. Modules declare `options.foxDen.*` and gate their config behind `enable`.
- **Library (`foxDenLib`)**: every file under `modules/lib/` is imported with the flake inputs and merged into a nested attrset by path (`modules/lib/services/http.nix` → `foxDenLib.services.http`, and a `main.nix` maps to its directory). A lib file may also export `nixosModule`, which is added to every host. `foxDenLib`, all flake inputs, `hostName` and `systemArch` are available as module arguments.
- **Packages**: each `packages/<name>/package.nix` is merged into `pkgs`, along with the `packages` of every flake input (`modules/nixos/packages.nix`).
- **Cross-host global config**: `modules/lib/global/*` builds `dns`, `dhcp`, `firewall`, `kanidm`, `kerberos`, `foxIngress`, `foxMail` and similar from *all* `nixosConfigurations`. The results are passed back into each host as `specialArgs` and exported as flake outputs for mikrotik/terraform. A change on one host can therefore change DNS, DHCP or firewall output for the routers and for other hosts.

Typical service pattern (see `systems/x86_64-linux/islandfox/rmfakecloud.nix` + `modules/nixos/services/rmfakecloud.nix`):
- The service module defines `options.foxDen.services.<name>` via `foxDenLib.services.http.mkOptions` and builds its config with `services.make` / `services.http.make`. These run the service in its own network namespace attached to a "host".
- The system file enables the service and declares `foxDen.hosts.hosts.<name>`, typically with `config.lib.foxDenSys.mkVlanHost <vlan> { dns.fqdns, addresses, driver, webservice.enable, … }`. Addresses follow `10.<vlan>.x.y/16` and `fd2c:f4cb:63be:<vlan>::…/64`. Network drivers live in `modules/lib/hosts/drivers/`.
- Firewall rules are declared as `foxDen.firewall.rules` in nix and are realized on the MikroTik routers.

## Secrets

- `nix/secrets/<hostname>.yaml` is each host's default sops file, and `shared.yaml` is shared across hosts. Wrap secret-dependent config in `config.lib.foxDen.sops.mkIfAvailable` so hosts and builds without sops still evaluate.
- `terraform/*.tfstate` is encrypted in git via the `git-sops` smudge/clean filter (`./git-sops init` sets it up; `.sops.yaml` covers `terraform/`). Don't hand-edit or diff it as plaintext.

## Gotchas (from README)

- ZFS datasets must use `mountpoint=legacy`.
- Never use `/var/run`; always use `/run`.
- RouterOS devices can't be rebuilt from zero; `mikrotik/` only manages their dynamic config (DNS, DHCP, firewall, DynDNS, VRRP, scripts).
- The `vpn/` Go vendor hash lives in `vpn/vendor-hash.txt`. Renovate regenerates it on Go dep bumps; after changing deps by hand, run `../maid/tools/auto-nix-hash vpn/vendor-hash.txt './nix#nixosConfigurations.islandfox.pkgs.foxden-vpn.goModules'` from the repo root (FoxDen/maid checked out alongside core).
