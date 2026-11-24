#!/usr/bin/env bash
# InsightGrid one-step install or upgrade for a client server:
#
#   curl -fsSL https://raw.githubusercontent.com/PathwaysInternational-ke/insightgrid-install/main/get.sh | sudo bash
#
# It checks the server, installs Docker if missing, signs in to Pathways' private registry with
# the access token you were given, downloads the release bundle, analyses the server, asks the
# site questions once, and installs. Running it again upgrades to the latest release.
# Environment: IG_VERSION (default latest), IG_REGISTRY_USER, IG_TOKEN, IG_HOME, IG_RELEASES.
set -Eeuo pipefail
REGISTRY=ghcr.io
BUNDLE_IMAGE=${IG_BUNDLE_IMAGE:-$REGISTRY/pathwaysinternational-ke/insightgrid-client-bundle}
TAG=${IG_VERSION:-latest}
RELEASES=${IG_RELEASES:-/opt/insightgrid-releases}
export IG_HOME=${IG_HOME:-/opt/insightgrid}

bold=$'\033[1m' red=$'\033[1;31m' orange=$'\033[1;38;5;208m' green=$'\033[1;32m' off=$'\033[0m'
[ -t 1 ] || bold="" red="" orange="" green="" off=""
say() { printf '%s==>%s %s\n' "$bold" "$off" "$*"; }
warn() { printf '%s==> %s%s\n' "$orange" "$*" "$off"; }
die() { printf '%sError:%s %s\n' "$red" "$off" "$*" >&2; exit 1; }
# stdin is this script (curl | bash), so questions read the terminal.
ask() { local reply; read -r ${3:+-s} -p "$2" reply </dev/tty || true; [ -z "${3:-}" ] || echo; printf -v "$1" '%s' "$reply"; }

[ "$(uname -s)" = Linux ] || die "InsightGrid installs on Linux servers."
case "$(uname -m)" in x86_64|amd64) ;; *) die "InsightGrid images are built for x86_64; this server is $(uname -m)." ;; esac
os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-}"); os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
case "$os_id" in ubuntu|debian) ;; *) warn "Untested system ($os_name); Ubuntu or Debian is recommended." ;; esac
[ -r /dev/tty ] || [ -n "${IG_TOKEN:-}" ] || die "Run this from an interactive terminal, or set IG_REGISTRY_USER and IG_TOKEN."

ALLOW_ROOT=()
if [ "$(id -u)" -ne 0 ]; then
  docker info >/dev/null 2>&1 && mkdir -p "$RELEASES" 2>/dev/null && [ -w "$RELEASES" ] \
    || die "Run it with sudo:  curl -fsSL https://raw.githubusercontent.com/PathwaysInternational-ke/insightgrid-install/main/get.sh | sudo bash"
elif [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then
  printf '%s' "$orange"; cat <<'MSG'
You are signed in as root. We recommend a named administrator account instead, so every action
is traceable and root login can be switched off:

  adduser itadmin && usermod -aG sudo itadmin      (then add your SSH key for itadmin)
  sign in as itadmin and run the same command with sudo

MSG
  printf '%s' "$off"
  ask answer "Type ROOT to continue as root anyway, or press Enter to stop: "
  [ "$answer" = ROOT ] || die "Stopped. Nothing was changed."
  ALLOW_ROOT=(--allow-root)
fi

if ! command -v docker >/dev/null; then
  say "Installing Docker Engine from download.docker.com"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || die "Cannot reach download.docker.com. Allow outbound HTTPS, or ask Pathways for the offline bundle."
  sh /tmp/get-docker.sh >/tmp/get-docker.log 2>&1 || die "Docker installation failed; see /tmp/get-docker.log"
  rm -f /tmp/get-docker.sh
  command -v systemctl >/dev/null && systemctl enable --now docker >/dev/null 2>&1 || true
fi
docker compose version >/dev/null 2>&1 || die "Docker is installed but the Compose plugin is missing: install docker-compose-plugin."

if [ "${IG_NO_PULL:-0}" != 1 ]; then
  if ! docker pull -q "$BUNDLE_IMAGE:$TAG" >/dev/null 2>&1; then
    say "Sign in to Pathways' image registry (read-only access you were given)"
    user=${IG_REGISTRY_USER:-}; token=${IG_TOKEN:-}
    [ -n "$user" ] || ask user "  Registry username: "
    [ -n "$token" ] || ask token "  Access token (hidden): " secret
    printf '%s' "$token" | docker login "$REGISTRY" -u "$user" --password-stdin >/dev/null 2>&1 \
      || die "The registry refused that username and token. Check them with Pathways."
    unset token
    say "Downloading release bundle ($TAG)"
    docker pull -q "$BUNDLE_IMAGE:$TAG" >/dev/null || die "Cannot download $BUNDLE_IMAGE:$TAG. Is this token allowed to read it?"
  fi
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cid=$(docker create "$BUNDLE_IMAGE:$TAG" /none)
docker cp "$cid:/bundle/." "$work/" >/dev/null; docker rm "$cid" >/dev/null
release=$(grep -m1 '^IG_VERSION=' "$work/release.env" | cut -d= -f2-)
[ -n "$release" ] && [ -x "$work/install.sh" ] || die "The downloaded bundle is incomplete."
dest="$RELEASES/$release"
mkdir -p "$RELEASES"
if [ -d "$dest" ]; then
  diff -rq -x .bundle-digest "$work" "$dest" >/dev/null 2>&1 || die "$dest exists with different contents; move it aside and rerun."
else
  cp -a "$work" "$dest"; chmod 755 "$dest"
fi
docker image inspect -f '{{index .RepoDigests 0}}' "$BUNDLE_IMAGE:$TAG" >"$dest/.bundle-digest" 2>/dev/null || true
say "Release $release in $dest"

cd "$dest"
say "Analysing this server"
./install.sh check || die "Fix the items marked ✗ above, then run the same command again."
say "Installing InsightGrid $release"
./install.sh "${ALLOW_ROOT[@]}"
if grep -q '^IG_TLS=internal' "$IG_HOME/site.env" 2>/dev/null; then
  warn "Private site: install $IG_HOME/extra-ca.crt as a trusted root certificate on each computer that opens InsightGrid."
fi
