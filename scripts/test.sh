#!/bin/bash
# Stow test runner.
#
# Usage:
#   ./scripts/test.sh [unit|integration|ios|mac-ui|all]
#
# Defaults to `unit` if no subcommand is given. `all` chains every layer in
# order and short-circuits on the first failure.

set -e
cd "$(dirname "$0")/.."

cmd="${1:-unit}"

run_unit() {
    echo "▶ Unit tests (swift test)"
    swift test --parallel
}

run_integration() {
    echo "▶ Integration tests (CloudKit dev container)"
    if [ -z "${STOW_CK_CONTAINER:-}" ]; then
        echo "  → STOW_CK_CONTAINER not set; skipping integration suite."
        echo "    Set STOW_CK_CONTAINER=iCloud.<id> + STOW_CLOUDKIT_INTEGRATION=1 to run."
        return 0
    fi
    STOW_CLOUDKIT_INTEGRATION=1 swift test --filter StowIntegrationTests
}

run_ios() {
    echo "▶ iOS simulator scenarios"
    echo "  → builds the iOS app; full scenario scripts in docs/ios_scenarios.md"
    ./scripts/build-ios.sh > /dev/null
}

run_mac_ui() {
    echo "▶ macOS UI scenarios"
    echo "  → not yet wired (AppleScript scripts will land in a follow-up commit)"
    return 0
}

case "$cmd" in
    unit) run_unit ;;
    integration) run_integration ;;
    ios) run_ios ;;
    mac-ui) run_mac_ui ;;
    all)
        run_unit
        run_integration
        run_mac_ui
        run_ios
        ;;
    *)
        echo "Unknown subcommand: $cmd"
        echo "Usage: $0 [unit|integration|ios|mac-ui|all]"
        exit 1
        ;;
esac
