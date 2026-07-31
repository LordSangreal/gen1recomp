#!/usr/bin/env bash
# Packages the LÖVE2D Pokémon Red port into distributable macOS, Windows,
# and Linux builds. Runs entirely on macOS (no cross-compiling needed,
# the Windows and Linux builds reuse LÖVE's prebuilt win64 / AppImage
# binaries, fusing our game.love onto them the same way love.exe does).
#
# Usage: scripts/build.sh [mac|win|linux|android|ios|all|3ds|switch|wiiu|console]
#                          [--version X.Y.Z] [--identity "Developer ID Application: ..."]
#                          [--notary-profile NAME] [--no-notarize]
#                          [--release]   # ios only: release config instead of debug
#                          [--unpackaged] # console only: emit loose game files
#                                         # instead of fusing into the binary
#
# Output: dist/mac/gen1recomp-macos.zip
#         dist/win/gen1recomp-win64.zip
#         dist/linux/gen1recomp-linux.zip (fused x86_64 AppImage)
#         dist/android/debug/*.apk (full gradle output stays under
#           mobile/android/app/build/outputs/apk/embedNoRecord/)
#         dist/ios/<Config>-<sdk>/gen1recomp.app (full xcodebuild output stays
#           under mobile/ios/build/Build/Products/)
#         dist/console/sdcard/ (LÖVE Potion game folder, runs as-is)
#         dist/console/gen1recomp-<ver>-console-bundle.zip (for lovebrew.org)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$ROOT/.bazinga"
CACHE="$HERE/cache"
WORK="$HERE/work"
DIST="$ROOT/dist"
ENTITLEMENTS="$ROOT/scripts/macos-entitlements.plist"

APP_NAME="gen1recomp"
BUNDLE_ID="com.theboisclub.pokemonred"
LOVE_VERSION="11.5"
VERSION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
VERSION_EXPLICIT=false
IDENTITY=""
TARGET="all"
NOTARY_PROFILE="notary-profile"
NOTARIZE=true
IOS_RELEASE=false
# Console bundles ask for a single executable by default.  With packaged=false
# the bundler has nothing to build for a non-3DS target -- no executable, and no
# asset conversion outside the 3DS -- so it hands back the source unchanged,
# which is what dist/console/sdcard already is.
CONSOLE_PACKAGED=true

# Console targets requested, in bundler names (ctr / hac / cafe), deduped and
# kept in the order the user asked for them.
CONSOLE_LIST=""
add_console() {
  case " $CONSOLE_LIST " in
    *" $1 "*) ;;                                     # already requested
    *) CONSOLE_LIST="${CONSOLE_LIST:+$CONSOLE_LIST }$1" ;;
  esac
}

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    mac|win|linux|android|ios|all) TARGET="$1" ;;
    # Console targets accumulate instead of overwriting: one bundle can build
    # for several consoles at once, and each build_console run clears
    # dist/console, so `build.sh 3ds wiiu` as two separate runs would leave
    # only the Wii U output behind.
    3ds)     TARGET="console"; add_console ctr ;;
    switch)  TARGET="console"; add_console hac ;;
    wiiu)    TARGET="console"; add_console cafe ;;
    console) TARGET="console"; add_console ctr; add_console hac; add_console cafe ;;
    --version) VERSION="$2"; VERSION_EXPLICIT=true; shift ;;
    --identity) IDENTITY="$2"; shift ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift ;;
    --no-notarize) NOTARIZE=false ;;
    --release) IOS_RELEASE=true ;;
    --packaged) CONSOLE_PACKAGED=true ;;
    --unpackaged) CONSOLE_PACKAGED=false ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

mkdir -p "$CACHE" "$WORK" "$DIST/mac" "$DIST/win" "$DIST/linux"

# --------------------------------------------------------------- game.love
# tools/save-editor is part of the shipped app, not a dev-only script: the
# launcher's Edit button on a save row opens it in-process (main.lua), and
# `--editor` / POKEPORT_EDITOR=1 opens it standalone.  It is required through
# love.filesystem's require path, so it has to live inside the archive.
say "packing game.love"
LOVE_FILE="$WORK/game.love"
rm -f "$LOVE_FILE"
(cd "$ROOT" && zip -q -9 -r "$LOVE_FILE" \
  main.lua conf.lua src data assets tools/save-editor \
  tools/rom_manifest.json tools/rom_manifest_blue.json \
  tools/rom_manifest_yellow.json \
  -x '*.DS_Store' 'data/generated/*' 'assets/generated/*')
# List the archive once into a file, and grep that file rather than a pipe.
# `unzip -Z1 ... | grep -q ...` looks harmless but is a race under the
# `set -o pipefail` above: grep -q exits the instant it matches, unzip takes
# SIGPIPE on the next write, and pipefail then reports the whole pipeline as
# failed even though the match succeeded.  Every check below matches something
# in the last 20 of ~300 entries, so unzip is virtually always still writing --
# which turned every one of these guards into an unconditional "missing file"
# abort, on every target.
LOVE_LIST="$WORK/game.love.list"
unzip -Z1 "$LOVE_FILE" > "$LOVE_LIST"
if grep -Eq '^(data|assets)/generated/[^/]+|^(data|assets)/generated/.+/' "$LOVE_LIST"; then
  fail "game.love unexpectedly contains generated ROM data"
fi
# The editor is only reachable if its entry point and both module directories
# made it in, and every version's import manifest has to ship or that game's
# ROM import fails in the built app (dev reads them off the source tree, so
# the miss only ever shows up in a build -- the Yellow manifest shipped this
# way once).
for required in tools/save-editor/App.lua tools/save-editor/Kit.lua \
                tools/save-editor/panels/Party.lua \
                tools/rom_manifest.json tools/rom_manifest_blue.json \
                tools/rom_manifest_yellow.json; do
  grep -qx "$required" "$LOVE_LIST" \
    || fail "game.love is missing $required"
done
say "game.love: $(du -h "$LOVE_FILE" | cut -f1)"

# ------------------------------------------------------- stamp release version
# The working tree ships Version.lua with engine "0.0.0-dev"; the real release
# number only ever lives inside the packed archive. When --version is a strict
# X.Y.Z, patch a copy of Version.lua (engine set to that number) under a staging
# dir and replace the entry inside game.love in place -- never the source tree.
# Short-hash / "dev" builds are left with the "-dev" default so they cannot be
# mistaken for a release. The stamp is then read back out of the archive and the
# build fails if it did not take.
if printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  say "stamping engine version $VERSION into game.love"
  stamp_dir="$WORK/stamp"
  rm -rf "$stamp_dir"
  mkdir -p "$stamp_dir/src/core"
  sed -E "s/(engine[[:space:]]*=[[:space:]]*\")[^\"]*(\")/\1$VERSION\2/" \
    "$ROOT/src/core/Version.lua" > "$stamp_dir/src/core/Version.lua"
  (cd "$stamp_dir" && zip -q "$LOVE_FILE" src/core/Version.lua)
  version_re="$(printf '%s' "$VERSION" | sed 's/\./\\./g')"
  # Captured, not piped into grep -q, for the same SIGPIPE-under-pipefail
  # reason as the listing checks above.
  stamped="$(unzip -p "$LOVE_FILE" src/core/Version.lua)"
  printf '%s' "$stamped" \
    | grep -Eq "engine[[:space:]]*=[[:space:]]*\"$version_re\"" \
    || fail "version stamp failed: game.love does not report engine $VERSION"
  say "stamped engine version: $VERSION"
else
  say "version '$VERSION' is not X.Y.Z,  shipping default engine (no stamp)"
fi

# --------------------------------------------------------------- macOS
build_mac() {
  say "building macOS app"
  local love_app="${LOVE_APP:-/Applications/love.app}"
  [ -d "$love_app" ] || fail "LÖVE.app not found at $love_app (install it or set LOVE_APP=/path/to/love.app)"

  local out_app="$WORK/$APP_NAME.app"
  rm -rf "$out_app"
  cp -R "$love_app" "$out_app"

  # drop any bundled placeholder .love and fuse ours in
  find "$out_app/Contents/Resources" -maxdepth 1 -name '*.love' -delete
  cp "$LOVE_FILE" "$out_app/Contents/Resources/game.love"

  local plist="$out_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$plist"

  if [ -f "$ROOT/assets/icon.icns" ]; then
    cp "$ROOT/assets/icon.icns" "$out_app/Contents/Resources/GameIcon.icns"
  fi

  local id="$IDENTITY"
  if [ -z "$id" ]; then
    id="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/^[^"]*"(.*)"$/\1/' || true)"
  fi
  if [ -n "$id" ]; then
    say "codesigning with: $id"
    codesign --deep --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" --sign "$id" "$out_app"
    codesign --verify --deep --strict --verbose=2 "$out_app"
  else
    warn "no 'Developer ID Application' identity found,  shipping unsigned."
    warn "install your cert in Keychain Access, then re-run (or pass --identity \"Developer ID Application: Name (TEAMID)\")."
    warn "unsigned builds will be Gatekeeper-blocked on other Macs; notarize with 'xcrun notarytool submit' once signed."
    NOTARIZE=false
  fi

  if [ "$NOTARIZE" = true ]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
      warn "keychain profile '$NOTARY_PROFILE' not found/working,  skipping notarization."
      warn "set it up with: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id ... --team-id ... --password ..."
    else
      local notarize_zip="$WORK/$APP_NAME-notarize.zip"
      rm -f "$notarize_zip"
      (cd "$WORK" && ditto -c -k --keepParent "$APP_NAME.app" "$notarize_zip")
      say "submitting to Apple notary service (this can take a few minutes)"
      xcrun notarytool submit "$notarize_zip" --keychain-profile "$NOTARY_PROFILE" --wait
      say "stapling notarization ticket"
      xcrun stapler staple "$out_app"
      rm -f "$notarize_zip"
    fi
  fi

  local zip_out="$DIST/mac/$APP_NAME-macos.zip"
  rm -f "$zip_out"
  (cd "$WORK" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$zip_out")
  say "macOS build: $zip_out"
}

# --------------------------------------------------------------- Windows
build_win() {
  say "building Windows (win64) app"
  local zip_name="love-$LOVE_VERSION-win64.zip"
  local love_zip="$CACHE/$zip_name"
  # A cache hit only checks existence, not validity -- a prior run truncated
  # by a network drop mid-download (curl still leaves the partial file if
  # the exit code slips through) would otherwise be reused forever.
  if [ -f "$love_zip" ] && ! unzip -tqq "$love_zip" >/dev/null 2>&1; then
    warn "cached $zip_name is not a valid zip,  removing and re-downloading"
    rm -f "$love_zip"
  fi
  if [ ! -f "$love_zip" ]; then
    say "downloading LÖVE $LOVE_VERSION win64 binaries"
    curl -fL --progress-bar \
      "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$zip_name" \
      -o "$love_zip" || fail "download failed,  check LOVE_VERSION or your network"
    unzip -tqq "$love_zip" >/dev/null 2>&1 \
      || fail "downloaded $zip_name is not a valid zip (truncated download?)"
  fi

  local extract_dir="$WORK/love-win64"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  unzip -q "$love_zip" -d "$extract_dir"
  local love_dir
  love_dir="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"

  local out_dir="$WORK/$APP_NAME-win64"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  cp "$love_dir"/*.dll "$out_dir"/
  cp "$love_dir"/license.txt "$out_dir"/ 2>/dev/null || true

  cat "$love_dir/love.exe" "$LOVE_FILE" > "$out_dir/$APP_NAME.exe"

  local zip_out="$DIST/win/$APP_NAME-win64.zip"
  rm -f "$zip_out"
  (cd "$WORK" && zip -q -9 -r "$zip_out" "$APP_NAME-win64")
  say "Windows build: $zip_out"
}

# --------------------------------------------------------------- Linux
build_linux() {
  say "building Linux (x86_64 AppImage) app"
  local appimage_name="love-$LOVE_VERSION-x86_64.AppImage"
  local love_appimage="$CACHE/$appimage_name"
  # Same cache-validity gap as the win64 zip above: an AppImage is just an
  # ELF, so check the magic bytes before trusting a cached copy is complete.
  if [ -f "$love_appimage" ] && [ "$(head -c 4 "$love_appimage" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
    warn "cached $appimage_name is not a valid ELF binary,  removing and re-downloading"
    rm -f "$love_appimage"
  fi
  if [ ! -f "$love_appimage" ]; then
    say "downloading LÖVE $LOVE_VERSION Linux AppImage"
    curl -fL --progress-bar \
      "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$appimage_name" \
      -o "$love_appimage" || fail "download failed,  check LOVE_VERSION or your network"
    [ "$(head -c 4 "$love_appimage" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] \
      || fail "downloaded $appimage_name is not a valid ELF binary (truncated download?)"
  fi
  chmod +x "$love_appimage"

  # The Windows-style `cat love.exe game.love` fusion does NOT work here:
  # an AppImage is a small runtime ELF with a squashfs appended, and at
  # launch the runtime mounts the squashfs and executes bin/love from
  # *inside* it -- bytes appended to the outer file are never read, so
  # users would just get vanilla LÖVE's no-game screen. Instead, unpack
  # the squashfs, drop game.love in, point AppRun's FUSE_PATH hook at it
  # (the hook ships commented-out in LÖVE's official AppImage), and glue
  # runtime + repacked squashfs back together.
  command -v unsquashfs >/dev/null && command -v mksquashfs >/dev/null \
    || fail "squashfs tools not found; install with: brew install squashfs"

  # The squashfs starts right where the ELF ends:
  # e_shoff + e_shnum * e_shentsize (all little-endian in the ELF64 header).
  local e_shoff e_shentsize e_shnum sfs_offset
  e_shoff=$(od -An -j40 -N8 -tu8 "$love_appimage" | tr -d ' ')
  e_shentsize=$(od -An -j58 -N2 -tu2 "$love_appimage" | tr -d ' ')
  e_shnum=$(od -An -j60 -N2 -tu2 "$love_appimage" | tr -d ' ')
  sfs_offset=$((e_shoff + e_shentsize * e_shnum))
  [ "$(dd if="$love_appimage" bs=1 skip="$sfs_offset" count=4 2>/dev/null)" = "hsqs" ] \
    || fail "no squashfs superblock at computed offset $sfs_offset (unexpected AppImage layout)"

  local appdir="$WORK/linux-appdir"
  rm -rf "$appdir"
  unsquashfs -q -no-xattrs -o "$sfs_offset" -d "$appdir" "$love_appimage" >/dev/null

  cp "$LOVE_FILE" "$appdir/game.love"
  sed -i '' 's|^#FUSE_PATH="$APPDIR/my_game.love"$|FUSE_PATH="$APPDIR/game.love"|' "$appdir/AppRun"
  grep -q '^FUSE_PATH="\$APPDIR/game.love"$' "$appdir/AppRun" \
    || fail "failed to enable FUSE_PATH in AppRun (upstream AppRun changed?)"

  # Match the upstream image's compression (gzip, 128K blocks) so the
  # bundled runtime can read it.
  local sfs_out="$WORK/game.squashfs"
  rm -f "$sfs_out"
  mksquashfs "$appdir" "$sfs_out" \
    -comp gzip -b 131072 -noappend -all-root -no-xattrs -quiet >/dev/null

  local out_bin="$WORK/$APP_NAME-x86_64.AppImage"
  rm -f "$out_bin"
  head -c "$sfs_offset" "$love_appimage" > "$out_bin"
  cat "$sfs_out" >> "$out_bin"
  chmod +x "$out_bin"

  local zip_out="$DIST/linux/$APP_NAME-linux.zip"
  rm -f "$zip_out"
  (cd "$WORK" && zip -q -9 -j "$zip_out" "$(basename "$out_bin")")
  say "Linux build: $zip_out"
}

# ------------------------------------------------- Nintendo (LÖVE Potion)
# 3DS / Switch / Wii U, via LÖVE Potion (https://lovebrew.org).
#
# Nothing is compiled here, and nothing can be: LÖVE Potion ships prebuilt
# console binaries, and turning a game into a .3dsx/.nro/.wuhb is done by the
# lovebrew bundler, which is a hosted service (it shells out to devkitPro tools
# server-side).  There is no working local CLI for it.  The old `lovebrew`
# client still on the releases page posts to www.bundle.lovebrew.org/data:
# that hostname no longer resolves, and the /data route is gone from the host
# that does (404 on GET, 405 on POST), so the client cannot be repaired by
# repointing it.  So this target produces the two things that do not depend on
# any service being up:
#
#   1. an SD-card tree, which needs no bundling at all.  With `packaged = false`
#      LÖVE Potion runs a plain `game/` folder sitting next to its own binary,
#      so this is the route that actually boots today, and the one where a
#      player can drop their .gb right next to main.lua for the auto-import.
#   2. a bundle zip in the layout the bundler expects, for whenever the service
#      is reachable, so producing the single-file executables is a drag and
#      drop rather than a re-derivation of this layout by hand.
#
# The game payload is unpacked from game.love rather than re-copied from the
# source tree, so the console files are byte-identical to every other platform's
# -- including the version stamp above, which a fresh copy would miss.
build_console() {
  local targets="$1"          # toml array body, e.g. '"ctr", "hac"'
  local label="$2"            # human name for the log line
  say "building for Nintendo consoles ($label) via LÖVE Potion"

  local out="$DIST/console"
  local stage="$WORK/console"
  rm -rf "$stage" "$out"
  mkdir -p "$stage/game" "$out"

  # 1. game payload, straight out of the archive the desktop builds ship
  unzip -q "$LOVE_FILE" -d "$stage/game"
  [ -f "$stage/game/main.lua" ] \
    || fail "console payload has no main.lua at its root"

  # 2. icons, in each console's required size and container
  say "generating console icons"
  python3 "$ROOT/tools/make_console_icons.py" --out "$stage/icons" \
    || fail "icon generation failed (needs Pillow: python3 -m pip install Pillow)"
  for required in icon-ctr.png icon-hac.jpg icon-cafe.png; do
    [ -f "$stage/icons/$required" ] || fail "icon generation did not write $required"
  done

  # 3. bundler config.  Two files on purpose, and they are not redundant: the
  # published example and docs use lovebrew.toml with a per-target `icons`
  # table, while the current bundler source reads bundle.toml with a single
  # `icon`.  The two schemas are mutually exclusive, the service picks one
  # filename and ignores the other, and writing both costs nothing while
  # removing a coin flip over which deployment is live.
  local semver="$VERSION"
  printf '%s' "$semver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || semver="0.1.0"

  cat > "$stage/lovebrew.toml" <<TOML
[metadata]
title = "$APP_NAME"
author = "bryanthaboi"
description = "Pokemon Red/Blue recompilation"
version = "$semver"
icons = { ctr = "icons/icon-ctr.png", hac = "icons/icon-hac.jpg", cafe = "icons/icon-cafe.png" }

[build]
targets = [$targets]
source = "game"
packaged = $CONSOLE_PACKAGED
TOML

  cat > "$stage/bundle.toml" <<TOML
[metadata]
title = "$APP_NAME"
author = "bryanthaboi"
description = "Pokemon Red/Blue recompilation"
version = "$semver"
icon = "icons/icon-ctr.png"

[build]
targets = [$targets]
source = "game"
TOML

  # 4. bundle zip, for the hosted bundler
  local bundle="$out/$APP_NAME-$VERSION-console-bundle.zip"
  (cd "$stage" && zip -q -9 -r "$bundle" lovebrew.toml bundle.toml game icons \
    -x '*.DS_Store')

  # 5. SD-card tree.  The LÖVE Potion binary is deliberately not vendored: it
  # is a 20-35MB per-console download with its own release cadence, and pinning
  # a stale copy inside our dist is how a player ends up debugging a runtime
  # mismatch that we caused.
  local sd="$out/sdcard"
  mkdir -p "$sd"
  cp -R "$stage/game" "$sd/game"
  cp -R "$stage/icons" "$sd/icons"
  cat > "$sd/README.txt" <<'TXT'
Pokemon Gen 1 recompilation, Nintendo homebrew (3DS / Switch / Wii U)
====================================================================

This folder is the game, not the runtime.  It runs on LÖVE Potion, which is a
separate download:

    https://github.com/lovebrew/lovepotion/releases

1. Copy LÖVE Potion's binary for your console (.3dsx, .nro or .wuhb) onto the
   SD card, in the usual homebrew location.
2. Copy this `game` folder in next to that binary.
3. Copy your own Pokemon Red / Blue / Yellow ROM (.gb or .gbc) into the `game`
   folder, right beside main.lua.
4. Launch it from the homebrew menu.

No ROM ships with this, and none can: the game builds everything it needs from
your own cartridge dump on first launch.  That import runs once, takes a while
on a 3DS, and writes into the save directory afterwards.

The ROM is found by its SHA-1, so the filename does not matter, and Red, Blue
and Yellow can all sit there together.

If instead you built a single fused executable with the bundler (packaged =
true), there is no `game` folder to drop the ROM beside -- the source lives
inside the binary and is read-only.  Put the ROM in the game's save directory
instead; the launcher prints the exact path when it cannot find one.
TXT

  say "console bundle: $bundle"
  say "console SD tree: $sd"
  warn "not built into .3dsx/.nro/.wuhb here: drag the bundle zip above into"
  warn "https://bundle.lovebrew.org, which returns the executables. (Ignore"
  warn "api.lovebrew.org -- that is the unreleased rewrite's endpoint, it 502s,"
  warn "and it is not what the live bundler uses.) The SD tree needs no bundler."
}

# --------------------------------------------------------------- Android
build_android() {
  say "building Android (delegating to scripts/build_android.sh)"
  local args=()
  if [ "$VERSION_EXPLICIT" = true ]; then
    args+=(--version "$VERSION")
  fi
  "$ROOT/scripts/build_android.sh" ${args[@]+"${args[@]}"}
}

# --------------------------------------------------------------- iOS
build_ios() {
  say "building iOS (delegating to scripts/build_ios.sh)"
  local args=()
  if [ "$IOS_RELEASE" = true ]; then
    args+=(--release)
  fi
  if [ "$VERSION_EXPLICIT" = true ]; then
    args+=(--version "$VERSION")
  fi
  "$ROOT/scripts/build_ios.sh" ${args[@]+"${args[@]}"}
}

case "$TARGET" in
  mac) build_mac ;;
  win) build_win ;;
  linux) build_linux ;;
  android) build_android ;;
  ios) build_ios ;;
  # ctr / hac / cafe are the bundler's own names for the three consoles.
  console)
    # "ctr cafe" -> '"ctr", "cafe"' for the toml array, and "3DS, Wii U" for
    # the log line.
    console_toml=""
    console_label=""
    for c in $CONSOLE_LIST; do
      case "$c" in
        ctr)  name="3DS" ;;
        hac)  name="Switch" ;;
        cafe) name="Wii U" ;;
      esac
      console_toml="${console_toml:+$console_toml, }\"$c\""
      console_label="${console_label:+$console_label, }$name"
    done
    build_console "$console_toml" "$console_label"
    ;;
  # `all` stays the desktop trio: the console output is not a finished
  # executable, so folding it in would make every desktop build print bundler
  # instructions nobody asked for.
  all) build_mac; build_win; build_linux ;;
esac

case "$TARGET" in
  android) say "done. See $DIST/android/" ;;
  ios) say "done. See $DIST/ios/" ;;
  3ds|switch|wiiu|console) say "done. See $DIST/console/" ;;
  *) say "done. Artifacts in $DIST" ;;
esac
