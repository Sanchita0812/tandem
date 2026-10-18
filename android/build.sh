#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

echo "==> Building Tandem Android APK via Gradle..."
./gradlew assembleDebug

OUTPUT_APK="$SCRIPT_DIR/app/build/outputs/apk/debug/app-debug.apk"
DIST_APK="$SCRIPT_DIR/Tandem-v0.1.apk"
ROOT_APK="$SCRIPT_DIR/../Tandem-v0.1.apk"

cp "$OUTPUT_APK" "$DIST_APK"
cp "$OUTPUT_APK" "$ROOT_APK"

echo "==> Build successful!"
echo "APK location: $DIST_APK"
echo "Root copy:    $ROOT_APK"
