#!/bin/zsh
set -euo pipefail
root="$(dirname "$0")/../.."
out="$root/build/native-narration-probe"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
macros="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
mkdir -p "$out"
flags=(-O -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors
       -target arm64-apple-macosx15.0 -module-cache-path "$out/ModuleCache")
xcrun swiftc "${flags[@]}" -emit-library -emit-module -enable-testing -module-name OshoDiscourses \
  -emit-module-path "$out/OshoDiscourses.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/libOshoDiscourses.dylib \
  "$root/OshoDiscourses/Services/TranslatedNarration.swift" \
  "$root/OshoDiscourses/Services/NativeNarrationSpeechRenderer.swift" \
  -o "$out/libOshoDiscourses.dylib"
xcrun swiftc "${flags[@]}" -I "$out" -L "$out" -lOshoDiscourses -F "$frameworks" -framework Testing \
  -load-plugin-library "$macros" \
  -Xlinker -rpath -Xlinker @executable_path -Xlinker -rpath -Xlinker "$frameworks" \
  "$root/OshoDiscoursesTests/NativeNarrationSpeechRendererTests.swift" \
  "$root/Tools/NativeNarrationSpeechProbe/TestMain.swift" -o "$out/NativeNarrationSpeechTests"
"$out/NativeNarrationSpeechTests" "$@"
