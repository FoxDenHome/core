#!/usr/bin/env bash
exec curl -fsL \
        http://router.foxden.network:9002/dkim.json \
        http://router-backup.foxden.network:9002/dkim.json \
        http://icefox-foxmail.foxden.network:9002/dkim.json \
    | jq -s '.[0] * .[1] * .[2]'
