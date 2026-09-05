#!/bin/bash
# Build UnikeyAI.app: the original x-unikey engine (src/ukengine,
# src/ukinterface, src/vnconv, src/byteio) compiled unmodified, plus the
# new macOS front-end in macos/main.mm.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src"
BUILD="$HERE/build"
OBJ="$BUILD/obj"
APP="$HERE/UnikeyAI.app"

rm -rf "$BUILD" "$APP"
mkdir -p "$OBJ" "$APP/Contents/MacOS"

CXXFLAGS="-std=c++14 -O2 -Wno-c++11-narrowing"
INCLUDES="-I$SRC/byteio -I$SRC/vnconv -I$SRC/ukengine -I$SRC/ukinterface"

# --- 1. Compile the original, unmodified engine sources -------------------
CORE_SOURCES=(
  byteio/byteio.cpp
  byteio/prehdr.cpp
  vnconv/charset.cpp
  vnconv/convert.cpp
  vnconv/data.cpp
  vnconv/error.cpp
  vnconv/pattern.cpp
  vnconv/stdafx.cpp
  ukengine/ukengine.cpp
  ukengine/mactab.cpp
  ukengine/inputproc.cpp
  ukengine/usrkeymap.cpp
  ukengine/stdafx.cpp
  ukinterface/unikey.cpp
)

OBJECTS=()
for rel in "${CORE_SOURCES[@]}"; do
  # keep sources with the same basename (two stdafx.cpp) from colliding
  outname="$(echo "$rel" | tr '/' '_' | sed 's/\.cpp$/.o/')"
  out="$OBJ/$outname"
  echo "CXX  $rel"
  clang++ $CXXFLAGS $INCLUDES -c "$SRC/$rel" -o "$out"
  OBJECTS+=("$out")
done

echo "AR   libukcore.a"
ar rcs "$BUILD/libukcore.a" "${OBJECTS[@]}"

# --- 2. Compile the macOS front-end and link everything --------------------
# Set UNIKEYAI_DEBUG_LOG=1 in the environment to build with verbose per-
# keystroke NSLog output (see main.mm) - useful for diagnosing input issues
# in tricky fields like Spotlight's; leave unset for normal/release builds.
echo "OBJC main.mm${UNIKEYAI_DEBUG_LOG:+ (debug logging ON)}"
clang++ $CXXFLAGS -fobjc-arc $INCLUDES -DUNIKEYAI_DEBUG_LOG=${UNIKEYAI_DEBUG_LOG:-0} \
  -c "$HERE/main.mm" -o "$OBJ/main.o"

echo "LINK UnikeyAI"
clang++ -std=c++14 -fobjc-arc \
  "$OBJ/main.o" "$BUILD/libukcore.a" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement \
  -o "$APP/Contents/MacOS/UnikeyAI"

# --- 3. Generate the app icon (red/gold, drawn at build time - see gen_icon.mm)
echo "ICON AppIcon.icns"
mkdir -p "$APP/Contents/Resources"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
clang++ $CXXFLAGS -fobjc-arc -framework Cocoa "$HERE/gen_icon.mm" -o "$BUILD/gen_icon"
"$BUILD/gen_icon" "$BUILD/AppIcon-1024.png"
for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" "64 icon_32x32@2x.png" \
            "128 icon_128x128.png" "256 icon_128x128@2x.png" "256 icon_256x256.png" \
            "512 icon_256x256@2x.png" "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  set -- $spec
  sips -z "$1" "$1" "$BUILD/AppIcon-1024.png" --out "$ICONSET/$2" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# --- 4. Assemble the .app bundle -------------------------------------------
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer the stable local dev certificate (see macos/README.md) so that
# Accessibility/Input Monitoring permission survives rebuilds - ad-hoc
# signing (-s -) gets a brand new identity every build, which macOS treats
# as "a different app" and wipes previously granted TCC permissions.
SIGN_IDENTITY="VietTypeMacLocalDev"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "SIGN (ad-hoc - no '$SIGN_IDENTITY' certificate found, see macos/README.md to create one)"
  SIGN_IDENTITY="-"
else
  echo "SIGN ($SIGN_IDENTITY)"
fi
codesign --force --deep -s "$SIGN_IDENTITY" "$APP"

echo
echo "Built: $APP"
echo "Run:   open '$APP'"
echo "(On first launch, macOS will ask for Accessibility / Input Monitoring permission --"
echo " grant it in System Settings, then quit and reopen the app.)"
