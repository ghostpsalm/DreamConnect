#!/usr/bin/env bash
#
# DreamConnect network installer.
#
#   curl -fsSL https://github.com/ghostpsalm/DreamConnect/releases/latest/download/dreamconnect-install.sh | sudo bash
#
# Fetches the latest DreamConnect release source and runs its install.sh, which
# detects the desktop user / ScreenConnect unit / capture monitor, builds the
# agent, deploys to /opt/dreamconnect, and wires up both systemd services.
#
# This script is published as a release asset, so the URL above stays the same
# across versions and always installs the newest release. To uninstall, run
# `sudo ./install.sh --uninstall` from a source checkout of the repo.
set -euo pipefail

REPO="ghostpsalm/DreamConnect"

if [ "$(id -u)" -ne 0 ]; then
  echo "DreamConnect install must run as root, e.g.:" >&2
  echo "  curl -fsSL https://github.com/$REPO/releases/latest/download/dreamconnect-install.sh | sudo bash" >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need curl
need tar

echo ">> resolving latest DreamConnect release..."
# The /releases/latest URL redirects to /releases/tag/<tag>; grab the tag.
tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed -n 's#.*/releases/tag/##p')"
if [ -z "$tag" ]; then
  echo "could not determine the latest release (no releases published yet?)" >&2
  exit 1
fi
echo ">> installing DreamConnect $tag"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/$REPO/archive/refs/tags/$tag.tar.gz" | tar -xz -C "$tmp" --strip-components=1

cd "$tmp"
[ -f install.sh ] || { echo "release $tag has no install.sh" >&2; exit 1; }
exec bash install.sh "$@"
