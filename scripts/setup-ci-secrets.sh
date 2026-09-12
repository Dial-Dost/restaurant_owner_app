#!/usr/bin/env bash
#
# Put the Android signing material into this repo's GitHub Actions secrets, so
# the `Release clients` workflow can sign an APK the phones in the field will
# actually accept as an update.
#
# RUN THIS YOURSELF. It reads your local keystore and key.properties and hands
# them to `gh secret set`. Nothing is printed, nothing is copied through a
# terminal, and nothing leaves this machine except an encrypted value going to
# your own repository.
#
# WHY A SCRIPT RATHER THAN THE DOCUMENTED COPY-PASTE. docs/RELEASE.md walks
# through producing the base64 by hand and pasting it into the GitHub UI. That
# works, and it is also where the one failure this cannot self-diagnose comes
# from: a base64 blob truncated on the way through a terminal or a text box
# produces a keystore that decodes to garbage, and the failure surfaces much
# later as an unhelpful Gradle error. The workflow guards the obvious case by
# rejecting a decode under 512 bytes; not pasting at all is better.
#
# WHAT THIS DOES NOT DO: change the signing key. If this repo has ever published
# an APK, the key below MUST be the same one it was signed with. Android refuses
# an update whose signing certificate changed, and the only remedy for a user is
# to uninstall — losing local state. Verify the fingerprint before you run this
# (see docs/RELEASE.md, "Confirm the pinned signing fingerprint").
#
# Usage:   bash scripts/setup-ci-secrets.sh
set -euo pipefail

# Repo root, whichever directory this was invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

KEYSTORE="android/app/upload-keystore.jks"
PROPS="android/key.properties"

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || fail "the GitHub CLI (gh) is not installed."
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"

[ -f "$KEYSTORE" ] || fail "$KEYSTORE not found. It is gitignored on purpose — copy it in from wherever you keep it."
[ -f "$PROPS" ]    || fail "$PROPS not found. Copy android/key.properties.example and fill it in."

# base64 -w0 is GNU; macOS needs -i. Normalise to one line, because a newline
# inside the secret becomes a newline inside the decoded file.
#
# THE MACOS BRANCH USED TO PASS THE PATH POSITIONALLY and failed on the only
# platform it existed for: macOS base64 rejects a bare file argument with
# "invalid argument <file>" and prints its usage, so the script died before
# setting a single secret. Both branches now name the input the way their own
# implementation expects. Detection reads the usage text rather than uname,
# since the distinction that matters is GNU-vs-BSD coreutils, not the OS.
if base64 --help 2>&1 | grep -q -- "-w"; then
	B64="$(base64 -w0 "$KEYSTORE")"
else
	B64="$(base64 -i "$KEYSTORE" | tr -d '\n')"
fi

# Read the passwords out of key.properties rather than prompting: they are
# already on this disk, and prompting would put them in shell history.
prop() {
	local key="$1" value
	value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$PROPS" | head -n1 | cut -d= -f2- || true)"
	# Trim surrounding whitespace and CR (this file is often edited on Windows).
	value="${value%$'\r'}"
	value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
	printf '%s' "$value"
}

STORE_PASSWORD="$(prop storePassword)"
KEY_PASSWORD="$(prop keyPassword)"
KEY_ALIAS="$(prop keyAlias)"

[ -n "$STORE_PASSWORD" ] || fail "storePassword is missing or empty in $PROPS"
[ -n "$KEY_PASSWORD" ]   || fail "keyPassword is missing or empty in $PROPS"
[ -n "$KEY_ALIAS" ]      || fail "keyAlias is missing or empty in $PROPS"

# Sanity, without revealing anything: base64 runs about 4/3 the file size.
raw_size=$(wc -c < "$KEYSTORE" | tr -d ' ')
b64_size=${#B64}
[ "$b64_size" -gt 512 ] || fail "the encoded keystore is only ${b64_size} chars — that is not a real keystore."
echo "keystore ${raw_size} bytes -> ${b64_size} base64 chars"
echo "alias    ${KEY_ALIAS}"
echo

# The value arrives on STDIN and is never an argument, so it never appears in the
# process list where `ps` would show it to every user on the machine. That was
# always the intent; the mechanism was wrong.
#
# `--body-file` IS NOT A FLAG on `gh secret set` — it was rejected outright, and
# gh printed its usage instead of storing anything. The documented behaviour is
# simpler than the flag we were reaching for: with `--body` omitted, gh reads the
# value from standard input on its own. Same secrecy property, one fewer flag.
set_secret() {
	printf '%s' "$2" | gh secret set "$1" >/dev/null
	echo "  set $1"
}

echo "Setting repository secrets:"
set_secret ANDROID_KEYSTORE_BASE64   "$B64"
set_secret ANDROID_KEYSTORE_PASSWORD "$STORE_PASSWORD"
set_secret ANDROID_KEY_PASSWORD      "$KEY_PASSWORD"
set_secret ANDROID_KEY_ALIAS         "$KEY_ALIAS"

echo
echo "Done. Confirm with:  gh secret list"
echo
echo "The secrets are set, but nothing has been PROVEN yet. The only real proof"
echo "the signing is right is installing a CI-built APK OVER an existing install:"
echo "a wrong key installs perfectly on a clean device and is refused by every"
echo "phone that already has the app. docs/RELEASE.md has that procedure."
