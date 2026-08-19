#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_DIR="$ROOT/mobile/macos"
CACHE="$ROOT/.bazinga/love12"
SOURCE_DIR="${LOVE_SOURCE_DIR:-$CACHE/source}"
RUNTIME_APP="${LOVE_APP_OUTPUT:-$CACHE/love.app}"
BUILD_DIR="$CACHE/build"
LOVE_VERSION="$(tr -d '[:space:]' < "$MACOS_DIR/LOVE_VERSION")"
LOVE_SOURCE_REF="$(tr -d '[:space:]' < "$MACOS_DIR/LOVE_SOURCE_REF")"
APPLE_DEPENDENCIES_REF="$(tr -d '[:space:]' < "$MACOS_DIR/APPLE_DEPENDENCIES_REF")"
LOVE_SOURCE_REPO="${LOVE_SOURCE_REPO:-https://github.com/love2d/love.git}"
APPLE_DEPENDENCIES_REPO="${APPLE_DEPENDENCIES_REPO:-https://github.com/love2d/love-apple-dependencies.git}"

FETCH=false
CLEAN=false

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

strip_bundle_metadata() {
  local bundle="$1"
  xattr -rc "$bundle"
  xattr -rd com.apple.FinderInfo "$bundle" 2>/dev/null || true
  xattr -rd 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
}

while [ $# -gt 0 ]; do
  case "$1" in
    --fetch) FETCH=true ;;
    --clean) CLEAN=true ;;
    -h|--help)
      printf '%s\n' 'usage: scripts/build_love_macos.sh [--fetch] [--clean]'
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || fail "macOS LÖVE builds require Darwin"
command -v git >/dev/null 2>&1 || fail "git is required to fetch LÖVE sources"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required to build LÖVE for macOS"
command -v xattr >/dev/null 2>&1 || fail "xattr is required to normalize the runtime bundle"

source_ready() {
  [ -d "$SOURCE_DIR/platform/xcode/love.xcodeproj" ] \
    && [ -d "$SOURCE_DIR/platform/xcode/macosx/Frameworks/Lua.framework" ] \
    && [ -d "$SOURCE_DIR/platform/xcode/shared/Frameworks/SDL3.xcframework" ]
}

source_is_pinned() {
  [ "$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)" = "$LOVE_SOURCE_REF" ] \
    && [ -f "$SOURCE_DIR/.gen1recomp-apple-dependencies-ref" ] \
    && [ "$(tr -d '[:space:]' < "$SOURCE_DIR/.gen1recomp-apple-dependencies-ref")" = "$APPLE_DEPENDENCIES_REF" ]
}

fetch_repo() {
  local repo_url="$1"
  local ref="$2"
  local destination="$3"
  mkdir -p "$destination"
  git -C "$destination" init -q
  git -C "$destination" remote add origin "$repo_url"
  git -C "$destination" fetch --depth 1 origin "$ref"
  git -C "$destination" checkout --detach -q FETCH_HEAD
}

fetch_sources() {
  local tmp
  tmp="$(mktemp -d "$CACHE/fetch.XXXXXX")"
  say "fetching LÖVE source $LOVE_SOURCE_REF"
  fetch_repo "$LOVE_SOURCE_REPO" "$LOVE_SOURCE_REF" "$tmp/love"
  say "fetching Apple dependencies $APPLE_DEPENDENCIES_REF"
  fetch_repo "$APPLE_DEPENDENCIES_REPO" "$APPLE_DEPENDENCIES_REF" "$tmp/dependencies"
  mkdir -p "$tmp/love/platform/xcode/macosx/Frameworks" "$tmp/love/platform/xcode/shared"
  cp -R "$tmp/dependencies/macOS/Frameworks/." "$tmp/love/platform/xcode/macosx/Frameworks/"
  cp -R "$tmp/dependencies/shared/." "$tmp/love/platform/xcode/shared/"
  rm -rf "$SOURCE_DIR"
  mkdir -p "$(dirname "$SOURCE_DIR")"
  mv "$tmp/love" "$SOURCE_DIR"
  printf '%s\n' "$APPLE_DEPENDENCIES_REF" > "$SOURCE_DIR/.gen1recomp-apple-dependencies-ref"
  rm -rf "$tmp"
  say "LÖVE source ready at $SOURCE_DIR"
}

if $CLEAN; then
  [ -z "${LOVE_SOURCE_DIR:-}" ] \
    || fail "--clean cannot be used with LOVE_SOURCE_DIR"
  rm -rf "$SOURCE_DIR" "$BUILD_DIR" "$RUNTIME_APP"
fi

if ! source_ready || ! source_is_pinned; then
  if ! $FETCH; then
    fail "pinned LÖVE 12 sources are missing at $SOURCE_DIR; run scripts/build_love_macos.sh --fetch"
  fi
  [ -z "${LOVE_SOURCE_DIR:-}" ] \
    || fail "LOVE_SOURCE_DIR is not the pinned LÖVE commit $LOVE_SOURCE_REF"
  fetch_sources
fi

PROJECT="$SOURCE_DIR/platform/xcode/love.xcodeproj"
rm -rf "$BUILD_DIR" "$RUNTIME_APP"
mkdir -p "$BUILD_DIR"
say "building LÖVE 12 macOS runtime"
xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -target love-macosx \
  -configuration Release \
  -sdk macosx \
  SYMROOT="$BUILD_DIR" \
  OBJROOT="$BUILD_DIR/Intermediates" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=-

BUILT_APP="$BUILD_DIR/Release/love.app"
[ -d "$BUILT_APP" ] || fail "xcodebuild produced no LÖVE app at $BUILT_APP"
ditto --norsrc "$BUILT_APP" "$RUNTIME_APP"
strip_bundle_metadata "$RUNTIME_APP"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RUNTIME_APP/Contents/Info.plist" 2>/dev/null || true)"
version_re="$(printf '%s' "$LOVE_VERSION" | sed 's/\./\\./g')"
printf '%s' "$version" | grep -Eq "^${version_re}(\.|$)" \
  || fail "built runtime reports LÖVE version '$version'"
[ -x "$RUNTIME_APP/Contents/MacOS/love" ] \
  || fail "built runtime is missing Contents/MacOS/love"
[ -f "$RUNTIME_APP/Contents/Frameworks/love.framework/love" ] \
  || fail "built runtime is missing love.framework"
otool -L "$RUNTIME_APP/Contents/Frameworks/love.framework/love" \
  | grep -q '/Metal.framework/' \
  || fail "built LÖVE runtime is not linked to Metal"

archs="$(lipo -archs "$RUNTIME_APP/Contents/MacOS/love")"
printf '%s' "$archs" | grep -qw arm64 \
  || fail "built LÖVE app is missing arm64"
printf '%s' "$archs" | grep -qw x86_64 \
  || fail "built LÖVE app is missing x86_64"
framework_archs="$(lipo -archs "$RUNTIME_APP/Contents/Frameworks/love.framework/love")"
printf '%s' "$framework_archs" | grep -qw arm64 \
  || fail "built LÖVE framework is missing arm64"
printf '%s' "$framework_archs" | grep -qw x86_64 \
  || fail "built LÖVE framework is missing x86_64"

say "LÖVE 12 macOS runtime: $RUNTIME_APP"
