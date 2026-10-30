#!/bin/bash
# Build the complete Windows payload on Linux so the Windows machine only has to run Inno Setup.
#
# Produces:
#   dist/installer/BahaiResearch/            staged {app} layout (app/ + runtime/ + VERSION)
#   dist/BahaiResearch-win-payload-<ver>.zip upload this as a release asset
#
# The Windows side then runs: tools\release-windows.bat <version>
#
# Usage: tools/package-windows-payload.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(./gradlew -q properties 2>/dev/null | sed -n 's/^version: //p' | head -n 1)"
if [ -z "$VERSION" ]; then
  echo "ERROR: could not read the project version from build.gradle"
  exit 1
fi

WIN_JDK_CACHE="${WIN_JDK_CACHE:-$HOME/.cache/bahairesearch/win-jdk}"
WIN_JDK_VERSION="${WIN_JDK_VERSION:-21}"
MODULES="java.base,java.desktop,java.logging,java.net.http,java.sql,jdk.unsupported,jdk.crypto.ec,jdk.httpserver"

PAYLOAD="$ROOT/dist/installer/BahaiResearch"
ZIP="$ROOT/dist/BahaiResearch-win-payload-$VERSION.zip"

echo "Version: $VERSION"

# -- 1. Universal fat jar (Linux + Windows JavaFX natives) -----------------
echo "[1/5] Building fat jar with Windows JavaFX natives..."
./gradlew shadowJar -PbundleJavaFxPlatforms=win --console=plain

JAR="$ROOT/build/libs/BahaiResearch-$VERSION-all.jar"
if [ ! -f "$JAR" ]; then
  echo "ERROR: shadowJar did not produce $JAR"
  exit 1
fi

# -- 2. Windows JDK (cached) ----------------------------------------------
JMODS="$WIN_JDK_CACHE/jdk/jmods"
if [ ! -d "$JMODS" ]; then
  echo "[2/5] Downloading Windows JDK $WIN_JDK_VERSION (one time, cached in $WIN_JDK_CACHE)..."
  mkdir -p "$WIN_JDK_CACHE"
  curl -sSL -o "$WIN_JDK_CACHE/jdk.zip" \
    "https://api.adoptium.net/v3/binary/latest/$WIN_JDK_VERSION/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk"
  rm -rf "$WIN_JDK_CACHE/extract" "$WIN_JDK_CACHE/jdk"
  unzip -q "$WIN_JDK_CACHE/jdk.zip" -d "$WIN_JDK_CACHE/extract"
  mv "$(ls -d "$WIN_JDK_CACHE"/extract/jdk-* | head -n 1)" "$WIN_JDK_CACHE/jdk"
  rm -rf "$WIN_JDK_CACHE/extract" "$WIN_JDK_CACHE/jdk.zip"
fi
if [ ! -d "$JMODS" ]; then
  echo "ERROR: Windows jmods not found at $JMODS"
  exit 1
fi
echo "[2/5] Using Windows jmods: $JMODS"

# -- 3. Stage the {app} layout -------------------------------------------
echo "[3/5] Staging $PAYLOAD..."
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/app/data/corpus"

# Stable jar name keeps the Inno script free of version interpolation
cp "$JAR" "$PAYLOAD/app/BahaiResearch-all.jar"
cp "$ROOT/bahai-research.local-only.example.properties" "$PAYLOAD/app/bahai-research.properties"
cp -r "$ROOT/data/corpus/curated" "$PAYLOAD/app/data/corpus/"
sed -i \
  -e 's/^[[:space:]]*corpus\.autoIngestIfEmpty[[:space:]]*=.*/corpus.autoIngestIfEmpty=true/' \
  -e 's/^[[:space:]]*corpus\.curatedIngestEnabled[[:space:]]*=.*/corpus.curatedIngestEnabled=true/' \
  -e 's/^[[:space:]]*corpus\.forceReingest[[:space:]]*=.*/corpus.forceReingest=false/' \
  "$PAYLOAD/app/bahai-research.properties"

# -- 4. Cross-build the Windows runtime ----------------------------------
echo "[4/5] Building Windows runtime with jlink..."
jlink --module-path "$JMODS" \
      --add-modules "$MODULES" \
      --output "$PAYLOAD/runtime" \
      --strip-debug --no-man-pages --no-header-files --compress=2
if [ ! -f "$PAYLOAD/runtime/bin/javaw.exe" ]; then
  echo "ERROR: jlink did not produce runtime/bin/javaw.exe"
  exit 1
fi

printf '%s\n' "$VERSION" > "$PAYLOAD/VERSION"

# -- 5. Zip for the release asset ----------------------------------------
echo "[5/5] Packaging $ZIP..."
mkdir -p "$ROOT/dist"
rm -f "$ZIP"
if command -v zip >/dev/null 2>&1; then
  ( cd "$ROOT/dist/installer" && zip -qr "$ZIP" BahaiResearch )
else
  python3 -m zipfile -c "$ZIP" "$PAYLOAD"
fi

cat <<EOF

Done.
  Payload folder: $PAYLOAD
  Payload zip   : $ZIP
                  $(stat -c%s "$ZIP") bytes, modified $(date -r "$ZIP" '+%Y-%m-%d %H:%M')

Next: copy the zip to the Windows machine, then run release-windows.bat there.
It reads \$ROOT\\dist\\BahaiResearch-win-payload-$VERSION.zip and skips any download, so
the file just has to land in the project's dist\\ folder:

  cp "$ZIP" /media/   # VirtualBox shared folder; then move it on Windows
  # -> D:\\AI-Python\\BahaiResearch\\dist\\$(basename "$ZIP")

Then on Windows:
  cd D:\\AI-Python\\BahaiResearch
  git pull
  tools\\release-windows.bat $VERSION

The script echoes the zip's byte size and modification time, so it is easy to confirm the
copy matches the numbers printed above. Delete the zip to force a fresh download instead.

Alternatively, publish the payload as a release asset and let Windows fetch it:
  gh release upload v$VERSION "$ZIP" --clobber
EOF
