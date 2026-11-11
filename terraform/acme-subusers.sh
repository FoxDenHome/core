#!/usr/bin/env bash
set -euo pipefail

# Gives every ACME zone (tofu output acme_zones) a ClouDNS API sub-user that
# may edit only that zone, and writes its credentials into the sops secret of
# whoever requests the certificates. The ClouDNS provider can't manage
# sub-users, so this talks to the API directly.
#
# Idempotent: a zone whose secret already holds its sub-user's ID is skipped.
# A sub-user whose secret is missing or stale gets a new password. --rotate
# gives every sub-user a new password.
#
# Needs CLOUDNS_AUTH_ID and CLOUDNS_PASSWORD (the main API user), like tofu.

cd "$(dirname "$(readlink -f "$0")")"

: "${CLOUDNS_AUTH_ID:?}" "${CLOUDNS_PASSWORD:?}"

rotate=0
if [ "${1-}" = "--rotate" ]; then
	rotate=1
fi

# zone => where its credentials go:
#   env:<sops file>:<key>  an EnvironmentFile for lego / devicecert
#                          (CLOUDNS_SUB_AUTH_ID, CLOUDNS_AUTH_PASSWORD)
#   dashboard:<sops file>  ACME_DNS_AUTH_ID, ACME_DNS_PASSWORD (configure/dashboard.py)
# Zones not listed here (managed outside this repo) get a 0600 file to copy from.
declare -A targets=(
	[devicecerts-islandfox.acme.foxden.network]="env:../nix/secrets/islandfox.yaml:devicecerts-acme"
	[tunnel-f0x-es.acme.foxden.network]="env:../nix/secrets/islandfox.yaml:foxden-vpn-edge-acme"
	[bengalfox-ipmi-foxden-network.acme.foxden.network]="env:../nix/secrets/bengalfox.yaml:ipmiconfig-acme"
	[status-foxden-network.acme.foxden.network]="dashboard:../mikrotik/secrets/dashboard.yaml"
)

api() {
	local endpoint="$1"
	shift
	local res
	res="$(curl -sS --fail-with-body \
		--data-urlencode "auth-id=${CLOUDNS_AUTH_ID}" \
		--data-urlencode "auth-password@"<(printf '%s' "${CLOUDNS_PASSWORD}") \
		"$@" "https://api.cloudns.net/sub-users/${endpoint}.json")"
	if jq -e 'type == "object" and has("status") and .status != "Success"' <<< "${res}" > /dev/null; then
		echo "ClouDNS ${endpoint} failed: $(jq -r '.statusDescription // .message // .' <<< "${res}")" >&2
		return 1
	fi
	printf '%s' "${res}"
}

# sops set reads a JSON value; feed it on stdin so secrets stay out of argv
sops_set() {
	local file="$1" key="$2" value="$3"
	printf '%s' "${value}" | jq -Rs . | sops set --value-stdin "${file}" "[\"${key}\"]"
}

sops_get() {
	sops -d --extract "[\"$2\"]" "$1" 2> /dev/null || true
}

# The sub-user ID the secret currently holds, or empty
current_id() {
	local target="$1" kind file key
	IFS=: read -r kind file key <<< "${target}"
	case "${kind}" in
	env) sops_get "${file}" "${key}" | sed -n 's/^CLOUDNS_SUB_AUTH_ID=//p' ;;
	dashboard) sops_get "${file}" ACME_DNS_AUTH_ID ;;
	esac
}

store() {
	local zone="$1" target="$2" id="$3" password="$4" kind file key
	IFS=: read -r kind file key <<< "${target}"
	case "${kind}" in
	env)
		sops_set "${file}" "${key}" "$(printf 'CLOUDNS_SUB_AUTH_ID=%s\nCLOUDNS_AUTH_PASSWORD=%s\n' "${id}" "${password}")"
		echo "  -> ${file} ${key}"
		;;
	dashboard)
		sops_set "${file}" ACME_DNS_AUTH_ID "${id}"
		sops_set "${file}" ACME_DNS_PASSWORD "${password}"
		echo "  -> ${file} ACME_DNS_AUTH_ID, ACME_DNS_PASSWORD"
		;;
	*)
		local out="${XDG_RUNTIME_DIR:-/tmp}/acme-subuser-${zone%%.*}.env"
		(
			umask 077
			printf 'CLOUDNS_SUB_AUTH_ID=%s\nCLOUDNS_AUTH_PASSWORD=%s\n' "${id}" "${password}" > "${out}"
		)
		echo "  -> not managed here, credentials in ${out} (delete after use)"
		;;
	esac
}

mapfile -t zones < <(./tf.sh output -json acme_zones | jq -r '[.[]] | unique | .[]')

# Usernames are the zone's first label: acme-<label>
subusers="$(api list-sub-users -d page=1 -d rows-per-page=100 |
	jq -c 'if type == "object" then [.[]] else . end | map({key: ."sub-auth-user", value: .id}) | from_entries')"

for zone in "${zones[@]}"; do
	user="acme-${zone%%.*}"
	target="${targets[${zone}]-}"
	id="$(jq -r --arg u "${user}" '.[$u] // empty' <<< "${subusers}")"
	echo "${zone} (${user})"

	if [ -n "${id}" ] && [ "${rotate}" = 0 ] && [ -n "${target}" ] && [ "$(current_id "${target}")" = "${id}" ]; then
		echo "  up to date (${id})"
		continue
	fi
	if [ -n "${id}" ] && [ "${rotate}" = 0 ] && [ -z "${target}" ]; then
		echo "  exists (${id}), not managed here; --rotate to get new credentials"
		continue
	fi

	password="$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 40)"
	if [ -z "${id}" ]; then
		id="$(api add --data-urlencode "password@"<(printf '%s' "${password}") \
			--data-urlencode "sub-auth-user=${user}" \
			-d zones=0 -d mail-forwards=0 -d records=100 | jq -r .data.id)"
		echo "  created ${id}"
	else
		api modify-password -d "id=${id}" --data-urlencode "password@"<(printf '%s' "${password}") > /dev/null
		echo "  new password for ${id}"
	fi
	if ! api zones -d "id=${id}" 2> /dev/null | grep -qF "\"${zone}\""; then
		api delegate-zone -d "id=${id}" --data-urlencode "zone=${zone}" > /dev/null
	fi
	store "${zone}" "${target}" "${id}" "${password}"
done
