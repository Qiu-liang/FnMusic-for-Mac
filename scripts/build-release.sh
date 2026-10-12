#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_PATH="${PROJECT_ROOT}/FnMusic.xcodeproj"
SCHEME="FnMusic"
CONFIGURATION="Release"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${PROJECT_ROOT}/.build/PackagingDerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/dist}"
APP_NAME="FnMusic"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
ZIP_PATH="${OUTPUT_DIR}/${APP_NAME}-macOS-universal.zip"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}-macOS-universal.dmg"

for tool in xcodebuild ditto hdiutil lipo unzip; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "${tool}" >&2
        exit 1
    fi
done

if [[ ! -d "${PROJECT_PATH}" ]]; then
    printf 'Xcode project not found: %s\n' "${PROJECT_PATH}" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

printf 'Building %s (%s, arm64 + x86_64)...\n' "${APP_NAME}" "${CONFIGURATION}"
xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    build

if [[ ! -d "${APP_PATH}" || ! -x "${APP_PATH}/Contents/MacOS/${APP_NAME}" ]]; then
    printf 'Build completed without the expected app bundle: %s\n' "${APP_PATH}" >&2
    exit 1
fi

ARCHITECTURES="$(lipo -archs "${APP_PATH}/Contents/MacOS/${APP_NAME}")"
for architecture in arm64 x86_64; do
    if [[ " ${ARCHITECTURES} " != *" ${architecture} "* ]]; then
        printf 'Expected a universal app with arm64 and x86_64; found: %s\n' "${ARCHITECTURES}" >&2
        exit 1
    fi
done

printf 'Creating ZIP: %s\n' "${ZIP_PATH}"
ZIP_TEMP="${ZIP_PATH}.tmp.$$"
trap 'rm -f "${ZIP_TEMP}"' EXIT
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_TEMP}"
mv -f "${ZIP_TEMP}" "${ZIP_PATH}"

DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-dmg.XXXXXX")"
trap 'rm -f "${ZIP_TEMP}"; rm -rf "${DMG_STAGE}"' EXIT
ditto "${APP_PATH}" "${DMG_STAGE}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGE}/Applications"

printf 'Creating DMG: %s\n' "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

printf 'Verifying ZIP...\n'
unzip -tq "${ZIP_PATH}"
printf 'Verifying DMG...\n'
hdiutil verify "${DMG_PATH}"

printf '\nBuild packages created:\n  %s\n  %s\n' "${ZIP_PATH}" "${DMG_PATH}"
