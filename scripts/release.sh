#!/bin/bash
# Prepare the same direct-download format as iMCP without publishing it.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${REPOSSESS_APP_DIR:-build}/rePossess.app"
dist="${REPOSSESS_DIST_DIR:-dist}"
version="$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/repossess/Command.swift)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: invalid release version" >&2
    exit 1
fi
package="$dist/rePossess-$version.zip"

require_clean_tree() {
    if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
        echo "error: commit release changes before building or packaging" >&2
        exit 1
    fi
}

require_app() {
    require_clean_tree
    if [[ ! -d "$app" ]]; then
        echo "error: build the release app with mise run release:build" >&2
        exit 1
    fi
    local app_version
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    if [[ "$app_version" != "$version" ]]; then
        echo "error: app version $app_version does not match source version $version" >&2
        exit 1
    fi
    local source_revision
    source_revision="$(/usr/libexec/PlistBuddy -c 'Print :RePossessSourceRevision' "$app/Contents/Info.plist")"
    if [[ "$source_revision" != "$(git rev-parse HEAD)" ]]; then
        echo "error: app source revision does not match HEAD; rebuild before packaging" >&2
        exit 1
    fi
    codesign --verify --strict --deep "$app"
    local target details
    for target in "$app" "$app/Contents/MacOS/repossess"; do
        details="$(codesign --display --verbose=4 "$target" 2>&1)"
        if [[ "$details" != *"Authority=Developer ID Application:"* || "$details" != *"runtime"* || "$details" != *"Timestamp="* ]]; then
            echo "error: $target needs Developer ID signing, hardened runtime, and a secure timestamp" >&2
            exit 1
        fi
    done
}

build() {
    require_clean_tree
    REPOSSESS_DISTRIBUTION=1 scripts/app.sh build
}

notarize() {
    require_app
    local credential_args=()
    if [[ -n "${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}${NOTARY_KEY_FILE:-}" ]]; then
        if [[ -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" || ! -f "${NOTARY_KEY_FILE:-}" ]]; then
            echo "error: set NOTARY_KEY_ID, NOTARY_ISSUER_ID, and NOTARY_KEY_FILE together" >&2
            exit 1
        fi
        credential_args=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    elif [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
        credential_args=(--keychain-profile "$KEYCHAIN_PROFILE")
    else
        echo "error: set KEYCHAIN_PROFILE or the NOTARY_* credentials used by iMCP" >&2
        exit 1
    fi
    mkdir -p "$dist"
    local archive="$dist/rePossess-notarize.zip"
    ditto -c -k --keepParent "$app" "$archive"
    xcrun notarytool submit "$archive" --wait "${credential_args[@]}" --output-format json > "$dist/notarization.json"
    local status
    status="$(plutil -extract status raw "$dist/notarization.json")"
    if [[ "$status" != "Accepted" ]]; then
        echo "error: notarization status is $status; inspect $dist/notarization.json and the notary log" >&2
        exit 1
    fi
    rm -f "$archive"
    echo "Notarization accepted; receipt: $dist/notarization.json"
}

staple() {
    require_app
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
}

verify() {
    require_app
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
}

package_release() {
    verify
    mkdir -p "$dist"
    ditto -c -k --keepParent "$app" "$package"
    # A relative filename makes the checksum usable beside the downloaded ZIP.
    (cd "$dist" && shasum -a 256 "$(basename "$package")" > "$(basename "$package").sha256")
    echo "Prepared $package and $package.sha256; nothing was published"
}

case "${1:-help}" in
    build) build ;;
    notarize) notarize ;;
    staple) staple ;;
    verify) verify ;;
    package) package_release ;;
    prepare) build; notarize; staple; package_release ;;
    help) echo "Usage: scripts/release.sh {build|notarize|staple|verify|package|prepare}" ;;
    *) echo "error: unknown release step: $1" >&2; exit 64 ;;
esac
