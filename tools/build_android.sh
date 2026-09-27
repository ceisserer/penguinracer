#!/usr/bin/env bash
#
# Exports the `Android` preset to build/android/penguinracer.apk, and with
# --install puts it on the device `adb` sees.
#
#     tools/build_android.sh              # debug APK (debug keystore)
#     tools/build_android.sh --release    # release APK; needs a release keystore
#     tools/build_android.sh --install    # debug APK, then adb install -r
#
# Prerequisites are .devcontainer/setup-android.sh's: Godot 4.7.2 with its export
# templates, JDK 17, the Android SDK in $ANDROID_HOME, a debug keystore, and the
# editor settings pointing at the SDK — the script checks for each before it
# starts. The preset uses the prebuilt template
# (no Gradle build), arm64-v8a only, and ships every course in the APK — the
# web build's per-course streaming (PackStream) is a browser concern.
#
# A release export reads the keystore from the environment, never from the
# repository: GODOT_ANDROID_KEYSTORE_RELEASE_PATH, _USER and _PASSWORD.
#
# The game on a phone runs the Mobile renderer (Vulkan), as the desktop does;
# a device without Vulkan falls back to Compatibility on its own
# (`rendering_device/fallback_to_opengl3`), and RenderBackend then turns the
# shadows off there as it does on the web.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PROJECT="$ROOT/game"
OUT="$ROOT/build/android"
APK="$OUT/penguinracer.apk"

MODE=--export-debug
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --release) MODE=--export-release ;;
        --install) INSTALL=1 ;;
        *) echo "usage: $0 [--release] [--install]" >&2; exit 2 ;;
    esac
done
if [[ "$MODE" == --export-release && -z "${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:-}" ]]; then
    echo "a release export needs GODOT_ANDROID_KEYSTORE_RELEASE_PATH/_USER/_PASSWORD" >&2
    exit 2
fi

# Everything the export needs, checked before a two-minute export fails on it.
# .devcontainer/setup-android.sh installs and configures all of it.
fail() { echo "build_android: $*" >&2; echo "  run: bash .devcontainer/setup-android.sh" >&2; exit 1; }
command -v "$GODOT" >/dev/null || fail "no '$GODOT' on PATH"
GODOT_VERSION="$("$GODOT" --version | cut -d. -f1-3)"                # e.g. 4.7.2
TEMPLATES="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable"
[[ -f "$TEMPLATES/android_debug.apk" && -f "$TEMPLATES/android_release.apk" ]] \
    || fail "no Android export templates in $TEMPLATES"
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
compgen -G "$ANDROID_HOME/build-tools/*/apksigner" >/dev/null \
    || fail "no Android SDK build-tools (apksigner) under $ANDROID_HOME"
EDITOR_SETTINGS="$HOME/.config/godot/editor_settings-${GODOT_VERSION%.*}.tres"
grep -q '^export/android/android_sdk_path = "..*"' "$EDITOR_SETTINGS" 2>/dev/null \
    || fail "Godot's editor settings do not name the Android SDK ($EDITOR_SETTINGS)"
if [[ "$MODE" == --export-debug ]]; then
    # Godot reads these ahead of the editor settings, so a debug build signs
    # even where the editor was never pointed at the keystore.
    DEBUG_KEYSTORE="$HOME/.local/share/godot/keystores/debug.keystore"
    [[ -f "$DEBUG_KEYSTORE" ]] || fail "no debug keystore at $DEBUG_KEYSTORE"
    export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="${GODOT_ANDROID_KEYSTORE_DEBUG_PATH:-$DEBUG_KEYSTORE}"
    export GODOT_ANDROID_KEYSTORE_DEBUG_USER="${GODOT_ANDROID_KEYSTORE_DEBUG_USER:-androiddebugkey}"
    export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD="${GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD:-android}"
fi

mkdir -p "$OUT"
rm -f "$APK"
# The export reports failure on stderr but can still exit 0; the APK is the test.
"$GODOT" --headless --path "$PROJECT" "$MODE" "Android" "$APK"
if [[ ! -s "$APK" ]]; then
    echo "export produced no APK — run it again without --headless in the editor's" \
         "Export dialog for the reason (usually SDK paths in editor settings)" >&2
    exit 1
fi
ls -lh "$APK"

if (( INSTALL )); then
    adb install -r "$APK"
fi
