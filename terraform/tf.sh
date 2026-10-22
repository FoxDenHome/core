#!/usr/bin/env bash
set -euo pipefail

# Runs tofu against the state database on islandfox, reached through an SSH
# Unix socket forward. Access is granted to the kanidm superadmins group.

cd "$(dirname "$(readlink -f "$0")")"

STATE_HOST="${TOFU_STATE_HOST:-islandfox.foxden.network}"

sockdir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/tofu-state.XXXXXX")"
cleanup() {
	ssh -S "${sockdir}/ssh.ctl" -O exit "${STATE_HOST}" 2> /dev/null || true
	rm -rf "${sockdir}"
}
trap cleanup EXIT

ssh -fNM -S "${sockdir}/ssh.ctl" \
	-o ExitOnForwardFailure=yes \
	-L "${sockdir}/.s.PGSQL.5432:/run/postgresql-opentofu/.s.PGSQL.5432" \
	"${STATE_HOST}"

export PG_CONN_STR="host=${sockdir} dbname=opentofu user=opentofu sslmode=disable"
TF_VAR_state_passphrase="$(sops -d --extract '["passphrase"]' state-passphrase.yaml)"
export TF_VAR_state_passphrase

tofu "$@"
