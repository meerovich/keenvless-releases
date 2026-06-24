#!/bin/sh
set -eu

# KeenVLESS bootstrap for Keenetic/Netcraze MIPS routers with Entware on internal storage.
# Usage:
#   WEB_TOKEN='change-me' HY2_LINK='hysteria2://...' ROUTE_SOURCES='192.168.1.0/24' sh keenvless-bootstrap.sh

REPO="${KEENVLESS_REPO:-meerovich/keenvless-releases}"
LATEST_URL="${KEENVLESS_LATEST_URL:-https://raw.githubusercontent.com/meerovich/keenvless-releases/main/dist/latest.json}"
WEB_TOKEN="${WEB_TOKEN:-change-me-please}"
HY2_NAME="${HY2_NAME:-HEL-HY2}"
HY2_LINK="${HY2_LINK:-}"
ROUTE_SOURCES="${ROUTE_SOURCES:-192.168.1.0/24}"
REMOTE_WEB_PORT="${REMOTE_WEB_PORT:-8088}"
WORK="${WORK:-/tmp/keenvless-bootstrap}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

echo "[1/9] Checking Entware"
need opkg
mkdir -p "$WORK"

echo "[2/9] Installing dependencies"
opkg update
opkg install ca-bundle ca-certificates curl wget-ssl jq coreutils-sha256sum lighttpd lighttpd-mod-cgi xray iptables || \
opkg install ca-bundle ca-certificates curl wget-ssl jq coreutils-sha256sum lighttpd lighttpd-mod-cgi xray

if [ ! -x /opt/sbin/xray ] && [ -x /opt/bin/xray ]; then
  mkdir -p /opt/sbin
  ln -sf /opt/bin/xray /opt/sbin/xray
fi

need curl
need jq
need sha256sum
[ -x /opt/sbin/xray ] || { echo "xray binary not found at /opt/sbin/xray" >&2; exit 1; }

echo "[3/9] Downloading latest metadata"
curl -fL --connect-timeout 15 -m 90 -o "$WORK/latest.json" "$LATEST_URL"
version="$(jq -r '.version // empty' "$WORK/latest.json")"
file="$(jq -r '.file // empty' "$WORK/latest.json")"
sha="$(jq -r '.sha256 // empty' "$WORK/latest.json")"
[ -n "$version" ] && [ -n "$file" ] && [ -n "$sha" ] || { echo "bad latest.json" >&2; exit 1; }
case "$file" in dist/*) ;; *) echo "bad package path: $file" >&2; exit 1 ;; esac
pkg_url="https://raw.githubusercontent.com/$REPO/main/$file"

echo "[4/9] Downloading package $version"
curl -fL --connect-timeout 15 -m 180 -o "$WORK/package.tar.gz" "$pkg_url"
echo "$sha  $WORK/package.tar.gz" | sha256sum -c -

echo "[5/9] Installing files"
rm -rf "$WORK/unpack"
mkdir -p "$WORK/unpack"
tar -xzf "$WORK/package.tar.gz" -C "$WORK/unpack"
jq -e '.app == "KeenVLESS" and .package_version == 1' "$WORK/unpack/manifest.json" >/dev/null
mkdir -p /opt/bin /opt/share/www /opt/etc/init.d /opt/etc/lighttpd/conf.d /opt/etc/keenvless /opt/etc/xray /opt/var/lib/keenvless /opt/var/log
cp -R "$WORK/unpack/files/opt/." /opt/
chmod 0755 /opt/bin/keenvless /opt/share/www/api.sh /opt/etc/init.d/S99keenvless
chmod 0644 /opt/etc/lighttpd/conf.d/99-keenvless.conf

echo "[6/9] Writing config"
cat > /opt/etc/keenvless/keenvless.conf <<EOF_CONF
APP_VERSION='$version'
GITHUB_REPO='$REPO'
TOKEN_REQUIRED='1'
TOKEN='$WEB_TOKEN'
REMOTE_WEB_ENABLED='1'
REMOTE_WEB_PORT='$REMOTE_WEB_PORT'
REMOTE_WEB_SOURCES=''
ROUTE_TCP_PORTS='80,443'
ROUTE_BLOCK_UDP443='1'
ROUTE_PROFILE='geo'
SERVER_GROUP='auto'
WATCHDOG_ENABLED='1'
WATCHDOG_INTERVAL_MIN='5'
WATCHDOG_PROBE_AFTER_FAILS='3'
WATCHDOG_SWITCH_AFTER_FAILS='6'
WATCHDOG_CANDIDATE_COUNT='5'
WATCHDOG_SWITCH_COOLDOWN_MIN='15'
WATCHDOG_FALLBACK_DIRECT='1'
WATCHDOG_RESTORE_ORIGINAL='1'
WATCHDOG_QUARANTINE_MIN='30'
WATCHDOG_RESTORE_OK_COUNT='2'
WATCHDOG_FLAP_WINDOW_MIN='60'
WATCHDOG_MAX_SWITCHES_WINDOW='3'
MOBILE_WATCHDOG_ENABLED='1'
MOBILE_WATCHDOG_INTERVAL_MIN='5'
MOBILE_WATCHDOG_FAIL_MIN='60'
MOBILE_WATCHDOG_USB_OFF_SEC='10'
MOBILE_WATCHDOG_IFACE='auto'
DNS_MONITOR_ENABLED='0'
DNS_MONITOR_INTERVAL_MIN='15'
DNS_MONITOR_HOSTS='api.ipify.org,ya.ru,youtube.com'
EOF_CONF
chmod 600 /opt/etc/keenvless/keenvless.conf

echo "[7/9] Ensuring lighttpd CGI"
if ! grep -R 'mod_cgi' /opt/etc/lighttpd.conf /opt/etc/lighttpd /opt/etc/lighttpd/conf.d >/dev/null 2>&1; then
  echo 'server.modules += ( "mod_cgi" )' > /opt/etc/lighttpd/conf.d/10-cgi.conf
fi
if [ -s /opt/etc/lighttpd/lighttpd.conf ] && ! grep -q 'conf.d/\*.conf' /opt/etc/lighttpd/lighttpd.conf; then
  echo 'include "/opt/etc/lighttpd/conf.d/*.conf"' >> /opt/etc/lighttpd/lighttpd.conf
fi
if [ -x /opt/etc/init.d/S80lighttpd ]; then
  /opt/etc/init.d/S80lighttpd restart || /opt/etc/init.d/S80lighttpd start
else
  killall lighttpd >/dev/null 2>&1 || true
  lighttpd -f /opt/etc/lighttpd/lighttpd.conf
fi

echo "[8/9] Configuring KeenVLESS"
/opt/bin/keenvless set-web-auth 1 "$WEB_TOKEN"
/opt/bin/keenvless set-remote-web 1 "$REMOTE_WEB_PORT" ""
/opt/bin/keenvless set-config "$ROUTE_SOURCES" "80,443" "1" "" ""

if [ -n "$HY2_LINK" ]; then
  id="$(/opt/bin/keenvless manual-add "$HY2_NAME" "$HY2_LINK" | jq -r '.id // empty')"
  [ -n "$id" ] || { echo "manual-add failed" >&2; exit 1; }
  /opt/bin/keenvless select "$id"
  /opt/bin/keenvless route-on "$ROUTE_SOURCES"
else
  echo "HY2_LINK is empty: profile selection skipped"
fi

/opt/bin/keenvless set-watchdog 1 5 3 6 5 15 1 1 30 2 60 3
/opt/bin/keenvless install-auto
/opt/etc/init.d/S99keenvless restart || /opt/etc/init.d/S99keenvless start

echo "[9/9] Verifying"
/opt/bin/keenvless self-test
/opt/bin/keenvless dependency-doctor
/opt/bin/keenvless health-report
echo "DONE: http://192.168.1.1:${REMOTE_WEB_PORT}/?token=${WEB_TOKEN}#/health"
