#!/bin/sh
# Install tsuna for the current user, without root:
#   - downloads a release archive and its signed checksums,
#   - verifies the minisign signature and the archive's SHA-256,
#   - installs the binary to $TSUNA_PREFIX/bin (default ~/.local/bin),
#   - installs a systemd user unit / launchd agent running `tsuna agent`.
#
# Settings (environment):
#   TSUNA_VERSION          version, e.g. v1.2.3 or v1.3.0-rc.1 (default: the latest release)
#   TSUNA_PREFIX           install prefix (default: $HOME/.local)
#   TSUNA_NO_SERVICE=1     do not install the user service
#   TSUNA_PUBLIC_KEY       minisign public key (default: the one baked in below)
#   TSUNA_SKIP_SIGNATURE=1 only check the SHA-256, when minisign is not installed
#                          (the checksums then come from the download host unsigned)
#   TSUNA_RELEASE_API      releases API (default: the project's GitHub API)
#   TSUNA_DOWNLOAD_BASE    where assets live (default: the project's GitHub releases)
set -eu

# A repository shared with other projects: tsuna's releases are tagged tsuna-v1.2.3.
REPO="${TSUNA_REPO:-Capyful/artifacts}"
API="${TSUNA_RELEASE_API:-https://api.github.com/repos/$REPO/releases}"
BASE="${TSUNA_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"
VERSION="${TSUNA_VERSION:-latest}"
PREFIX="${TSUNA_PREFIX:-$HOME/.local}"
# Replaced with the release public key when a release is cut (see docs/install.md).
PUBKEY="${TSUNA_PUBLIC_KEY:-RWRXcMyak98QSP4HjoREf1P6tzCMQyLQr1/99JFCDIt0h9ZoXAOTAH5V}"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "do not run this as root: tsuna is a per-user tool (it syncs the config of the user who runs it)"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  *) die "unsupported OS $(uname -s) (Linux and macOS only)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) die "unsupported CPU $(uname -m)" ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/.*= *//'
  else die "need sha256sum, shasum or openssl"; fi
}

# Refuse before downloading anything when verification cannot happen.
CAN_VERIFY_SIG=0
if command -v minisign >/dev/null 2>&1 && [ "${PUBKEY#@}" = "$PUBKEY" ]; then
  CAN_VERIFY_SIG=1
elif [ "${TSUNA_SKIP_SIGNATURE:-0}" != 1 ]; then
  die "cannot verify the release signature: install minisign (https://jedisct1.github.io/minisign/) and make sure a public key is set (TSUNA_PUBLIC_KEY), or set TSUNA_SKIP_SIGNATURE=1 to only check the SHA-256 (weaker)"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tsuna-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

if [ "$VERSION" = latest ]; then
  # The stable versions among the tsuna-v* tags (all of them, in one
  # unpaginated response), highest first: the repository's own "latest" may
  # be another project's, and prereleases are installed only when asked for.
  # Up to five versions are tried, like self-update (maxTagsTried in
  # internal/update/update.go). A failed request is told apart from no tags.
  REFS="${API%/releases}/git/matching-refs/tags/tsuna-v"
  code="$(curl -sL -o "$TMP/refs.json" -w '%{http_code}' "$REFS")" || code=000
  [ "$code" = 200 ] || die "could not list the tsuna releases at $REFS (HTTP $code)"
  CANDIDATES="$(tr ',' '\n' < "$TMP/refs.json" \
    | sed -n 's/.*"ref"[ ]*:[ ]*"refs\/tags\/tsuna-v\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -n5)"
  [ -n "$CANDIDATES" ] || die "there is no tsuna release at $REFS"
else
  CANDIDATES="${VERSION#tsuna-v}"
  CANDIDATES="${CANDIDATES#v}"
fi
# A tag left behind by a deleted release (`gh release delete` keeps it) has
# no checksums.txt (404): try the next version. Any other failure stops here,
# so a network or server error never quietly installs an older release.
NUM=
for v in $CANDIDATES; do
  code="$(curl -sL -o "$TMP/checksums.txt" -w '%{http_code}' "$BASE/tsuna-v$v/checksums.txt")" || code=000
  case "$code" in
    200) NUM="$v"; break ;;
    404) say "no release for tsuna-v$v" ;;
    *) die "download of checksums.txt for tsuna-v$v failed (HTTP $code)" ;;
  esac
done
[ -n "$NUM" ] || die "no downloadable tsuna release among: $(printf '%s' "$CANDIDATES" | tr '\n' ' ')"
TAG="tsuna-v$NUM"
NAME="tsuna_${NUM}_${OS}_${ARCH}.tar.gz"
say "installing tsuna v$NUM ($OS/$ARCH)"

dl() { curl -fsSL -o "$TMP/$1" "$BASE/$TAG/$1" || die "download of $1 failed ($BASE/$TAG/$1)"; }
if [ "$CAN_VERIFY_SIG" = 1 ]; then
  dl checksums.txt.minisig
  minisign -Vm "$TMP/checksums.txt" -x "$TMP/checksums.txt.minisig" -P "$PUBKEY" >/dev/null \
    || die "the signature of checksums.txt does not verify: refusing to install"
  say "signature verified"
else
  say "warning: signature NOT verified (TSUNA_SKIP_SIGNATURE=1); only the SHA-256 is checked" >&2
fi

dl "$NAME"
WANT="$(awk -v n="$NAME" '$2 == n || $2 == "*" n { print $1 }' "$TMP/checksums.txt" | head -n1)"
[ -n "$WANT" ] || die "$NAME is not in checksums.txt"
[ "$(sha256_of "$TMP/$NAME")" = "$WANT" ] || die "checksum of $NAME does not match: refusing to install"

mkdir "$TMP/x"
tar -xzf "$TMP/$NAME" -C "$TMP/x" tsuna || die "no tsuna binary in $NAME"
BIN="$PREFIX/bin"
mkdir -p "$BIN"
# Copy next to the destination, then rename: replaces a running binary safely.
cp "$TMP/x/tsuna" "$BIN/.tsuna.new.$$"
chmod 0755 "$BIN/.tsuna.new.$$"
mv -f "$BIN/.tsuna.new.$$" "$BIN/tsuna"
say "installed $BIN/tsuna"

if [ "${TSUNA_NO_SERVICE:-0}" = 1 ]; then
  say "skipping the user service (TSUNA_NO_SERVICE=1); later: $BIN/tsuna service install --enable"
else
  ENABLE=--enable
  if [ "$OS" = linux ] && ! command -v systemctl >/dev/null 2>&1; then
    say "systemctl not found: writing the unit but not enabling it"
    ENABLE=
  fi
  # shellcheck disable=SC2086
  "$BIN/tsuna" service install --exe "$BIN/tsuna" $ENABLE || say "warning: could not set up the user service; run: $BIN/tsuna service install --enable"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "note: $BIN is not on your PATH" ;;
esac
say "next: tsuna agent enroll <server-url> <token>   (the token comes from the portal)"
