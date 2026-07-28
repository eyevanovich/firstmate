#!/usr/bin/env bash
# fm-marker-lib.sh - compatibility entry point for from-firstmate routing.
#
# bin/fm-operational-input.sh owns current operational-input construction,
# parsing, marker bytes, and narrow legacy compatibility. Existing callers
# source this path so they do not need a separate migration. No side effects on
# source; set -u and set -e safe.

_FM_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-operational-input.sh
. "$_FM_MARKER_LIB_DIR/fm-operational-input.sh"
unset _FM_MARKER_LIB_DIR
