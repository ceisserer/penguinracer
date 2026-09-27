#!/usr/bin/env bash
# Toolchain for exporting PenguinRacer to Android: Godot 4.7.2 and its export templates, JDK 17,
# and the Android SDK packages the 4.7.2 Gradle template pins (android_source.zip →
# config.gradle: compileSdk/targetSdk 36, build-tools 36.1.0, NDK 29.0.14206865, Java 17).
# Bump those together with GODOT_VERSION.
#
# Idempotent: every step checks before it downloads, so it is safe to re-run by hand and cheap
# on a rebuilt container, where the SDK survives on the android-sdk volume.
set -euo pipefail

GODOT_VERSION=4.7.2
GODOT_TAG="${GODOT_VERSION}-stable"
GODOT_TEMPLATES="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable"

JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
CMDLINE_TOOLS_ZIP=commandlinetools-linux-16111833_latest.zip
CMDLINE_TOOLS_SHA1=e025545c62a8e64c7559119566a569fb1dec5f60
SDK_PACKAGES=(
  "platform-tools"
  "platforms;android-36"
  "build-tools;36.1.0"
  "ndk;29.0.14206865"
)

KEYSTORE="$HOME/.local/share/godot/keystores/debug.keystore"
EDITOR_SETTINGS="$HOME/.config/godot/editor_settings-${GODOT_VERSION%.*}.tres"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
log() { printf '\n== %s\n' "$*"; }

log "System packages (JDK 17, unzip)"
if ! [ -x "$JAVA_HOME/bin/keytool" ] || ! command -v unzip >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends openjdk-17-jdk-headless unzip curl ca-certificates
fi

log "Godot $GODOT_VERSION"
if ! godot --version 2>/dev/null | grep -q "^${GODOT_VERSION}\.stable"; then
  curl -fsSL -o "$tmp/godot.zip" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/Godot_v${GODOT_TAG}_linux.x86_64.zip"
  unzip -q "$tmp/godot.zip" -d "$tmp"
  sudo install -m 755 "$tmp/Godot_v${GODOT_TAG}_linux.x86_64" /usr/local/bin/godot
fi

log "Godot export templates"
if ! [ -f "$GODOT_TEMPLATES/android_source.zip" ]; then
  curl -fsSL -o "$tmp/templates.tpz" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/Godot_v${GODOT_TAG}_export_templates.tpz"
  unzip -q "$tmp/templates.tpz" -d "$tmp/tpl"
  mkdir -p "$GODOT_TEMPLATES"
  cp -a "$tmp/tpl/templates/." "$GODOT_TEMPLATES/"
fi

log "Android SDK in $ANDROID_HOME"
# A fresh named volume is mounted root-owned.
sudo mkdir -p "$ANDROID_HOME"
sudo chown "$(id -u):$(id -g)" "$ANDROID_HOME"
sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if ! [ -x "$sdkmanager" ]; then
  curl -fsSL -o "$tmp/cmdline-tools.zip" "https://dl.google.com/android/repository/$CMDLINE_TOOLS_ZIP"
  echo "$CMDLINE_TOOLS_SHA1  $tmp/cmdline-tools.zip" | sha1sum -c -
  unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv "$tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
fi
export JAVA_HOME ANDROID_HOME
"$sdkmanager" --sdk_root="$ANDROID_HOME" --licenses >/dev/null < <(yes)  # not `yes |`: SIGPIPE trips pipefail
"$sdkmanager" --sdk_root="$ANDROID_HOME" "${SDK_PACKAGES[@]}"

log "Debug keystore"
if ! [ -f "$KEYSTORE" ]; then
  mkdir -p "$(dirname "$KEYSTORE")"
  "$JAVA_HOME/bin/keytool" -genkeypair -v -keystore "$KEYSTORE" -storepass android \
    -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
fi

log "Godot editor settings"
# Godot fills these from JAVA_HOME / ANDROID_HOME only when it first writes the file; an existing
# file keeps whatever it holds, often "", so point it at this toolchain explicitly.
if [ -f "$EDITOR_SETTINGS" ]; then
  set_editor() {
    local key=$1 value=$2
    if grep -q "^export/android/$key = " "$EDITOR_SETTINGS"; then
      sed -i "s|^export/android/$key = .*|export/android/$key = \"$value\"|" "$EDITOR_SETTINGS"
    else
      printf 'export/android/%s = "%s"\n' "$key" "$value" >>"$EDITOR_SETTINGS"
    fi
  }
  set_editor java_sdk_path "$JAVA_HOME"
  set_editor android_sdk_path "$ANDROID_HOME"
  set_editor debug_keystore "$KEYSTORE"
  set_editor debug_keystore_user androiddebugkey
  set_editor debug_keystore_pass android
fi

log "Android toolchain ready"
