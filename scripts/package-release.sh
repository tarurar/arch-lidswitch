#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install-hyprland-lid-switch.sh"

usage() {
    echo "Usage: $0 DESTINATION" >&2
}

if (( $# != 1 )) || [[ -z "$1" ]]; then
    usage
    exit 2
fi

destination=$1
destination_created=false

cleanup() {
    local status=$?

    if (( status != 0 )) && [[ "$destination_created" == true ]]; then
        rm -rf -- "$destination"
    fi
    exit "$status"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build-installer.sh" --check

if ! mkdir -m 0755 -- "$destination"; then
    echo "Release destination must not already exist: $destination" >&2
    exit 1
fi
destination_created=true

install -m 0755 -- "$INSTALLER" \
    "$destination/install-hyprland-lid-switch.sh"
(
    cd "$destination"
    sha256sum -- install-hyprland-lid-switch.sh > SHA256SUMS
    chmod 0644 SHA256SUMS
    sha256sum --check --strict SHA256SUMS
)

destination_created=false
