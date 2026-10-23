#!/bin/bash
set -euo pipefail

# Builds Soprano Web and refuses to continue when a WebKit delegate method has
# a "nearly matching" Swift signature. Those methods compile but WebKit never
# calls them, so packaging such a build produces silently broken dialogs.
#
# Usage: scripts/build-with-guard.sh [debug|release]

configuration="${1:-debug}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 2
fi

: "${DEVELOPER_DIR:=/Library/Developer/CommandLineTools}"
: "${SDKROOT:=$DEVELOPER_DIR/SDKs/MacOSX26.sdk}"
export DEVELOPER_DIR SDKROOT
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

log="$(mktemp "${TMPDIR:-/tmp}/soprano-web-build.XXXXXX")"
cleanup() { rm -f "$log"; }
trap cleanup EXIT

if [[ "$configuration" == "release" ]]; then
    if ! swift build -c release 2>&1 | tee "$log"; then
        echo "Release build failed." >&2
        exit 1
    fi
else
    if ! swift build 2>&1 | tee "$log"; then
        echo "Debug build failed." >&2
        exit 1
    fi
fi

if grep -q "nearly matches optional requirement" "$log"; then
    echo "Refusing to package: a WebKit delegate method has a non-matching signature." >&2
    grep -A6 "nearly matches optional requirement" "$log" >&2
    exit 1
fi
