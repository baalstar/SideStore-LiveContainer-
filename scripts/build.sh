#!/bin/bash
# Builds LiveContainer+SideStore.ipa from the sources here. Needs macOS, Xcode,
# rustup, and: brew install ldid xcbeautify
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SS="$ROOT/SideStore"
LC="$ROOT/LiveContainer"

# Everything is logged; on exit, success or not, dist/diagnostics.zip is written.
LOGS="$ROOT/dist/logs"
rm -rf "$LOGS" "$ROOT/dist/diagnostics.zip" && mkdir -p "$LOGS"
rm -f "$SS/build/logs/build.log"
export RUST_BACKTRACE=1
exec 3>&1 4>&2
exec > >(tee "$LOGS/full.log") 2>&1
TEE_PID=$!
STEP=start
step() { STEP="$1"; echo; echo "=== STEP: $1 ($(date -u +%H:%M:%SZ)) ==="; }
finish() {
  code=$?
  set +e
  echo "=== EXIT code=$code step=$STEP ==="
  exec 1>&3 2>&4
  wait "$TEE_PID" 2>/dev/null
  python3 "$ROOT/scripts/collect_logs.py" "$ROOT" "$code" "$STEP"
  exit "$code"
}
trap finish EXIT

step environment
for c in "sw_vers" "uname -a" "xcodebuild -version" "xcrun --sdk iphoneos --show-sdk-version" \
         "swift --version" "cargo --version" "rustc --version" "python3 --version" \
         "command -v ldid" "command -v xcbeautify" "df -h ."; do
  echo "\$ $c"; $c || echo "(unavailable)"
done

fetch() { # url dir [commit]
  if [ -z "$(ls -A "$2" 2>/dev/null)" ]; then
    git clone --recursive "$1" "$2"
    if [ -n "${3:-}" ]; then
      git -C "$2" checkout -q "$3"
      git -C "$2" submodule update --init --recursive
    fi
  fi
  echo "dependency $2 at $(git -C "$2" log -1 --format='%H %cd' 2>/dev/null || echo unknown)"
}
step dependencies
# The uploaded archives had empty submodule folders.
fetch https://github.com/SideStore/SideSign "$SS/Dependencies/SideSign" 752d1ef602aa792a432ffa1e71646dc1ecf7363c
fetch https://github.com/SideStore/minimuxer "$SS/Dependencies/minimuxer"   # develop, not pinned
fetch https://github.com/LiveContainer/fishhook "$LC/fishhook"
fetch https://github.com/LiveContainer/litehook "$LC/litehook"

step sidesign-patch
P="$ROOT/patches/sidesign-macosx-client-info.patch"
if ! git -C "$SS/Dependencies/SideSign" apply --reverse --check "$P" 2>/dev/null; then
  git -C "$SS/Dependencies/SideSign" apply "$P"
fi

step rust-core
rustup target add aarch64-apple-ios
CORE="$SS/Dependencies/sisign"
(cd "$CORE" && IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --release --target aarch64-apple-ios)
step rust-export
# Export only si_* so bundled C/Rust code can't clash with SideStore's libraries.
mkdir -p "$CORE/dist" && rm -f "$CORE/dist/libsisign.a"
LIB="$CORE/target/aarch64-apple-ios/release/libsideinstaller_ffi.a"
nm -gjU "$LIB" | grep '^_si_' | sort -u > "$CORE/dist/exports.txt"
test -s "$CORE/dist/exports.txt"
xcrun --sdk iphoneos ld -r -arch arm64 -platform_version ios 15.0 15.0 -all_load \
  -exported_symbols_list "$CORE/dist/exports.txt" "$LIB" -o "$CORE/dist/sisign.o"
xcrun libtool -static -o "$CORE/dist/libsisign.a" "$CORE/dist/sisign.o"

step sidestore
(cd "$SS" && python3 scripts/ci/workflow.py build)
test -f "$SS/SideStore.ipa"

step livecontainer
cd "$LC"
[ -d Dependencies/OpenSSL.xcframework ] || sh .github/prepare_dependencies.sh
rm -rf archive.xcarchive Payload tmp LiveContainer.ipa LiveContainer+SideStore.ipa
xcodebuild archive -archivePath archive -scheme LiveContainer -project LiveContainer.xcodeproj \
  -sdk iphoneos -arch arm64 -configuration Release
step package
scheme=LiveContainer archive_path=archive SIDESTORE_IPA="$SS/SideStore.ipa" sh -x .github/build_github.sh
test -f "LiveContainer+SideStore.ipa"
mkdir -p "$ROOT/dist" && cp "LiveContainer+SideStore.ipa" "$ROOT/dist/"
