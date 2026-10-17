#!/bin/bash
# Rebuilds the committed src/main/jniLibs bridge, like iOS's XCFramework; Gradle builds need no Rust.
# Needs cargo-ndk, rustup targets aarch64-linux-android and x86_64-linux-android, and the NDK below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
CRATE_DIR="${REPO_ROOT}/native/deepfilter-bridge"
OUTPUT="${MODULE_DIR}/src/main/jniLibs"
LIB_NAME="libdeepfilter_bridge.so"

NDK_VERSION="29.0.14206865"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${HOME}/Library/Android/sdk/ndk/${NDK_VERSION}}"
# Keeps Android build output out of the crate's own target directory.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${MODULE_DIR}/build/deepfilter-cargo}"
# Android 15+ devices may use 16 KB pages; 4 KB-aligned segments fail to load there.
# The soname lets the JNI shim link with -l and record a relative NEEDED entry.
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-soname,${LIB_NAME}"

case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  Linux) HOST_TAG="linux-x86_64" ;;
  *) echo "Unsupported host $(uname -s)" >&2; exit 1 ;;
esac
STRIP="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}/bin/llvm-strip"
READELF="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}/bin/llvm-readelf"

cd "${CRATE_DIR}"
echo "==> Building ${LIB_NAME} for arm64-v8a and x86_64"
# --locked: the pinned tract version is what upstream's source compiles against.
cargo ndk -t arm64-v8a -t x86_64 --platform 26 -o "${OUTPUT}" build --release --locked

for abi in arm64-v8a x86_64; do
  # cargo-ndk also copies upstream's own dylib; the bridge links it statically.
  find "${OUTPUT}/${abi}" -name 'libdf-*.so' -delete
  lib="${OUTPUT}/${abi}/${LIB_NAME}"
  "${STRIP}" --strip-unneeded "${lib}"
  echo "==> ${abi}: $(du -h "${lib}" | cut -f1)"
  "${READELF}" -d "${lib}" | grep NEEDED || true
  "${READELF}" -d "${lib}" | grep SONAME || true
  "${READELF}" -l "${lib}" | grep LOAD | head -n 1 || true
done
