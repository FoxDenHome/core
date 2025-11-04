#!/usr/bin/env bash
set -euo pipefail

latest_commit_date="$(git show -s --format='%cs' HEAD)"
first_commit_id_date="$(git log --after="$latest_commit_date 00:00" --before="$latest_commit_date 23:59" --pretty='format:%H' | tail -1)"

date_commit_count="$(echo "00$(git rev-list --count "$first_commit_id_date..HEAD")" | grep -o '..$')"

latest_calver="$(echo "$latest_commit_date" | sed 's/-//g')$date_commit_count"
echo "$latest_calver"

mkdir -p $out
echo "$latest_calver" > $out/serial
