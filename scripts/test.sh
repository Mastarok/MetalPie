#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./swiftpm-env.sh
source "${SCRIPT_DIR}/swiftpm-env.sh"

cd "${REPO_ROOT}"

# Ensure Swift Testing macro plugin (`libTestingMacros.dylib`) is always discovered under
# Swift 6.4 CommandLineTools even during incremental `swiftbuild` runs.
ACTIVE_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
TESTING_PLUGINS_DIR="${ACTIVE_DEV_DIR}/usr/lib/swift/host/plugins/testing"
if [ -d "${TESTING_PLUGINS_DIR}" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "${TESTING_PLUGINS_DIR}" "$@"
else
  exec swift test "$@"
fi
