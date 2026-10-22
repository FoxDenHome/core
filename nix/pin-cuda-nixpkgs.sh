#!/usr/bin/env bash
# Pins the nixpkgs input to the newest nixos-unstable-small rev for which the NixOS-CUDA Hydra
# built every job in REQUIRED_JOBS, so CUDA hosts substitute from cache.nixos-cuda.org instead of
# compiling torch & co. The pin never moves backwards; if no newer eval qualifies, it stays put.
set -euo pipefail
cd "$(dirname "$0")"
set -x

HYDRA='https://hydra.nixos-cuda.org'
JOBSET='nixos-cuda/cuda-packages-unstable'
MAX_EVALS=15

# The heavy cudaSupport-sensitive builds in our closures. PY is replaced by the rev's python3 attr.
REQUIRED_JOBS=(
	onnxruntime
	PY.onnxruntime
	PY.torch
	PY.torchvision
)

hydra() {
	curl -fsS -m 300 -H 'Accept: application/json' "${HYDRA}/$1"
}

current_rev="$(sed -n 's|^\s*nixpkgs\.url = "github:NixOS/nixpkgs/\([0-9a-f]\{40\}\)";.*|\1|p' flake.nix)"
if [ -z "${current_rev}" ]; then
	echo 'Could not find pinned nixpkgs rev in flake.nix' >&2
	exit 1
fi

for eval_id in $(hydra "jobset/${JOBSET}/evals" | jq -r ".evals[:${MAX_EVALS}][].id"); do
	rev="$(hydra "eval/${eval_id}" | jq -r '.jobsetevalinputs.nixpkgs.revision')"
	if [ "${rev}" = "${current_rev}" ]; then
		echo "No newer fully built eval than the current pin ${current_rev}"
		exit 0
	fi

	status="$(curl -fsS -m 60 "https://api.github.com/repos/NixOS/nixpkgs/compare/${current_rev}...${rev}?per_page=1" | jq -r '.status')"
	if [ "${status}" != 'ahead' ]; then
		echo "Eval ${eval_id} (${rev}): not ahead of current pin (${status}), stopping"
		exit 0
	fi

	py="$(nix eval --raw "github:NixOS/nixpkgs/${rev}#python3.pythonAttr")Packages"
	builds="$(hydra "eval/${eval_id}/builds")"
	missing=''
	for job in "${REQUIRED_JOBS[@]}"; do
		job="${job/#PY./${py}.}.x86_64-linux"
		ok="$(jq -r --arg job "${job}" 'any(.[]; .job == $job and .finished == 1 and .buildstatus == 0)' <<<"${builds}")"
		if [ "${ok}" != 'true' ]; then
			missing="${missing} ${job}"
		fi
	done

	if [ -n "${missing}" ]; then
		echo "Eval ${eval_id} (${rev}): missing${missing}"
		continue
	fi

	echo "Pinning nixpkgs to ${rev} (eval ${eval_id})"
	sed -i "s|github:NixOS/nixpkgs/${current_rev}|github:NixOS/nixpkgs/${rev}|" flake.nix
	nix flake lock
	exit 0
done

echo "No newer fully built eval within the last ${MAX_EVALS}, keeping ${current_rev}"
