#!/bin/bash
set -euo pipefail
DOCTOR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DOCTOR_ROOT"
DOCTOR_BUILD="$DOCTOR_ROOT/.build"
mkdir -p "$DOCTOR_BUILD/tmp" "$DOCTOR_BUILD/ModuleCache" "$DOCTOR_BUILD/ClangCache"
DOCTOR_TMP="$(mktemp -d /private/tmp/doja-doctor-build.XXXXXX)"
# The Swift driver requires POSIX temporary directories (this disk is exFAT).
# Only transient compiler files use the internal disk; all caches stay external.
export TMPDIR="$DOCTOR_TMP/"
trap 'python3 -c '\''import pathlib,shutil,sys; p=pathlib.Path(sys.argv[1]); assert p.parent == pathlib.Path("/private/tmp") and p.name.startswith("doja-doctor-build."); shutil.rmtree(p)'\'' "$DOCTOR_TMP"' EXIT
export CLANG_MODULE_CACHE_PATH="$DOCTOR_BUILD/ClangCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$DOCTOR_BUILD/ModuleCache"
DOCTOR_FLAGS=(--disable-sandbox --disable-index-store --manifest-cache none --scratch-path "$DOCTOR_BUILD" --cache-path "$DOCTOR_BUILD/cache" --config-path "$DOCTOR_BUILD/config" --security-path "$DOCTOR_BUILD/security" -Xswiftc -module-cache-path -Xswiftc "$DOCTOR_BUILD/ModuleCache")
swift build -c release --jobs 2 "${DOCTOR_FLAGS[@]}"
DOCTOR_BIN="$(swift build -c release "${DOCTOR_FLAGS[@]}" --show-bin-path)"
DOCTOR_APP="$DOCTOR_ROOT/dist/DOJA Mac Doctor.app"
mkdir -p "$DOCTOR_APP/Contents/MacOS" "$DOCTOR_APP/Contents/Resources"
cp "$DOCTOR_BIN/DOJAMacDoctor" "$DOCTOR_APP/Contents/MacOS/DOJAMacDoctor"
cp "$DOCTOR_BIN/doctor-scan" "$DOCTOR_ROOT/dist/doctor-scan"
cat > "$DOCTOR_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DOJA Mac Doctor</string>
<key>CFBundleDisplayName</key><string>DOJA Mac Doctor</string>
<key>CFBundleIdentifier</key><string>studio.doja.macdoctor</string>
<key>CFBundleExecutable</key><string>DOJAMacDoctor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>DOJA · 本机诊断与确认清理</string>
</dict></plist>
PLIST
cat > "$DOCTOR_APP/Contents/Resources/PrivacyInfo.xcprivacy" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>NSPrivacyTracking</key><false/>
<key>NSPrivacyCollectedDataTypes</key><array/>
<key>NSPrivacyAccessedAPITypes</key><array>
<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryDiskSpace</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>85F4.1</string></array></dict>
<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryFileTimestamp</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>DDA9.1</string><string>3B52.1</string></array></dict>
<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array></dict>
</array></dict></plist>
PLIST
swift "$DOCTOR_ROOT/scripts/make-icon.swift" "$DOCTOR_BUILD/AppIcon.png"
python3 "$DOCTOR_ROOT/scripts/pack-icon.py" "$DOCTOR_BUILD/AppIcon.png" "$DOCTOR_APP/Contents/Resources/AppIcon.icns"
# exFAT writes AppleDouble sidecars; remove generated sidecars only in our bundle.
python3 - "$DOCTOR_APP" <<'PY'
import pathlib, sys
for item in pathlib.Path(sys.argv[1]).rglob('._*'):
    if item.is_file():
        item.unlink()
PY
codesign --force --sign - --identifier studio.doja.macdoctor "$DOCTOR_APP"
codesign --verify --strict "$DOCTOR_APP"
printf '构建完成：%s\n' "$DOCTOR_APP"
