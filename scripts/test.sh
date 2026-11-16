#!/bin/sh
# Run the unit tests.
# With only the Command Line Tools installed, `swift test` doesn't pass the Swift Testing
# macro plugin to the compiler, so point it there explicitly.
set -e
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
