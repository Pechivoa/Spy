#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
TARGET="${1:-./build/Spy.app}"
swift build -c release
swiftc Icon.swift Sources/SpiderGlyph.swift -o .build/SpyIconGenerator
.build/SpyIconGenerator .build/Spy.iconset
iconutil -c icns -o Spy.icns .build/Spy.iconset
mkdir -p "$TARGET/Contents/MacOS" "$TARGET/Contents/Resources"
cp .build/release/Spy "$TARGET/Contents/MacOS/Spy"
cp Info.plist "$TARGET/Contents/Info.plist"
if [[ -f Spy.icns ]]; then cp Spy.icns "$TARGET/Contents/Resources/Spy.icns"; fi
if [[ "${SPY_SIGNING_MODE:-persistent}" == "adhoc" ]]; then
    codesign --force --sign - --identifier local.spy.mac "$TARGET"
    print "Development ad hoc signature: privacy grants may need renewal after rebuilding."
else
    python3 sign-local.py "$TARGET"
fi
codesign --verify --deep --strict "$TARGET"
print "Built: $TARGET"
