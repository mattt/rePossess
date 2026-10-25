#!/bin/bash
# Builds, signs, runs, and quits rePossess.app, the menu bar app with the `repossess` command inside.
#
#   scripts/app.sh build             Build both products, assemble the bundle, and sign it.
#   scripts/app.sh sign              Sign the assembled bundle again.
#   scripts/app.sh run [options...]  Open the app; options such as --library <folder> and --no-keychain go to it.
#   scripts/app.sh quit              Quit the running app.
#
# REPOSSESS_SIGNING_IDENTITY chooses the certificate, as for `mise run build:release`.
# REPOSSESS_APP_DIR chooses the folder for rePossess.app; the default is build/.
#
# The bundle:
#   Contents/MacOS/RePossessApp   the menu bar app
#   Contents/MacOS/repossess      the command, which MCP clients start as `repossess mcp`
#   Contents/Resources/*.bundle   SwiftPM's resource bundles, such as MLX's Metal library
#
# Both executables are signed with the identifier co.dododo.repossess and the same certificate,
# so that they have the designated requirement of the command that Mattt allowed to read the device token.
# The command sits in Contents/MacOS, not Contents/Helpers, because Foundation gives a program there
# the app's bundle, and so the resource bundles in Contents/Resources.
set -euo pipefail

cd "$(dirname "$0")/.."

identity="${REPOSSESS_SIGNING_IDENTITY:-Apple Development: Mattt Zmuda (S3NBB5643Q)}"
identifier="co.dododo.repossess"
folder="${REPOSSESS_APP_DIR:-build}"
app="$folder/rePossess.app"

requirement() {
    codesign --display --requirements - "$1" 2>&1 | sed -n 's/^designated => //p'
}

assemble() {
    swift build -c release --product repossess
    swift build -c release --product RePossessApp
    local bin version
    bin="$(swift build -c release --show-bin-path)"
    version="$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/repossess/Command.swift)"
    if [ -z "$version" ]; then
        echo "error: no version in Sources/repossess/Command.swift" >&2
        exit 1
    fi

    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp App/Info.plist "$app/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$app/Contents/Info.plist"
    cp "$bin/RePossessApp" "$app/Contents/MacOS/RePossessApp"
    cp "$bin/repossess" "$app/Contents/MacOS/repossess"
    local bundle found=0
    for bundle in "$bin"/*.bundle; do
        [ -d "$bundle" ] || continue
        ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        echo "error: no resource bundles in $bin" >&2
        exit 1
    fi
    if [ ! -f "$app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
        echo "error: MLX's Metal library is missing from the build" >&2
        exit 1
    fi
    echo "Assembled $app (version $version)"
}

sign() {
    if [ ! -d "$app" ]; then
        echo "error: $app does not exist; run \`mise run build:app\` first" >&2
        exit 1
    fi
    # Inner code first, then the bundle, which seals it.
    codesign --force --sign "$identity" --identifier "$identifier" --timestamp=none "$app/Contents/MacOS/repossess"
    codesign --force --sign "$identity" --timestamp=none "$app"
    codesign --verify --strict --deep "$app"
    local app_requirement helper_requirement
    app_requirement="$(requirement "$app")"
    helper_requirement="$(requirement "$app/Contents/MacOS/repossess")"
    echo "App:    $app_requirement"
    echo "Helper: $helper_requirement"
    if [ "$app_requirement" != "$helper_requirement" ]; then
        echo "error: the app and the helper have different designated requirements" >&2
        exit 1
    fi
    echo "Signed $app"
}

case "${1:-}" in
    build)
        assemble
        sign
        ;;
    sign)
        sign
        ;;
    run)
        shift
        if [ ! -d "$app" ]; then
            echo "error: $app does not exist; run \`mise run build:app\` first" >&2
            exit 1
        fi
        open -n "$app" --args ${1+"$@"}
        ;;
    quit)
        if pgrep -x RePossessApp > /dev/null; then
            osascript -e "quit app id \"$identifier\"" || pkill -x RePossessApp
        fi
        ;;
    *)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 64
        ;;
esac
