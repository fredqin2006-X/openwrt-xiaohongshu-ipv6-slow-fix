#!/bin/sh
set -eu
if [ ! -x /usr/libexec/xhs-ipv4-uninstall ]; then
    echo 'No managed installation found. Legacy deployments use /usr/libexec/xhs-ipv4-rollback.' >&2
    exit 1
fi
exec /usr/libexec/xhs-ipv4-uninstall
