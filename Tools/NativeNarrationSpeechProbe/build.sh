#!/bin/zsh
set -euo pipefail
root="$(dirname "$0")/../.."
out="$root/build/native-narration-probe"
mkdir -p "$out"
xcrun swiftc -O -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx15.0 -module-cache-path "$out/ModuleCache" \
  "$root/OshoDiscourses/Services/TranslatedNarration.swift" \
  "$root/OshoDiscourses/Services/NativeNarrationSpeechRenderer.swift" \
  "$root/Tools/NativeNarrationSpeechProbe/main.swift" \
  -o "$out/NativeNarrationSpeechProbe"
