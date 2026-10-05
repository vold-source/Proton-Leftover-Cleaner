#!/bin/bash
#
# Builds the Proton Leftover Cleaner AppImage.
#
#   bash packaging/appimage/build.sh
#
# Creates in the "build" folder:
#   Proton_Leftover_Cleaner-<version>-x86_64.AppImage          the app
#   Proton_Leftover_Cleaner-<version>-x86_64.AppImage.sha256   checksum
#   Proton_Leftover_Cleaner-<version>-x86_64.AppImage.zsync    for AppImage updaters
# Upload all three to the GitHub release of that version.
#
# The version is taken from APP_VERSION in proton-leftover-cleaner.sh.
# The AppImage uses zenity and python3 from the system.

set -euo pipefail

packaging="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$packaging/../.." && pwd)"
script="$root/proton-leftover-cleaner.sh"
version="$(sed -n 's/^readonly APP_VERSION="\(.*\)"$/\1/p' "$script")"
[[ -n "$version" ]] || { echo "Could not read APP_VERSION from $script" >&2; exit 1; }

out="$root/build"
appdir="$out/AppDir"
image="$out/Proton_Leftover_Cleaner-$version-x86_64.AppImage"

# Where AppImage updaters (e.g. AppManager) look for new versions.
repo_owner="${GITHUB_OWNER:-vold-source}"
repo_name="${GITHUB_REPO:-Proton-Leftover-Cleaner}"
update_info="gh-releases-zsync|$repo_owner|$repo_name|latest|Proton_Leftover_Cleaner-*x86_64.AppImage.zsync"

appimagetool="${APPIMAGETOOL:-$out/appimagetool-x86_64.AppImage}"
if [[ ! -x "$appimagetool" ]]; then
    echo "Downloading appimagetool…"
    mkdir -p "$out"
    curl -fL --progress-bar -o "$appimagetool" \
        https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x "$appimagetool"
fi

echo "Preparing AppDir for version $version…"
rm -rf "$appdir"
install -D -m 755 "$script"                                     "$appdir/usr/bin/proton-leftover-cleaner"
install -D -m 755 "$packaging/AppRun"                           "$appdir/AppRun"
install -D -m 644 "$packaging/proton-leftover-cleaner.desktop"  "$appdir/proton-leftover-cleaner.desktop"
install -D -m 644 "$packaging/proton-leftover-cleaner.svg"      "$appdir/proton-leftover-cleaner.svg"
install -D -m 644 "$packaging/proton-leftover-cleaner.png"      "$appdir/.DirIcon"

echo "Building AppImage…"
rm -f "$image" "$image.sha256" "$image.zsync"
# APPIMAGE_EXTRACT_AND_RUN: works without FUSE. The .zsync file is written
# into the current folder, so run from the output folder.
(cd "$out" && APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 VERSION="$version" \
    "$appimagetool" --no-appstream --updateinformation "$update_info" "$appdir" "$image")
# Newer appimagetool versions may write the .zsync file into the home folder.
if [[ ! -f "$image.zsync" && -f "$HOME/${image##*/}.zsync" ]]; then
    mv "$HOME/${image##*/}.zsync" "$image.zsync"
fi

(cd "$out" && sha256sum "${image##*/}" > "${image##*/}.sha256")

echo
echo "Finished:"
ls -1 "$image" "$image.sha256" "$image.zsync"
