#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Tests"
PROJECT_PATH="Tests.xcodeproj"
SCHEME="Tests"
CONFIGURATION="Release"
DESTINATION="generic/platform=macOS"
BUILD_DIR="build/release"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_WORK_DIR="${BUILD_DIR}/dmg"
NOTARY_ZIP="${BUILD_DIR}/${APP_NAME}-notary.zip"
SKIP_GIT_CHECK=0
SKIP_NOTARIZATION=0
GENERATE_PROJECT=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build, sign, notarize, and package ${APP_NAME}.app into a notarized DMG.

Options:
  --identity ID          Developer ID Application identity to use.
                         Default: first "Developer ID Application" identity in the keychain.
  --team-id TEAM_ID      Apple Developer Team ID. Required when using APPLE_ID credentials.
  --notary-profile NAME  notarytool keychain profile name.
                         You can create one with:
                         xcrun notarytool store-credentials NAME --apple-id EMAIL --team-id TEAM_ID --password APP_PASSWORD
  --build-dir PATH       Release output directory. Default: ${BUILD_DIR}
  --generate-project     Run xcodegen generate before archiving.
  --skip-git-check       Allow building from a dirty working tree.
  --skip-notarization    Build and sign locally, but do not submit to Apple.
  -h, --help             Show this help.

Notarization credentials:
  Preferred:
    NOTARY_PROFILE or --notary-profile. The password is stored by notarytool
    in your keychain when you run store-credentials.

  Alternative:
    APPLE_ID, APPLE_PASSWORD, and TEAM_ID or --team-id.
    APPLE_PASSWORD should be an app-specific password, not your Apple ID login password.

Useful environment overrides:
  DEVELOPER_ID_APPLICATION, TEAM_ID, NOTARY_PROFILE, APPLE_ID, APPLE_PASSWORD
EOF
}

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      DEVELOPER_ID_APPLICATION="${2:?Missing identity after --identity}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:?Missing team id after --team-id}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:?Missing profile name after --notary-profile}"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="${2:?Missing path after --build-dir}"
      ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
      EXPORT_DIR="${BUILD_DIR}/export"
      DMG_WORK_DIR="${BUILD_DIR}/dmg"
      NOTARY_ZIP="${BUILD_DIR}/${APP_NAME}-notary.zip"
      shift 2
      ;;
    --skip-git-check)
      SKIP_GIT_CHECK=1
      shift
      ;;
    --generate-project)
      GENERATE_PROJECT=1
      shift
      ;;
    --skip-notarization)
      SKIP_NOTARIZATION=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  printf '\n==> %s\n' "$*"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

notarytool_args() {
  if [[ -n "${NOTARY_PROFILE}" ]]; then
    printf '%s\n' "--keychain-profile" "${NOTARY_PROFILE}"
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${TEAM_ID}" ]]; then
    printf '%s\n' "--apple-id" "${APPLE_ID}" "--password" "${APPLE_PASSWORD}" "--team-id" "${TEAM_ID}"
  else
    echo "Notarization credentials are missing." >&2
    echo "Set NOTARY_PROFILE, or set APPLE_ID, APPLE_PASSWORD, and TEAM_ID." >&2
    exit 1
  fi
}

notarize_and_staple() {
  local artifact="$1"

  log "Submitting $(basename "${artifact}") for notarization"
  submit_for_notarization "${artifact}"

  log "Stapling $(basename "${artifact}")"
  xcrun stapler staple "${artifact}"
}

submit_for_notarization() {
  local artifact="$1"
  local args=()

  if [[ -n "${NOTARY_PROFILE}" ]]; then
    args=(--keychain-profile "${NOTARY_PROFILE}")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${TEAM_ID}" ]]; then
    args=(--apple-id "${APPLE_ID}" --password "${APPLE_PASSWORD}" --team-id "${TEAM_ID}")
  else
    notarytool_args >/dev/null
  fi

  xcrun notarytool submit "${artifact}" "${args[@]}" --wait
}

codesign_item() {
  local path="$1"
  shift

  codesign --force --timestamp --options runtime --sign "${DEVELOPER_ID_APPLICATION}" "$@" "${path}"
}

require_tool git
require_tool xcodebuild
require_tool create-dmg

if [[ "${SKIP_NOTARIZATION}" -eq 0 ]]; then
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null
fi

if [[ "${SKIP_GIT_CHECK}" -eq 0 && -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash changes, or pass --skip-git-check." >&2
  exit 1
fi

if [[ -z "${DEVELOPER_ID_APPLICATION}" ]]; then
  DEVELOPER_ID_APPLICATION="$(
    security find-identity -v -p codesigning |
      sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' |
      head -n 1
  )"
fi

if [[ -z "${DEVELOPER_ID_APPLICATION}" ]]; then
  echo "No Developer ID Application signing identity found." >&2
  echo "Pass --identity or set DEVELOPER_ID_APPLICATION." >&2
  exit 1
fi

log "Using signing identity: ${DEVELOPER_ID_APPLICATION}"

if [[ -z "${TEAM_ID}" && "${DEVELOPER_ID_APPLICATION}" =~ \(([A-Z0-9]+)\)$ ]]; then
  TEAM_ID="${BASH_REMATCH[1]}"
  log "Inferred team ID: ${TEAM_ID}"
fi

log "Updating submodules"
git submodule update --init --recursive

if [[ "${GENERATE_PROJECT}" -eq 1 ]]; then
  require_tool xcodegen
  log "Generating Xcode project"
  xcodegen generate
fi

log "Cleaning release output"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DMG_WORK_DIR}"

log "Archiving ${APP_NAME}.app"
xcodebuild_args=(
  archive
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination "${DESTINATION}"
  -archivePath "${ARCHIVE_PATH}"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION}"
  OTHER_CODE_SIGN_FLAGS="--timestamp"
  SKIP_INSTALL=NO
)
if [[ -n "${TEAM_ID}" ]]; then
  xcodebuild_args+=(DEVELOPMENT_TEAM="${TEAM_ID}")
fi
xcodebuild "${xcodebuild_args[@]}"

ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if [[ ! -d "${ARCHIVED_APP}" ]]; then
  echo "Archive did not produce ${ARCHIVED_APP}" >&2
  exit 1
fi

APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
log "Preparing app bundle"
ditto "${ARCHIVED_APP}" "${APP_PATH}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist")"
RELEASE_NAME="${APP_NAME}-${VERSION}"
if [[ -n "${BUILD_NUMBER}" && "${BUILD_NUMBER}" != "${VERSION}" ]]; then
  RELEASE_NAME="${RELEASE_NAME}-${BUILD_NUMBER}"
fi

log "Signing nested executables"
if [[ -f "${APP_PATH}/Contents/MacOS/TestsCLI" ]]; then
  codesign_item "${APP_PATH}/Contents/MacOS/TestsCLI"
fi
if [[ -f "${APP_PATH}/Contents/MacOS/xcbeautify" ]]; then
  codesign_item "${APP_PATH}/Contents/MacOS/xcbeautify"
fi

log "Signing app bundle"
codesign_item "${APP_PATH}" --entitlements "Tests/Tests.entitlements"

log "Verifying app signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

if [[ "${SKIP_NOTARIZATION}" -eq 0 ]]; then
  log "Creating notary upload zip"
  rm -f "${NOTARY_ZIP}"
  ditto -c -k --keepParent "${APP_PATH}" "${NOTARY_ZIP}"
  log "Submitting app bundle for notarization"
  submit_for_notarization "${NOTARY_ZIP}"
  log "Stapling app bundle"
  xcrun stapler staple "${APP_PATH}"
fi

log "Creating signed DMG"
rm -f "${DMG_WORK_DIR}"/*.dmg
create-dmg \
  --overwrite \
  --identity="${DEVELOPER_ID_APPLICATION}" \
  --dmg-title="${APP_NAME}" \
  "${APP_PATH}" \
  "${DMG_WORK_DIR}"

GENERATED_DMG="$(find "${DMG_WORK_DIR}" -maxdepth 1 -type f -name '*.dmg' -print -quit)"
if [[ -z "${GENERATED_DMG}" ]]; then
  echo "create-dmg did not produce a DMG in ${DMG_WORK_DIR}" >&2
  exit 1
fi

FINAL_DMG="${BUILD_DIR}/${RELEASE_NAME}.dmg"
mv "${GENERATED_DMG}" "${FINAL_DMG}"

if [[ "${SKIP_NOTARIZATION}" -eq 0 ]]; then
  notarize_and_staple "${FINAL_DMG}"
fi

log "Verifying DMG signature"
codesign --verify --verbose=2 "${FINAL_DMG}"

if [[ "${SKIP_NOTARIZATION}" -eq 0 ]]; then
  log "Running Gatekeeper checks"
  spctl --assess --type execute --verbose=4 "${APP_PATH}"
  spctl --assess --type open --context context:primary-signature --verbose=4 "${FINAL_DMG}"
fi

log "Release DMG created"
printf '%s\n' "${FINAL_DMG}"
