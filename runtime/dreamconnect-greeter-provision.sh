#!/usr/bin/env bash
#
# dreamconnect-greeter-provision.sh — set up the local login view greeter mode
# serves, and tear it down again.
#
# Greeter mode is an RDP client of gnome-remote-desktop's *system* daemon
# (Remote Login). This script configures that daemon: TLS, a transport
# credential, and a firewall guard that keeps the listener off the network.
#
#   dreamconnect-greeter-provision.sh enable  [port]
#   dreamconnect-greeter-provision.sh disable [port]
#   dreamconnect-greeter-provision.sh status  [port]
#
# The transport credential is generated here, never typed and never passed as an
# argument. It is written to a 0600 file the daemon account reads; nothing else
# needs to know it.
#
# Root only: it configures a system service and the firewall.
set -euo pipefail

PORT="${2:-${DREAMCONNECT_GREETER_PORT:-3389}}"
RDP_USER="${DREAMCONNECT_GREETER_USER:-dreamconnect}"
DAEMON_ACCOUNT="${DREAMCONNECT_GREETER_ACCOUNT:-${SUDO_USER:-root}}"
SECRET_DIR="${DREAMCONNECT_GREETER_SECRET_DIR:-/etc/dreamconnect}"
SECRET="$SECRET_DIR/greeter-rdp.pw"

GRD_HOME=/var/lib/gnome-remote-desktop
TLS_DIR="$GRD_HOME/.local/share/gnome-remote-desktop"

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "must run as root"

# grdctl resolves its credential store from the *calling* process's data dir, so
# a credential set under sudo lands in root's store and the daemon — which runs
# as gnome-remote-desktop — never sees it. Every grdctl call that touches
# credentials must therefore run as that account.
as_grd() { runuser -u gnome-remote-desktop -- env HOME="$GRD_HOME" "$@"; }

# firewalld opens 1025-65535/tcp in the FedoraWorkstation zone, so simply *not*
# opening the port leaves it reachable. An explicit drop is required. Permanent
# as well as runtime: greeter mode must not become network-reachable at reboot.
guard_firewall() {
  command -v firewall-cmd >/dev/null 2>&1 || {
    echo "warning: firewalld not found — confirm $PORT is not reachable off-box" >&2
    return 0
  }
  local action="$1" flag
  case "$action" in add) flag=--add-rich-rule ;; remove) flag=--remove-rich-rule ;; esac
  for family in ipv4 ipv6; do
    for scope in "" --permanent; do
      firewall-cmd $scope "$flag=rule family=\"$family\" port port=\"$PORT\" protocol=\"tcp\" drop" \
        >/dev/null 2>&1 || true
    done
  done
}

enable_greeter() {
  command -v grdctl >/dev/null 2>&1 || die "gnome-remote-desktop is not installed"
  command -v winpr-makecert >/dev/null 2>&1 || die "freerdp is not installed"

  guard_firewall add

  as_grd mkdir -p "$TLS_DIR"
  if [ ! -s "$TLS_DIR/tls.key" ]; then
    as_grd winpr-makecert -silent -rdp -path "$TLS_DIR" tls >/dev/null
    # winpr-makecert leaves the key 0644. Only the 0700 parent is saving it.
    chmod 600 "$TLS_DIR/tls.key"
  fi

  # mkdir -p, not `install -d -m ...`: this directory belongs to the installer
  # (it holds install.state) and is created there with root's umask, i.e. 0755.
  # Forcing a mode here would silently retighten a shared directory — and 0700
  # locks the daemon account out of its own credential. The file's own 0600 plus
  # its ownership is what protects the secret.
  mkdir -p "$SECRET_DIR"
  if [ ! -s "$SECRET" ]; then
    ( umask 077; openssl rand -base64 30 | tr -d '\n=+/' > "$SECRET" )
  fi
  chmod 600 "$SECRET"
  chown "$DAEMON_ACCOUNT" "$SECRET"

  grdctl --system rdp set-port "$PORT"
  grdctl --system rdp set-tls-key "$TLS_DIR/tls.key"
  grdctl --system rdp set-tls-cert "$TLS_DIR/tls.crt"
  # Username as an argument, password on stdin. Piping both lines does not work:
  # grdctl opens a fresh buffered stream per prompt, so the username read
  # swallows the password line, the password read hits EOF, and it crashes
  # (SIGSEGV) — dumping the credential into a coredump on the way out.
  as_grd grdctl --system rdp set-credentials "$RDP_USER" < "$SECRET"
  grdctl --system rdp enable

  systemctl is-active --quiet gdm.service \
    || echo "warning: gdm.service is not running; there is no greeter to serve" >&2

  echo "greeter login view enabled on 127.0.0.1:$PORT (dropped off-box)"
  echo "credential: $SECRET (0600, $DAEMON_ACCOUNT)"
  grdctl --system status | sed -n '/TLS fingerprint/p'
}

disable_greeter() {
  grdctl --system rdp disable || true
  systemctl disable --now gnome-remote-desktop.service >/dev/null 2>&1 || true
  rm -f /etc/gnome-remote-desktop/grd.conf
  rm -f "$TLS_DIR/tls.key" "$TLS_DIR/tls.crt" "$TLS_DIR/credentials.ini"
  rm -f "$SECRET"
  guard_firewall remove
  echo "greeter login view disabled"
}

status_greeter() {
  grdctl --system status || true
  echo "--- listener ---"
  ss -lntp 2>/dev/null | grep ":$PORT" || echo "  nothing listening on $PORT"
  echo "--- credential ---"
  if [ -s "$SECRET" ]; then ls -l "$SECRET"; else echo "  absent"; fi
}

case "${1:-}" in
  enable)  enable_greeter ;;
  disable) disable_greeter ;;
  status)  status_greeter ;;
  *) echo "usage: $0 enable|disable|status [port]" >&2; exit 2 ;;
esac
