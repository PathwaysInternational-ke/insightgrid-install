#!/usr/bin/env bash
# InsightGrid one-step install or upgrade for a client server:
#
#   curl -fsSL https://get-ig.pathwaystechnologies.com | IG_KEY=igk_… bash
#
# It checks the server, enrolls it with the single-use install key Pathways gave you (later runs
# use the site credential saved in $IG_HOME), downloads the release bundle, analyses the server,
# asks the site questions once, and installs. Running it again upgrades to the latest release.
# Environment: IG_KEY, IG_VERSION (default stable), IG_HOME, IG_RELEASES; without a key,
# IG_REGISTRY_USER and IG_TOKEN sign in to the registry directly.
set -Eeuo pipefail
REGISTRY=${IG_REGISTRY:-ghcr.io}
BUNDLE_IMAGE=${IG_BUNDLE_IMAGE:-$REGISTRY/pathwaysinternational-ke/insightgrid-client-release}
TAG=${IG_VERSION:-stable}
RELEASES=${IG_RELEASES:-/opt/insightgrid-releases}
GET_URL=${IG_GET_URL:-https://raw.githubusercontent.com/PathwaysInternational-ke/insightgrid-install/main/get.sh}
PORTAL=${IG_PORTAL:-https://get-ig.pathwaystechnologies.com}
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
# Secrets handed over by the non-root run arrive in private files, never on a command line. They are
# kept in shell variables only, so the installer and Docker never inherit them.
if [ -n "${IG_TOKEN_FILE:-}" ]; then IG_TOKEN=$(cat "$IG_TOKEN_FILE"); rm -f "$IG_TOKEN_FILE"; fi
if [ -n "${IG_KEY_FILE:-}" ]; then IG_KEY=$(cat "$IG_KEY_FILE"); rm -f "$IG_KEY_FILE"; fi
token=${IG_TOKEN:-} key=${IG_KEY:-}; unset IG_TOKEN IG_KEY IG_TOKEN_FILE IG_KEY_FILE
STAGE="" CNAME="" DOCKER_TMP="" HANDOFF=()
cleanup() {
  [ ${#HANDOFF[@]} = 0 ] || rm -f "${HANDOFF[@]}"
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  [ -z "$CNAME" ] || docker rm -f "$CNAME" >/dev/null 2>&1 || true
  [ -z "$DOCKER_TMP" ] || rm -rf "$DOCKER_TMP"
}
trap cleanup EXIT

[ "$(uname -s)" = Linux ] || die "InsightGrid installs on Linux servers."
case "$(uname -m)" in x86_64|amd64) ;; *) die "InsightGrid images are built for x86_64; this server is $(uname -m)." ;; esac
os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-}"); os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
case "$os_id" in ubuntu|debian) ;; *) warn "Untested system ($os_name); Ubuntu or Debian is recommended." ;; esac
[ -r /dev/tty ] || [ -n "$token" ] || [ -n "$key" ] || [ -f "$IG_HOME/.site-credential" ] \
  || die "Run this from an interactive terminal, or set IG_KEY (or IG_REGISTRY_USER and IG_TOKEN)."

ALLOW_ROOT=()
if [ "$(id -u)" -ne 0 ]; then
  # Without root: rerun this script under sudo with the keyboard as input, so prompts and Ctrl+C
  # behave normally (piping into sudo leaves sudo unable to pass Ctrl+C on).
  # Without root, continue only with Docker access and full access to the releases and site folders
  # (a root-owned site folder would hide an unfinished upgrade's markers).
  me=$(id -un); why=()
  if ! out=$(docker info 2>&1 >/dev/null); then
    case "$out" in
      *"permission denied"*) why+=("$me cannot use Docker (to avoid this: sudo usermod -aG docker $me, then sign in again)") ;;
      *) why+=("Docker is not answering (check: sudo systemctl status docker)") ;;
    esac
  fi
  for d in "$RELEASES" "$IG_HOME"; do
    q=$(printf '%q' "$d")
    if [ ! -e "$d" ] && [ ! -L "$d" ] && [ "$d" = "$RELEASES" ]; then mkdir -p "$d" 2>/dev/null || true; fi
    if [ -d "$d" ]; then
      { [ -r "$d" ] && [ -w "$d" ] && [ -x "$d" ]; } || why+=("$me cannot write $d (to avoid this: sudo chown $me: $q && sudo chmod u+rwx $q)")
    elif [ -e "$d" ] || [ -L "$d" ]; then
      why+=("$d is not a folder (move it aside)")
    else
      { [ -w "$(dirname "$d")" ] && [ -x "$(dirname "$d")" ]; } || why+=("$me cannot create $d (to avoid this: sudo install -d -o $me -g $(id -gn) $q)")
    fi
  done
  if [ ${#why[@]} -gt 0 ]; then
    [ -z "${IG_REEXEC:-}" ] || die "sudo did not give administrator rights; ask your server administrator."
    self="${BASH_SOURCE[0]:-}"
    if [ ! -f "$self" ]; then
      self=$(mktemp /tmp/insightgrid-get.XXXXXX); run_bg /dev/null curl -fsSL "$GET_URL" -o "$self" || die "Cannot download $GET_URL"
    fi
    say "Administrator rights are needed because:"; printf '      - %s\n' "${why[@]}"
    say "Continuing with sudo; it may ask for your password."
    mapfile -t pass < <(env | grep -E '^IG_[A-Z_]+=' || true); pass+=(IG_REEXEC=1)
    if [ -n "$token" ]; then
      tokfile=$(mktemp /tmp/insightgrid-token.XXXXXX); HANDOFF+=("$tokfile"); printf '%s' "$token" >"$tokfile"; pass+=(IG_TOKEN_FILE="$tokfile")
    fi
    if [ -n "$key" ]; then
      keyfile=$(mktemp /tmp/insightgrid-key.XXXXXX); HANDOFF+=("$keyfile"); printf '%s' "$key" >"$keyfile"; pass+=(IG_KEY_FILE="$keyfile")
    fi
    # Not exec: if sudo is refused or cancelled, this run still removes the handed-over files.
    # A handler (not an ignore) for Ctrl+C here, so the sudo run still receives it.
    trap ':' INT; rc=0; sudo env "${pass[@]}" bash "$self" </dev/tty || rc=$?; exit "$rc"
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

# Same fingerprint as install.sh's bundle_hash.
# Fails on a symlink (its target could change without changing the hash) or an unreadable file.
bundle_hash() {
  local links; links=$(find "$1" -type l -print -quit) && [ -z "$links" ] || return 1
  (set -o pipefail; cd "$1" && find . -type f ! -name .bundle-digest -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-64)
}
# An upgrade that stopped halfway is finished with the release it started, not a newer latest.
resume=""
if [ -f "$IG_HOME/.upgrade-target" ]; then
  read -r thash resume <"$IG_HOME/.upgrade-target" || true
  [ -x "$resume/install.sh" ] || die "An upgrade is unfinished but its release folder $resume is missing. Ask Pathways before continuing."
  { h=$(bundle_hash "$resume") && [ "$h" = "$thash" ]; } || die "The release folder $resume changed after its upgrade began. Ask Pathways before continuing."
  say "Resuming the unfinished upgrade with $(basename "$resume")"
elif [ -f "$IG_HOME/.upgrade-backup" ]; then
  die "An upgrade started by an earlier installer is unfinished. Finish it by running ./install.sh in the release folder you used."
fi

# ---------- registry access: install key or site credential ----------
SITE_CRED="$IG_HOME/.site-credential"
host=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-' | cut -c1-253)
# portal ACTION JSON-BODY: POSTs the body from stdin (never argv); prints the response body, fails unless 200.
portal() {
  local proto='=https' out code
  [[ ! "$PORTAL" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?$ ]] || proto='=http'   # a local test portal
  out=$(printf '%s' "$2" | curl -sS --proto "$proto" --max-time 30 -H 'content-type: application/json' \
        --data-binary @- -w '\n%{http_code}' "$PORTAL/v1/install/$1") || return 2
  code=${out##*$'\n'}; out=${out%$'\n'*}
  [ "$code" = 200 ] || { [ "$code" = 403 ] && return 3; return 2; }
  printf '%s' "$out"
}
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<<"$2"; }
access=""
if [ "${IG_NO_PULL:-0}" != 1 ]; then
  if [ ! -f "$SITE_CRED" ] && [ -z "$key" ] && [ -z "$token" ] && [ -r /dev/tty ]; then
    ask key "Install key from Pathways (hidden; press Enter to sign in with a registry token instead): " secret
  fi
  if [ -f "$SITE_CRED" ]; then
    site=$(cat "$SITE_CRED"); [[ "$site" =~ ^igs_[0-9a-f]{12}_[0-9a-f]{64}$ ]] || die "$SITE_CRED is damaged. Ask Pathways for a new install key."
    rc=0; access=$(portal renew "{\"site\":\"$site\",\"host\":\"$host\",\"version\":\"$TAG\"}") || rc=$?
    [ "$rc" != 3 ] || die "Pathways refused this server's access (it may have been revoked). Ask Pathways."
    [ "$rc" = 0 ] || die "Cannot reach $PORTAL. Check this server's internet access and run the same command again."
  elif [ -n "$key" ]; then
    [[ "$key" =~ ^igk_[0-9a-f]{12}_[0-9a-f]{64}$ ]] || die "That is not an InsightGrid install key (they start with igk_)."
    say "Enrolling this server"
    rc=0; access=$(portal enroll "{\"key\":\"$key\",\"host\":\"$host\",\"version\":\"$TAG\"}") || rc=$?
    [ "$rc" != 3 ] || die "Pathways refused that install key (used, expired or revoked). Ask Pathways for a new one."
    [ "$rc" = 0 ] || die "Cannot reach $PORTAL. Check this server's internet access and run the same command again."
    site=$(field siteCredential "$access")
    [[ "$site" =~ ^igs_[0-9a-f]{12}_[0-9a-f]{64}$ ]] || die "Unexpected answer from $PORTAL."
    # The key is now spent: losing this file means asking Pathways for a new key.
    { mkdir -p "$IG_HOME" && tmpcred=$(mktemp "$IG_HOME/.site-credential.XXXXXX") && printf '%s\n' "$site" >"$tmpcred" \
        && mv -T "$tmpcred" "$SITE_CRED"; } || die "Could not save $SITE_CRED. Ask Pathways for a new install key."
    say "Server enrolled (site $(cut -d_ -f2 <<<"$site"))"
  fi
  key=""; unset site
  if [ -f "$SITE_CRED" ]; then   # enrolled or renewed above: the answer must be complete
    r_user=$(field username "$access"); r_token=$(field token "$access"); r_host=$(field registry "$access")
    [ "$r_host" = "$REGISTRY" ] && [[ "$r_user" =~ ^[A-Za-z0-9._-]{1,100}$ ]] && [[ "$r_token" =~ ^[A-Za-z0-9._-]{1,400}$ ]] \
      || die "Unexpected answer from $PORTAL."
    # Registry access lives in a private Docker config for this run only; nothing stays on the server.
    # Written directly, not with docker login, which could hand the token to a credential helper.
    DOCKER_TMP=$(mktemp -d /tmp/insightgrid-docker.XXXXXX); export DOCKER_CONFIG=$DOCKER_TMP
    printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$REGISTRY" "$(printf '%s:%s' "$r_user" "$r_token" | base64 -w0)" >"$DOCKER_TMP/config.json"
    unset r_token access
  fi
fi

if [ -z "$resume" ] && [ "${IG_NO_PULL:-0}" != 1 ]; then
  if [ -n "$DOCKER_TMP" ]; then
    run_bg /dev/null docker pull -q "$BUNDLE_IMAGE:$TAG" || die "Cannot download $BUNDLE_IMAGE:$TAG."
  elif ! run_bg /dev/null docker pull -q "$BUNDLE_IMAGE:$TAG"; then
    say "Sign in to Pathways' image registry (read-only access you were given)"
    user=${IG_REGISTRY_USER:-}
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
if [ -n "$resume" ]; then
  dest=$resume; release=$(basename "$resume")
else
# Named before it exists, so cleanup on exit can always find the temporary container.
cname="insightgrid-bundle-$$-$RANDOM"; CNAME=$cname; stage=$(mktemp -d "$RELEASES/.incoming.XXXXXX"); STAGE=$stage
# Resolved once: the bundle unpacked is the one recorded in .bundle-digest, even if the tag moves meanwhile.
# A loaded image (IG_NO_PULL) may carry no registry digest; it is then opened by tag and not recorded.
ref=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$BUNDLE_IMAGE:$TAG" 2>/dev/null | grep -m1 "^$BUNDLE_IMAGE@sha256:") || ref=""
[ -n "$ref" ] || [ "${IG_NO_PULL:-0}" = 1 ] || die "Cannot resolve the downloaded bundle's digest."
run_bg /dev/null docker create --name "$cname" "${ref:-$BUNDLE_IMAGE:$TAG}" /none || die "Cannot open the release bundle."
run_bg /dev/null docker cp "$cname:/bundle/." "$stage/" || die "Cannot unpack the release bundle."
docker rm "$cname" >/dev/null 2>&1 || true
release=$(grep -m1 '^IG_VERSION=' "$stage/release.env" | cut -d= -f2-)
[[ "$release" =~ ^[A-Za-z0-9._-]+$ ]] && [ -x "$stage/install.sh" ] || die "The downloaded bundle is incomplete."
# An older installer would not refuse a downgrade itself, so an undated release never replaces a dated one.
if grep -q '^IG_RELEASED_AT=.' "$IG_HOME/installed-release.env" 2>/dev/null && ! grep -q '^IG_RELEASED_AT=.' "$stage/release.env"; then
  die "Release $release carries no release date but this site's installed release does; it may be older. Ask Pathways for a current release."
fi
dest="$RELEASES/$release"
if [ -d "$dest" ]; then
  modes() { (set -o pipefail; cd "$1" && find . -mindepth 1 ! -name .bundle-digest -printf '%m %p\n' | LC_ALL=C sort); }
  { diff -rq -x .bundle-digest "$stage" "$dest" >/dev/null 2>&1 && m1=$(modes "$stage") && m2=$(modes "$dest") && [ "$m1" = "$m2" ]; } \
    || die "$dest exists with different contents; move it aside and rerun."
else
  chmod 755 "$stage"; mv "$stage" "$dest"
fi
if [ -n "$ref" ]; then echo "$ref" >"$dest/.bundle-digest"; else rm -f "$dest/.bundle-digest"; fi
fi
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
if [ -f "$SITE_CRED" ] && [ "${IG_NO_PULL:-0}" != 1 ]; then
  now=$(grep -m1 '^IG_VERSION=' "$IG_HOME/installed-release.env" 2>/dev/null | cut -d= -f2-) || now=""
  [[ "$now" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || now=$release
  portal report "{\"site\":\"$(cat "$SITE_CRED")\",\"host\":\"$host\",\"version\":\"$now\"}" >/dev/null \
    || warn "Installed, but could not tell Pathways which version this server runs."
fi
if grep -q '^IG_TLS=internal' "$IG_HOME/site.env" 2>/dev/null; then
  warn "Private site: install $IG_HOME/extra-ca.crt as a trusted root certificate on each computer that opens InsightGrid."
fi
