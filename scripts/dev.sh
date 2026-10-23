#!/bin/bash
set -euo pipefail

launch_app=true
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--build-only]" >&2
    exit 2
fi
if [[ $# -eq 1 ]]; then
    if [[ "$1" != "--build-only" ]]; then
        echo "Usage: $0 [--build-only]" >&2
        exit 2
    fi
    launch_app=false
fi

: "${DEVELOPER_DIR:=/Library/Developer/CommandLineTools}"
: "${SDKROOT:=$DEVELOPER_DIR/SDKs/MacOSX26.sdk}"
export DEVELOPER_DIR SDKROOT
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

echo "Building Soprano Web Dev..."
"$script_dir/build-with-guard.sh" debug

dev_app="$repo_root/.build/debug/Soprano Web Dev.app"
"$script_dir/package-app.sh" \
    debug \
    "$dev_app" \
    "com.soprano.web.dev" \
    "Soprano Web Dev"

echo "Created Soprano Web Dev at $dev_app"

if [[ "$launch_app" == true ]]; then
    echo "Launching an isolated Soprano Web Dev instance..."
    open -n "$dev_app"
fi
