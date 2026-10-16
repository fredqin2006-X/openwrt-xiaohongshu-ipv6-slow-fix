#!/bin/sh
set -eu
src=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
iface=br-lan
check_only=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) check_only=1; shift;;
        --interface) [ "$#" -ge 2 ] || { echo 'Missing interface' >&2; exit 2; }; iface=$2; shift 2;;
        --help|-h) echo 'Usage: sh install.sh [--check] [--interface br-lan]'; exit 0;;
        *) echo "Unknown option: $1" >&2; exit 2;;
    esac
done
fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'Run as root on the router.'
case "$iface" in ''|*[!a-zA-Z0-9_.:-]*) fail 'Invalid interface name.';; esac
[ "${#iface}" -le 15 ] || fail 'Interface name exceeds 15 characters.'
[ -f /etc/openwrt_release ] && [ -f /etc/rc.common ] && [ -x /etc/init.d/dnsmasq ] || fail 'Requires OpenWrt/iStoreOS with procd and dnsmasq.'
for cmd in nft dnsmasq tcpdump lua timeout nslookup mkfifo mktemp logger ip awk sed grep cp chmod mkdir rmdir rm cat date wc head tr sleep; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing dependency: $cmd"
done
dnsmasq --version | grep 'Compile time options:' | grep -qw nftset || fail 'dnsmasq must be built with nftset support.'
ip link show dev "$iface" >/dev/null 2>&1 || fail "Interface does not exist: $iface"
nft list table inet fw4 >/dev/null 2>&1 || fail 'An active nftables firewall4 table is required.'
[ -f /etc/dnsmasq.conf ] && [ ! -L /etc/dnsmasq.conf ] || fail 'Requires a regular /etc/dnsmasq.conf file.'
configs=$(grep -l '^conf-file=/etc/dnsmasq.conf$' /var/etc/dnsmasq.conf.* 2>/dev/null || :)
count=$(printf '%s\n' "$configs" | grep -c . || :)
[ "$count" = 1 ] || fail 'Requires exactly one active default dnsmasq instance loading /etc/dnsmasq.conf.'
dns_config=$configs
version=$(cat "$src/files/etc/xhs-ipv4/VERSION")
if [ -e /etc/init.d/xhs-ipv4 ] || [ -e /etc/xhs-ipv4 ]; then
    if [ -r /etc/xhs-ipv4/VERSION ] && [ "$(cat /etc/xhs-ipv4/VERSION)" = "$version" ] && [ "$(cat /etc/xhs-ipv4/options)" = "LAN_IFACE=$iface" ]; then
        echo "Already installed: $version ($iface). No files or backups changed."
        exit 0
    fi
    fail 'Existing XHS installation found. Uninstall it first; legacy deployments use xhs-ipv4-rollback.'
fi
for f in /usr/libexec/xhs-ipv4-control /usr/libexec/xhs-ipv4-monitor /usr/libexec/xhs-ipv4-learn.lua /usr/libexec/xhs-ipv4-uninstall; do
    [ ! -e "$f" ] || fail "Refusing to overwrite existing file: $f"
done
if grep -q '^# \(BEGIN\|END\) XHS-IPV4$' /etc/dnsmasq.conf; then fail 'Existing or incomplete XHS DNS block found; inspect it before installing.'; fi
if nft list table inet xhs_ipv4 >/dev/null 2>&1; then fail 'Table inet xhs_ipv4 already exists.'; fi
umask 077
tmp=$(mktemp -d /tmp/xhs-ipv4-install.XXXXXX)
modified=0
done_ok=0
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$modified" = 1 ] && [ "$done_ok" = 0 ]; then
        echo 'Installation failed; restoring the pre-install DNS config and removing this installation.' >&2
        cat "$tmp/dnsmasq.before" > /etc/dnsmasq.conf
        /etc/init.d/dnsmasq restart || :
        /etc/init.d/xhs-ipv4 disable 2>/dev/null || :
        /etc/init.d/xhs-ipv4 stop 2>/dev/null || :
        nft delete table inet xhs_ipv4 2>/dev/null || :
        rm -f /etc/init.d/xhs-ipv4 /usr/libexec/xhs-ipv4-control /usr/libexec/xhs-ipv4-monitor /usr/libexec/xhs-ipv4-learn.lua /usr/libexec/xhs-ipv4-uninstall
        rm -f /etc/xhs-ipv4/domains /etc/xhs-ipv4/hosts /etc/xhs-ipv4/options /etc/xhs-ipv4/VERSION
        rmdir /etc/xhs-ipv4 2>/dev/null || :
    fi
    rm -f "$tmp/rules.nft" "$tmp/dnsmasq.before"
    rmdir "$tmp" 2>/dev/null || :
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
sh "$src/files/usr/libexec/xhs-ipv4-control" render "$iface" > "$tmp/rules.nft"
nft -c -f "$tmp/rules.nft"
XHS_LUA_SOURCE="$src/files/usr/libexec/xhs-ipv4-learn.lua" lua -e 'assert(loadfile(os.getenv("XHS_LUA_SOURCE")))'
tcpdump -n -p -Q in -i "$iface" -d 'ip6 and (tcp dst port 80 or tcp dst port 443)' >/dev/null 2>&1 || fail 'tcpdump must support -Q in and the IPv6 capture filter.'
dnsmasq --test -C "$dns_config"
echo 'Preflight passed: root, firewall4, nftables, DNS integration, Lua and packet capture.'
[ "$check_only" = 0 ] || { done_ok=1; exit 0; }
backup=/etc/xhs-ipv4-backup
mkdir -p "$backup"
chmod 700 "$backup"
[ -e "$backup/dnsmasq.conf.original" ] || cp -p /etc/dnsmasq.conf "$backup/dnsmasq.conf.original"
chmod 600 "$backup/dnsmasq.conf.original"
cp -p /etc/dnsmasq.conf "$tmp/dnsmasq.before"
modified=1
mkdir -p /etc/xhs-ipv4
for f in domains hosts VERSION; do cp "$src/files/etc/xhs-ipv4/$f" "/etc/xhs-ipv4/$f"; done
printf 'LAN_IFACE=%s\n' "$iface" > /etc/xhs-ipv4/options
cp "$src/files/etc/init.d/xhs-ipv4" /etc/init.d/xhs-ipv4
for f in xhs-ipv4-control xhs-ipv4-monitor xhs-ipv4-learn.lua xhs-ipv4-uninstall; do
    cp "$src/files/usr/libexec/$f" "/usr/libexec/$f"
done
chmod 755 /etc/init.d/xhs-ipv4 /usr/libexec/xhs-ipv4-control /usr/libexec/xhs-ipv4-monitor /usr/libexec/xhs-ipv4-uninstall
chmod 644 /usr/libexec/xhs-ipv4-learn.lua /etc/xhs-ipv4/*
/usr/libexec/xhs-ipv4-control ensure
domains=$(tr '\n' '/' < /etc/xhs-ipv4/domains)
printf '\n# BEGIN XHS-IPV4\nnftset=/%s6#inet#xhs_ipv4#targets6\n# END XHS-IPV4\n' "$domains" >> /etc/dnsmasq.conf
dnsmasq --test -C "$dns_config"
/etc/init.d/xhs-ipv4 enable
/etc/init.d/xhs-ipv4 start
/etc/init.d/dnsmasq restart
/etc/init.d/dnsmasq status
/etc/init.d/xhs-ipv4 status
done_ok=1
echo "Installed $version on $iface. Original DNS backup: $backup/dnsmasq.conf.original"
echo 'Status: /usr/libexec/xhs-ipv4-control status'
echo 'Uninstall: /usr/libexec/xhs-ipv4-uninstall'
