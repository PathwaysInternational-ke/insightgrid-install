#!/usr/bin/env bash
# InsightGrid one-step install or upgrade for a client server:
#
#   curl -fsSL https://raw.githubusercontent.com/PathwaysInternational-ke/insightgrid-install/main/get.sh | bash
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
GET_URL=${IG_GET_URL:-https://raw.githubusercontent.com/PathwaysInternational-ke/insightgrid-install/main/get.sh}
export IG_HOME=${IG_HOME:-/opt/insightgrid}

bold=$'\033[1m' red=$'\033[1;31m' orange=$'\033[1;38;5;208m' green=$'\033[1;32m' off=$'\033[0m'
[ -t 1 ] || bold="" red="" orange="" green="" off=""
say() { printf '%s==>%s %s\n' "$bold" "$off" "$*"; }
warn() { printf '%s==> %s%s\n' "$orange" "$*" "$off"; }
die() { printf '%sError:%s %s\n' "$red" "$off" "$*" >&2; exit 1; }
# stdin is this script (curl | bash), so questions read the terminal.
ask() {  # asks again after a declined Ctrl+C
  local reply rc
  ASK_PROMPT="$2"
  while :; do read -r ${3:+-s} -p "$2" reply </dev/tty && rc=0 || rc=$?; [ "$rc" -le 128 ] && break; done
  ASK_PROMPT=""
  [ -z "${3:-}" ] || echo; printf -v "$1" '%s' "$reply"
}
WORKER="" ASK_PROMPT=""   # a background job Ctrl+C may stop; the question being asked
on_interrupt() {
  local a=""
  printf '\n'
  read -r -p "${orange}Stop the installer? Running the same command later continues safely. [y/N]${off} " a </dev/tty || a=y
  case "$a" in y|Y|yes) ;; *) echo "Continuing."; printf '%s' "$ASK_PROMPT"; return 0 ;; esac
  [ -z "$WORKER" ] || kill -TERM -- "-$WORKER" 2>/dev/null || true
  die "Stopped by request. Run the same command again to continue."
}
trap on_interrupt INT
# run_bg LOG CMD...: runs CMD in its own session with output to LOG, so a declined Ctrl+C cannot
# interrupt it (Ctrl+C then "y" stops it). With a real LOG, its last line is shown as progress.
run_bg() {
  local log=$1 rc=0; shift
  setsid "$@" </dev/null >"$log" 2>&1 & WORKER=$!
  while kill -0 "$WORKER" 2>/dev/null; do
    [ "$log" = /dev/null ] || [ ! -t 1 ] || printf '\r\033[K  %s' "$(tail -n1 "$log" 2>/dev/null | cut -c1-90 || true)"
    sleep 1 || true
  done
  [ "$log" = /dev/null ] || [ ! -t 1 ] || printf '\r\033[K'
  wait "$WORKER" || rc=$?; WORKER=""
  return "$rc"
}
# A token handed over by the non-root run arrives in a private file, never on a command line.
if [ -n "${IG_TOKEN_FILE:-}" ]; then IG_TOKEN=$(cat "$IG_TOKEN_FILE"); rm -f "$IG_TOKEN_FILE"; export IG_TOKEN; fi

[ "$(uname -s)" = Linux ] || die "InsightGrid installs on Linux servers."
case "$(uname -m)" in x86_64|amd64) ;; *) die "InsightGrid images are built for x86_64; this server is $(uname -m)." ;; esac
os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-}"); os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
case "$os_id" in ubuntu|debian) ;; *) warn "Untested system ($os_name); Ubuntu or Debian is recommended." ;; esac
[ -r /dev/tty ] || [ -n "${IG_TOKEN:-}" ] || die "Run this from an interactive terminal, or set IG_REGISTRY_USER and IG_TOKEN."

ALLOW_ROOT=()
if [ "$(id -u)" -ne 0 ]; then
  # Without root: rerun this script under sudo with the keyboard as input, so prompts and Ctrl+C
  # behave normally (piping into sudo leaves sudo unable to pass Ctrl+C on).
  if ! { docker info >/dev/null 2>&1 && mkdir -p "$RELEASES" 2>/dev/null && [ -w "$RELEASES" ]; }; then
    [ -z "${IG_REEXEC:-}" ] || die "sudo did not give administrator rights; ask your server administrator."
    self="${BASH_SOURCE[0]:-}"
    if [ ! -f "$self" ]; then
      self=$(mktemp /tmp/insightgrid-get.XXXXXX); run_bg /dev/null curl -fsSL "$GET_URL" -o "$self" || die "Cannot download $GET_URL"
    fi
    say "Administrator rights are needed; sudo may ask for your password."
    mapfile -t pass < <(env | grep -E '^IG_[A-Z_]+=' | grep -v '^IG_TOKEN=' || true); pass+=(IG_REEXEC=1)
    if [ -n "${IG_TOKEN:-}" ]; then
      tokfile=$(mktemp /tmp/insightgrid-token.XXXXXX); printf '%s' "$IG_TOKEN" >"$tokfile"; pass+=(IG_TOKEN_FILE="$tokfile")
    fi
    exec sudo env "${pass[@]}" bash "$self" </dev/tty
  fi
elif [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then
  printf '%s' "$orange"; cat <<'MSG'
You are signed in as root. We recommend a named administrator account instead, so every action
is traceable and root login can be switched off:

  adduser itadmin && usermod -aG sudo itadmin      (then add your SSH key for itadmin)
  sign in as itadmin and run the same command there

MSG
  printf '%s' "$off"
  ask answer "Type ROOT to continue as root anyway, or press Enter to stop: "
  [ "$answer" = ROOT ] || die "Stopped. Nothing was changed."
  ALLOW_ROOT=(--allow-root)
fi

mkdir -p "$RELEASES"
exec 8<"$RELEASES"
flock -n 8 || die "Another InsightGrid install is already running on this server."

if ! command -v docker >/dev/null; then
  say "Installing Docker Engine from download.docker.com (a few minutes)"
  dscript=$(mktemp /tmp/insightgrid-docker.XXXXXX); dlog=$(mktemp /tmp/insightgrid-docker-install.XXXXXX)
  run_bg /dev/null curl -fsSL https://get.docker.com -o "$dscript" || die "Cannot reach download.docker.com. Allow outbound HTTPS, or ask Pathways for the offline bundle."
  run_bg "$dlog" sh "$dscript" || die "Docker installation failed; see $dlog"
  rm -f "$dscript"
  command -v systemctl >/dev/null && systemctl enable --now docker >/dev/null 2>&1 || true
fi
docker compose version >/dev/null 2>&1 || die "Docker is installed but the Compose plugin is missing: install docker-compose-plugin."

if [ "${IG_NO_PULL:-0}" != 1 ]; then
  if ! run_bg /dev/null docker pull -q "$BUNDLE_IMAGE:$TAG"; then
    say "Sign in to Pathways' image registry (read-only access you were given)"
    user=${IG_REGISTRY_USER:-}; token=${IG_TOKEN:-}
    [ -n "$user" ] || ask user "  Registry username: "
    [ -n "$token" ] || ask token "  Access token (hidden): " secret
    printf '%s' "$token" | docker login "$REGISTRY" -u "$user" --password-stdin >/dev/null 2>&1 \
      || die "The registry refused that username and token. Check them with Pathways."
    unset token
    say "Downloading release bundle ($TAG)"
    run_bg /dev/null docker pull -q "$BUNDLE_IMAGE:$TAG" || die "Cannot download $BUNDLE_IMAGE:$TAG. Is this token allowed to read it?"
  fi
fi

# Unpack next to the releases, then rename into place: an interrupted copy never leaves a half release.
# Named before it exists, so cleanup on exit can always find the temporary container.
cname="insightgrid-bundle-$$-$RANDOM"; stage=$(mktemp -d "$RELEASES/.incoming.XXXXXX")
trap 'rm -rf "$stage"; docker rm -f "$cname" >/dev/null 2>&1 || true' EXIT
run_bg /dev/null docker create --name "$cname" "$BUNDLE_IMAGE:$TAG" /none || die "Cannot open the release bundle."
run_bg /dev/null docker cp "$cname:/bundle/." "$stage/" || die "Cannot unpack the release bundle."
docker rm "$cname" >/dev/null 2>&1 || true
release=$(grep -m1 '^IG_VERSION=' "$stage/release.env" | cut -d= -f2-)
[[ "$release" =~ ^[A-Za-z0-9._-]+$ ]] && [ -x "$stage/install.sh" ] || die "The downloaded bundle is incomplete."
dest="$RELEASES/$release"
if [ -d "$dest" ]; then
  diff -rq -x .bundle-digest "$stage" "$dest" >/dev/null 2>&1 || die "$dest exists with different contents; move it aside and rerun."
else
  chmod 755 "$stage"; mv "$stage" "$dest"
fi
docker image inspect -f '{{index .RepoDigests 0}}' "$BUNDLE_IMAGE:$TAG" >"$dest/.bundle-digest" 2>/dev/null || true
say "Release $release in $dest"

cd "$dest"
say "Analysing this server"
trap ':' INT   # the installer asks about Ctrl+C itself
rc=0; ./install.sh check || rc=$?
[ "$rc" != 130 ] || exit 130
[ "$rc" = 0 ] || die "Fix the items marked ✗ above, then run the same command again."
trap on_interrupt INT
say "Installing InsightGrid $release"
trap ':' INT   # the installer asks about Ctrl+C itself
rc=0; ./install.sh "${ALLOW_ROOT[@]}" || rc=$?
trap on_interrupt INT
[ "$rc" = 0 ] || exit "$rc"
if grep -q '^IG_TLS=internal' "$IG_HOME/site.env" 2>/dev/null; then
  warn "Private site: install $IG_HOME/extra-ca.crt as a trusted root certificate on each computer that opens InsightGrid."
fi
