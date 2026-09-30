#!/bin/bash
# Assembles Jaaga.app from the Swift package's products.
#
# Jaaga is a plain SwiftPM package, so this script does the job an Xcode app target would: it puts the
# app executable, the daemon, the resource bundles, an Info.plist and the LaunchAgent plist into the
# layout macOS expects, then ad-hoc signs the result so SMAppService will consider registering it.
#
# Usage: Scripts/bundle-app.sh [--configuration debug|release] [--output DIR] [--version X.Y.Z]
set -euo pipefail

configuration=release
output=""
version="1.0.0"
build_number="${GITHUB_RUN_NUMBER:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) configuration="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --build) build_number="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's|^# \{0,1\}||'
      exit 0 ;;
    *) echo "bundle-app.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

echo "==> Building ($configuration)"
# One product per invocation: `swift build` honours only the last --product it is given, which would
# silently leave the other binary unbuilt.
swift build -c "$configuration" --product jaagad
swift build -c "$configuration" --product JaagaApp

products="$(swift build -c "$configuration" --show-bin-path)"
[[ -n "$output" ]] || output="$products"
app="$output/Jaaga.app"

echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"

cp "$products/JaagaApp" "$app/Contents/MacOS/JaagaApp"
cp "$products/jaagad" "$app/Contents/MacOS/jaagad"

sed -e "s|__VERSION__|$version|" -e "s|__BUILD__|$build_number|" \
  Support/Info.plist > "$app/Contents/Info.plist"
cp Support/com.jaaga.daemon.plist "$app/Contents/Library/LaunchAgents/com.jaaga.daemon.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# SwiftPM resource bundles (the usual-suspects catalog lives in one). They go in Contents/Resources
# only: codesign refuses a nested bundle inside Contents/MacOS. Both the app and the daemon resolve it
# from there, which `SuspectCatalog.bundled()` is written to do.
shopt -s nullglob
for bundle in "$products"/*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done
shopt -u nullglob

# SwiftPM names it "<package>_<target>.bundle", so match on the target rather than a fixed name.
if ! compgen -G "$app/Contents/Resources/*_JaagaCore.bundle" > /dev/null; then
  echo "bundle-app.sh: the JaagaCore resource bundle is missing; the daemon cannot classify" >&2
  echo "               usual suspects without it." >&2
  exit 1
fi

# Ad-hoc signature. Enough for SMAppService to register on the machine that built it; a Developer ID
# signature and notarization are what a distributable build needs, and are out of scope for now.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$app/Contents/MacOS/jaagad"
codesign --force --sign - --timestamp=none --deep "$app"
codesign --verify --deep --strict "$app"

echo "==> Built $app"
echo "    open \"$app\""
