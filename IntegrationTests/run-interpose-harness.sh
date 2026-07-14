#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
swift build -c release
bin="$(swift build -c release --show-bin-path)"
profile="$(mktemp -t shockemu-harness).se"
trap 'rm -f "$profile"' EXIT
printf '%s\n' 'space = X' > "$profile"
hash="$(/usr/bin/shasum -a 256 "$profile" | /usr/bin/awk '{print $1}')"

SHOCKEMU_PROFILE_PATH="$profile" \
SHOCKEMU_PROFILE_SHA256="$hash" \
SHOCKEMU_INPUT_SOURCE=local \
DYLD_INSERT_LIBRARIES="$bin/libShockEmuRuntime.dylib" \
"$bin/InterposeHarness"
