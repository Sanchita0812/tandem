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
V2_APK="$SCRIPT_DIR/Tandem-v0.2.apk"
ROOT_V2_APK="$SCRIPT_DIR/../Tandem-v0.2.apk"
ROOT_V1_APK="$SCRIPT_DIR/../Tandem-v0.1.apk"
ROOT_EASY_APK="$SCRIPT_DIR/../Tandem.apk"

cp "$OUTPUT_APK" "$V2_APK"
cp "$OUTPUT_APK" "$ROOT_V2_APK"
cp "$OUTPUT_APK" "$ROOT_V1_APK"
cp "$OUTPUT_APK" "$ROOT_EASY_APK"

echo "==> Build successful!"
echo "Primary APK (v0.2): $ROOT_V2_APK"
echo "Simple APK link:   $ROOT_EASY_APK"
