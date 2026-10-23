#!/bin/bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

: "${DEVELOPER_DIR:=/Library/Developer/CommandLineTools}"
: "${SDKROOT:=$DEVELOPER_DIR/SDKs/MacOSX26.sdk}"
export DEVELOPER_DIR SDKROOT
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
install_root="${SOPRANO_WEB_INSTALL_DIR:-/Applications}"

if [[ "$install_root" != /* || "$install_root" == "/" ]]; then
    echo "SOPRANO_WEB_INSTALL_DIR must be an absolute directory other than /." >&2
    exit 2
fi

echo "Building Soprano Web for release..."
"$script_dir/build-with-guard.sh" release

installed_app="$install_root/Soprano Web.app"
"$script_dir/package-app.sh" \
    release \
    "$installed_app" \
    "com.soprano.web" \
    "Soprano Web"

echo "Installed Soprano Web at $installed_app"
echo "The running app was not restarted; the update takes effect on its next launch."
