#!/bin/sh
# Bootstrap installer for waf-mke: the `curl ... | sh` front door.
#
#   curl -fsSL https://raw.githubusercontent.com/elmaxid/waf-mke-releases/main/bootstrap.sh | sh
#
# It resolves the release from the public releases repo, VERIFIES THE ED25519
# SIGNATURE of checksums.txt with `openssl pkeyutl -verify -rawin` (OpenSSL 3)
# against the public key embedded below, then checks the tarball's sha256
# against that verified file, checks the host with `waf-mke doctor` and runs
# `waf-mke install` (the binary does the real work: user, layout, unit, example
# config). install never enables or starts the service; with a terminal the
# script then hands over to `waf-mke setup`, which does (WAF_MKE_SETUP=skip
# avoids it; no terminal means no prompt).
#
# Honest limit: this script is its own root of trust. The signature protects
# against a tampered release ASSET (tarball, checksums.txt); it cannot protect
# against a tampered copy of this script, which is what carries the key.
# Nothing downloaded is extracted or run before the signature has verified. If
# openssl is missing or older than 3, the script stops; there is no way to skip.
#
# Overrides (environment):
#   WAF_MKE_VERSION       latest (default: newest STABLE release) or a tag such
#                         as v0.5.0-rc.1 (exactly that one, pre-release or not)
#   WAF_MKE_PRE           1: `latest` also considers pre-releases (rc)
#   WAF_MKE_SETUP         skip: install only, do not run `waf-mke setup`
#   WAF_MKE_REPO          default elmaxid/waf-mke-releases
#   WAF_MKE_API_URL       releases list, default
#                         https://api.github.com/repos/$WAF_MKE_REPO/releases
#   WAF_MKE_DOWNLOAD_URL  base up to /releases/download, default
#                         https://github.com/$WAF_MKE_REPO/releases/download
#   WAF_MKE_PUBKEY_FILE   TESTS ONLY: use this public key instead of the embedded one;
#                         refused unless WAF_MKE_TEST_MODE=1 is also set
#   WAF_MKE_TEST_MODE     TESTS ONLY: 1 allows http:// for WAF_MKE_API_URL and
#                         WAF_MKE_DOWNLOAD_URL, and only for http://127.0.0.1.
#                         Without it every URL must be https:// and curl runs
#                         with --proto =https --proto-redir =https (a redirect
#                         to http is never followed, in any mode).
#
# `latest` reads the first 30 releases (newest first). The JSON is parsed with
# a small awk program that looks only at the top-level fields tag_name,
# prerelease and draft of each release object, so field order, whitespace and
# nested objects do not matter; it assumes the API's normal JSON, not arbitrary
# JSON.
#
# Needs: POSIX sh, curl or wget, openssl >= 3, sha256sum, tar, awk; sudo when
# not root.
# odd/tasks/bootstrap-installer.md S1-S3, odd/tasks/release-channel.md S6.
set -eu

WAF_MKE_REPO=${WAF_MKE_REPO:-elmaxid/waf-mke-releases}
WAF_MKE_API_URL=${WAF_MKE_API_URL:-https://api.github.com/repos/$WAF_MKE_REPO/releases}
WAF_MKE_DOWNLOAD_URL=${WAF_MKE_DOWNLOAD_URL:-https://github.com/$WAF_MKE_REPO/releases/download}
WAF_MKE_VERSION=${WAF_MKE_VERSION:-latest}
WAF_MKE_PRE=${WAF_MKE_PRE:-}
WAF_MKE_SETUP=${WAF_MKE_SETUP:-auto}
WAF_MKE_PUBKEY_FILE=${WAF_MKE_PUBKEY_FILE:-}
WAF_MKE_TEST_MODE=${WAF_MKE_TEST_MODE:-}

say()  { printf '%s\n' "$*"; }
fail() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }

# A public key override is a test device: it must never be reachable by setting
# one variable by accident or by a hostile environment.
if [ -n "$WAF_MKE_PUBKEY_FILE" ] && [ "$WAF_MKE_TEST_MODE" != 1 ]; then
    fail "WAF_MKE_PUBKEY_FILE is for tests only and needs WAF_MKE_TEST_MODE=1 as well; nothing was changed"
fi

# The default path is https only. http is possible only in test mode and only
# for a loopback source that was set explicitly.
check_url() { # check_url <name> <value>
    case "$2" in
        https://*) ;;
        http://127.0.0.1:*|http://127.0.0.1/*)
            [ "$WAF_MKE_TEST_MODE" = 1 ] || fail "$1 must be an https:// URL (got '$2'); http://127.0.0.1 needs WAF_MKE_TEST_MODE=1 (tests only)" ;;
        *) fail "$1 must be an https:// URL (got '$2')" ;;
    esac
}
check_url WAF_MKE_API_URL "$WAF_MKE_API_URL"
check_url WAF_MKE_DOWNLOAD_URL "$WAF_MKE_DOWNLOAD_URL"

if [ "$WAF_MKE_TEST_MODE" = 1 ]; then
    CURL_PROTO=http,https
else
    CURL_PROTO=https
fi

WORK=$(mktemp -d /tmp/waf-mke-bootstrap.XXXXXX)
ROOTDIR=
cleanup() {
    rm -rf "$WORK"
    if [ -n "$ROOTDIR" ]; then sudo rm -rf "$ROOTDIR"; fi
}
trap cleanup EXIT

# --- fetch helper: curl or wget -------------------------------------------
# Redirects may only go to https, in every mode. wget is only the fallback for
# hosts without curl; it gets --https-only where this wget has it (outside
# test mode, where http://127.0.0.1 is allowed).
fetch() { # fetch <url> <outfile>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto "=$CURL_PROTO" --proto-redir =https -m 300 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        if [ "$WAF_MKE_TEST_MODE" != 1 ] && wget --help 2>&1 | grep -q -e '--https-only'; then
            wget -q --https-only -T 60 -O "$2" "$1"
        else
            wget -q -T 60 -O "$2" "$1"
        fi
    else
        fail "need curl or wget to download waf-mke"
    fi
}

# --- resolve the version ----------------------------------------------------
# releases_table prints one line per release, newest first: "<tag> <prerelease> <draft>"
releases_table() {
    awk '
    { all = all $0 "\n" }
    END {
        n = length(all); depth = 0; instr = 0; esc = 0; tok = ""; expect = 0
        for (i = 1; i <= n; i++) {
            c = substr(all, i, 1)
            if (instr) {
                if (esc) { esc = 0; buf = buf c }
                else if (c == "\\") esc = 1
                else if (c == "\"") {
                    instr = 0
                    if (depth == 2) {
                        if (expect) { if (key == "tag_name") tag = buf; expect = 0 }
                        else key = buf
                    }
                } else buf = buf c
                continue
            }
            if (c == "\"") { instr = 1; buf = ""; continue }
            if (c == "{" || c == "[") {
                depth++; expect = 0
                if (c == "{" && depth == 2) { tag = ""; pre = ""; dr = ""; key = "" }
                continue
            }
            if (c == "}" || c == "]") {
                if (depth == 2 && tok != "") { if (key == "prerelease") pre = tok; if (key == "draft") dr = tok; tok = ""; expect = 0 }
                if (c == "}" && depth == 2 && tag != "") print tag, (pre == "" ? "false" : pre), (dr == "" ? "false" : dr)
                depth--; continue
            }
            if (depth == 2) {
                if (c == ":") { expect = 1; continue }
                if (expect && c ~ /[A-Za-z0-9.+-]/) { tok = tok c; continue }
                if (tok != "") { if (key == "prerelease") pre = tok; if (key == "draft") dr = tok; tok = ""; expect = 0 }
            }
        }
    }' "$1"
}

case "$WAF_MKE_VERSION" in
    v[0-9]*) TAG=$WAF_MKE_VERSION ;;
    latest)
        api="$WAF_MKE_API_URL?per_page=30"
        fetch "$api" "$WORK/releases.json" 2>/dev/null || fail "cannot reach $api (is this host online?)"
        releases_table "$WORK/releases.json" > "$WORK/releases.tsv"
        if [ "$WAF_MKE_PRE" = "1" ]; then
            TAG=$(awk '$3 != "true" { print $1; exit }' "$WORK/releases.tsv")
        else
            TAG=$(awk '$3 != "true" && $2 != "true" { print $1; exit }' "$WORK/releases.tsv")
        fi
        if [ -z "$TAG" ]; then
            newest_pre=$(awk '$3 != "true" && $2 == "true" { print $1; exit }' "$WORK/releases.tsv")
            if [ -n "$newest_pre" ]; then
                fail "no stable release yet; the newest pre-release is $newest_pre. Install it with WAF_MKE_PRE=1 (newest including pre-releases) or WAF_MKE_VERSION=$newest_pre"
            fi
            fail "could not find any release in $api"
        fi
        ;;
    *) fail "WAF_MKE_VERSION must be 'latest' or a tag like v0.4.0-rc.13 (got '$WAF_MKE_VERSION')" ;;
esac
# Allowlist (WAF_MKE_VERSION and tags read from the API alike): vX.Y.Z with an
# optional -suffix of [0-9A-Za-z.-], never '..'. The case also removes any
# newline, which grep would take as several lines.
case "$TAG" in
    v*[!A-Za-z0-9.-]*|*..*) fail "refusing the odd release tag '$TAG'" ;;
esac
printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
    || fail "refusing the odd release tag '$TAG' (expected vX.Y.Z or vX.Y.Z-suffix)"

case "$WAF_MKE_SETUP" in
    auto|skip) ;;
    *) fail "WAF_MKE_SETUP must be 'skip' or unset (got '$WAF_MKE_SETUP'); nothing was changed" ;;
esac

# --- arch -------------------------------------------------------------------
case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "unsupported architecture: $(uname -m) (waf-mke ships amd64 and arm64)" ;;
esac
[ "$(uname -s)" = "Linux" ] || fail "only Linux is supported (got $(uname -s))"

TARBALL="waf-mke_${TAG#v}_linux_${ARCH}.tar.gz"
BASE="$WAF_MKE_DOWNLOAD_URL/$TAG"

# --- download, verify the signature, then the checksum -----------------------
say "bootstrap: downloading release $TAG"
fetch "$BASE/checksums.txt" "$WORK/checksums.txt" || fail "cannot download $BASE/checksums.txt"
fetch "$BASE/checksums.txt.sig" "$WORK/checksums.txt.sig" || fail "cannot download $BASE/checksums.txt.sig (is release $TAG signed?); refusing to install"

command -v openssl >/dev/null 2>&1 \
    || fail "openssl is required to verify the release signature and was not found; install openssl 3 and rerun (nothing was changed)"
openssl pkeyutl -help 2>&1 | grep -q -e '-rawin' \
    || fail "this openssl ($(openssl version 2>&1)) cannot verify Ed25519 signatures (needs OpenSSL 3, pkeyutl -rawin); upgrade openssl and rerun (nothing was changed)"

if [ -n "$WAF_MKE_PUBKEY_FILE" ]; then
    PUBKEY=$WAF_MKE_PUBKEY_FILE   # tests only
else
    PUBKEY=$WORK/release-signing.pub.pem
    # Identical to deploy/release-signing.pub.pem and to the key built into
    # waf-mke (scripts/bootstrap_test.sh and a Go test check both).
    cat > "$PUBKEY" <<'PEM'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAAYrUYhwLwqgoIb3P5TEZJr6N0dehgm/kI94i/ZbGRUg=
-----END PUBLIC KEY-----
PEM
fi

openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin -in "$WORK/checksums.txt" -sigfile "$WORK/checksums.txt.sig" >/dev/null 2>&1 \
    || fail "the signature of checksums.txt does NOT verify against the pinned release key; refusing to install (nothing was extracted or run)"
say "bootstrap: signature of checksums.txt verified"

say "bootstrap: downloading $TARBALL"
fetch "$BASE/$TARBALL" "$WORK/$TARBALL" || fail "cannot download $BASE/$TARBALL"

grep " $TARBALL\$" "$WORK/checksums.txt" | (cd "$WORK" && sha256sum -c -) \
    || fail "sha256 mismatch for $TARBALL (or it is not listed in the signed checksums.txt): the download is corrupt or was tampered with; refusing to install"

tar -C "$WORK" -xzf "$WORK/$TARBALL"
BIN="$WORK/${TARBALL%.tar.gz}/waf-mke"
[ -x "$BIN" ] || fail "the tarball did not contain an executable waf-mke"

# --- hand the verified bytes to root ------------------------------------------
# The temp dir belongs to the invoking user, who could swap the file between
# verification and `sudo` running it. So when not root, the verified binary is
# copied into a root-owned private dir, re-hashed there as root and compared
# with the hash taken right after the tarball was verified and extracted; only
# that copy is ever run. As root the temp dir is root-owned already.
VERIFIED_SHA=$(sha256sum "$BIN" | awk '{ print $1 }')
if [ "$(id -u)" = "0" ]; then
    RUNBIN=$BIN
    run_root() { "$@"; }
else
    say "bootstrap: needs root; asking for sudo (the download above never ran as root)"
    run_root() { sudo "$@"; }
    ROOTDIR=$(sudo mktemp -d /tmp/waf-mke-bootstrap-root.XXXXXX) || fail "cannot create a root-owned directory with sudo"
    sudo install -m 0700 "$BIN" "$ROOTDIR/waf-mke" || fail "cannot copy the binary into the root-owned directory"
    ROOT_SHA=$(sudo sha256sum "$ROOTDIR/waf-mke" | awk '{ print $1 }')
    if [ -z "$VERIFIED_SHA" ] || [ "$ROOT_SHA" != "$VERIFIED_SHA" ]; then
        fail "the binary changed after verification (sha256 $ROOT_SHA, verified $VERIFIED_SHA); refusing to run it as root (nothing was changed)"
    fi
    RUNBIN=$ROOTDIR/waf-mke
fi

# --- check the host, then install -------------------------------------------
say "bootstrap: checking this host with waf-mke doctor"
run_root "$RUNBIN" doctor || rc=$?
# doctor exits 1 on warnings (e.g. the missing service account, which install
# creates) and only 2 on real errors. Anything >= 2 stops here.
if [ "${rc:-0}" -ge 2 ]; then
    fail "doctor reported errors above; fix them before installing (nothing was changed)"
fi

say "bootstrap: running waf-mke install"
run_root "$RUNBIN" install

INSTALLED=/opt/waf-mke/bin/waf-mke

next_steps() {
    say
    say "bootstrap: next steps (nothing was enabled or started):"
    say "  1. sudo $INSTALLED setup        (guided: config, databases, first admin, start)"
    say "     or by hand: edit /opt/waf-mke/config.yaml, then"
    say "       sudo $INSTALLED validate -config /opt/waf-mke/config.yaml"
    say "       sudo systemctl enable --now waf-mke"
    say "  upgrade later with: sudo $INSTALLED upgrade <new-binary>"
}

# --- hand over to the guided setup (D5) -------------------------------------
# Under `curl | sh` stdin is the pipe, so the questions are read from the
# controlling terminal. Without one (CI, cron, ssh -T) nothing is asked: the
# next step is printed instead. WAF_MKE_SETUP=skip turns the hand-over off.
has_terminal() { [ -t 1 ] && ( : </dev/tty ) 2>/dev/null; }

if [ "$WAF_MKE_SETUP" = "skip" ]; then
    say "bootstrap: WAF_MKE_SETUP=skip, not running setup"
    next_steps
    exit 0
fi

if ! has_terminal; then
    say "bootstrap: no terminal available, not running setup"
    next_steps
    exit 0
fi

say
say "bootstrap: starting waf-mke setup (Ctrl-C to stop; WAF_MKE_SETUP=skip avoids this)"
rc=0
if [ "$(id -u)" = "0" ]; then
    "$INSTALLED" setup </dev/tty || rc=$?
else
    # The redirect is meant to be opened by this shell, not by sudo.
    # shellcheck disable=SC2024
    sudo "$INSTALLED" setup </dev/tty || rc=$?
fi
if [ "$rc" -ne 0 ]; then
    say "bootstrap: setup exited with code $rc; install is in place, rerun with: sudo $INSTALLED setup" >&2
    exit "$rc"
fi
