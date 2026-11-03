#!/bin/bash
# Lancia i test. Con i soli Command Line Tools il framework Testing va indicato a mano.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
# Con i Command Line Tools 27 il plugin delle macro di Testing sta in una sottocartella che swift non cerca.
PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
EXTRA=()
[ -d "$PLUGIN" ] && EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN")
if [ -d "$DEV/Frameworks/Testing.framework" ]; then
  swift test ${EXTRA[@]+"${EXTRA[@]}"} -Xswiftc -F -Xswiftc "$DEV/Frameworks" -Xlinker -F -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
else
  swift test "$@"
fi
