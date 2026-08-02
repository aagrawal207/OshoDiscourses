#!/bin/bash
# Rebuild Vendor/DeepFilterBridge.xcframework from source.
#
# Only needed when changing the Rust bridge or bumping the pinned DeepFilterNet
# commit. Normal app builds just link the committed XCFramework and do not
# require a Rust toolchain.
#
# Upstream DeepFilterNet is pinned by commit in Cargo.toml, and every
# transitive crate version is pinned in Cargo.lock (upstream's loose
# `tract = ^0.21.4` constraint otherwise resolves to a release with breaking
# API changes that its own source does not compile against). Do not run
# `cargo update` without re-verifying the build.
#
# Requires: rustup, and the three iOS targets:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

set -euo pipefail

CRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CRATE_DIR}/../.." && pwd)"
OUTPUT="${REPO_ROOT}/Vendor/DeepFilterBridge.xcframework"
LIB_NAME="libdeepfilter_bridge.a"

# Must match `deploymentTarget.iOS` in project.yml. Without this, rustc and the
# `cc` crate (which assembles tract's hand-written NEON kernels) stamp the
# objects with the host SDK's version, and every one of them draws a linker
# warning about being built for a newer iOS than the app targets.
export IPHONEOS_DEPLOYMENT_TARGET=18.0

cd "${CRATE_DIR}"

# The simulator slice must be universal. Release builds do not restrict
# themselves to the active architecture, so an arm64-only simulator slice makes
# `xcodebuild -configuration Release` fail to link for x86_64.
DEVICE_TARGET=aarch64-apple-ios
SIM_TARGETS=(aarch64-apple-ios-sim x86_64-apple-ios)

for target in "${DEVICE_TARGET}" "${SIM_TARGETS[@]}"; do
  echo "==> Building ${target}"
  # --locked so a stale index cannot silently upgrade the pinned tract version.
  cargo build --release --locked --target "${target}"
done

echo "==> Creating universal simulator library"
SIM_UNIVERSAL="${CRATE_DIR}/target/universal-sim"
mkdir -p "${SIM_UNIVERSAL}"
lipo -create \
  "${CRATE_DIR}/target/aarch64-apple-ios-sim/release/${LIB_NAME}" \
  "${CRATE_DIR}/target/x86_64-apple-ios/release/${LIB_NAME}" \
  -output "${SIM_UNIVERSAL}/${LIB_NAME}"

echo "==> Packaging XCFramework"
rm -rf "${OUTPUT}"
mkdir -p "${REPO_ROOT}/Vendor"
xcodebuild -create-xcframework \
  -library "${CRATE_DIR}/target/${DEVICE_TARGET}/release/${LIB_NAME}" \
  -headers "${CRATE_DIR}/include" \
  -library "${SIM_UNIVERSAL}/${LIB_NAME}" \
  -headers "${CRATE_DIR}/include" \
  -output "${OUTPUT}"

echo "==> Built ${OUTPUT}"
lipo -info "${OUTPUT}"/*/"${LIB_NAME}"
