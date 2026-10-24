#!/usr/bin/env bash
#
# Automated safety tests for Proton Leftover Cleaner.
#
# Run with:   bash tests/run-tests.sh
#
# Every test builds a fake Steam setup inside a fresh temporary folder and
# runs the app with HOME pointing there, so the app can only see fake
# libraries. A fake zenity (tests/fake-zenity) answers the windows, and a fake
# pgrep says Steam isn't running. The real Steam data on this computer is
# never read or touched, and the temporary folder is deleted at the end.

set -u

tests_dir=$(cd "$(dirname "$0")" && pwd)
app="$tests_dir/../proton-leftover-cleaner.sh"

# The temporary folder everything happens in. Refuse to go on if it isn't a
# fresh folder inside the system's temp area.
temp_base=$(realpath "${TMPDIR:-/tmp}")
root=$(mktemp -d "$temp_base/plc-tests.XXXXXX") || { echo "could not create a temporary folder" >&2; exit 1; }
[[ "$root" == "$temp_base"/plc-tests.* && -d "$root" ]] || { echo "unexpected temporary folder: $root" >&2; exit 1; }
trap 'rm -rf -- "$root"' EXIT

# Fake programs that come first on PATH: zenity (answers windows) and pgrep
# (Steam is running only when a test sets FAKE_STEAM_RUNNING=1).
bin="$root/bin"
mkdir -p "$bin"
cp "$tests_dir/fake-zenity" "$bin/zenity"
printf '#!/bin/sh\n[ "${FAKE_STEAM_RUNNING:-0}" = 1 ]\n' > "$bin/pgrep"
chmod +x "$bin/zenity" "$bin/pgrep"
[[ "$(PATH="$bin:$PATH" type -P zenity)" == "$bin/zenity" ]] || { echo "fake zenity is not in place, stopping" >&2; exit 1; }

failures=0
passes=0
current=""

pass() { passes=$((passes + 1)); }
fail() { failures=$((failures + 1)); echo "  FAIL [$current]: $*"; }

# --- Building a fake Steam setup ---------------------------------------------

# new_case <name>: a fresh folder for one test, with an empty Steam install.
# Sets: case_dir, home, steam, lib (the main library's steamapps folder).
new_case() {
    current="$1"
    echo "- $1"
    case_dir="$root/cases/$1"
    home="$case_dir/home"
    steam="$home/.local/share/Steam"
    lib="$steam/steamapps"
    mkdir -p "$lib/compatdata" "$lib/shadercache" "$lib/common"
}

# manifest <steamapps folder> <App ID> <name> <installdir>
manifest() {
    printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n}\n' \
        "$2" "$3" "$4" > "$1/appmanifest_$2.acf"
}

# installed_game <App ID> <name> <folder>: manifest, game folder, prefix, cache.
installed_game() {
    manifest "$lib" "$1" "$2" "$3"
    mkdir -p "$lib/common/$3" "$lib/compatdata/$1/pfx" "$lib/shadercache/$1"
    echo save > "$lib/compatdata/$1/pfx/save.dat"
}

# leftover <App ID>: prefix and shader cache of an uninstalled game.
leftover() {
    mkdir -p "$lib/compatdata/$1/pfx" "$lib/shadercache/$1"
    echo data > "$lib/compatdata/$1/pfx/file"
}

# shortcuts_vdf <file> <App ID>...: Steam's binary list of non-Steam games.
shortcuts_vdf() {
    python3 - "$@" <<'PYTHON'
import struct, sys
out, ids = sys.argv[1], [int(i) for i in sys.argv[2:]]
data = b"\x00shortcuts\x00"
for n, app_id in enumerate(ids):
    data += b"\x00" + str(n).encode() + b"\x00"
    data += b"\x02appid\x00" + struct.pack("<i", app_id - 2**32 if app_id >= 2**31 else app_id)
    data += b"\x01AppName\x00Game " + str(n).encode() + b"\x00"
    data += b"\x08"
data += b"\x08\x08"
open(out, "wb").write(data)
PYTHON
}

# --- Running the app -------------------------------------------------------------

# run_app [options]: runs the app in the current case. Output goes to
# $case_dir/out, zenity's log to $case_dir/zenity.log. It starts from the case
# folder, so a path that wrongly points "here" stays inside the test.
run_app() {
    : > "$case_dir/zenity.log"
    ( cd "$case_dir" && HOME="$home" USER="plc-test-user" PATH="$bin:$PATH" \
        FAKE_ZENITY_LOG="$case_dir/zenity.log" bash "$app" "$@" ) > "$case_dir/out" 2>&1
}

# --- Checks ------------------------------------------------------------------------

exists()  { if [[ -e "$1" || -L "$1" ]]; then pass; else fail "should still exist: ${1#"$case_dir"/}"; fi; }
gone()    { if [[ -e "$1" || -L "$1" ]]; then fail "should be removed: ${1#"$case_dir"/}"; else pass; fi; }
absent()  { if [[ -e "$1" ]]; then fail "should never have been created: ${1#"$case_dir"/}"; else pass; fi; }
listed()     { if grep -qF -- "$1" "$case_dir/out"; then pass; else fail "--list should show: $1"; fi; }
not_listed() { if grep -qF -- "$1" "$case_dir/out"; then fail "--list should not show: $1"; else pass; fi; }
logged()     { if grep -qF -- "$1" "$case_dir/zenity.log"; then pass; else fail "a window should show: $1"; fi; }
not_logged() { if grep -qF -- "$1" "$case_dir/zenity.log"; then fail "no window should show: $1"; else pass; fi; }

# Snapshot of every file and folder in the fake home, to prove nothing changed.
snapshot() { (cd "$home" && find . | LC_ALL=C sort); }

echo "Running Proton Leftover Cleaner safety tests in $root"

# ---------------------------------------------------------------------------------
new_case "only expected leftovers are removed"
installed_game 100 "Game A" "Game A"
leftover 200
mkdir -p "$lib/common/Old Game" "$lib/common/Steam Controller Configs" "$lib/compatdata/0/pfx"
run_app
gone "$lib/compatdata/200"
gone "$lib/shadercache/200"
gone "$lib/common/Old Game"
exists "$lib/compatdata/100/pfx/save.dat"
exists "$lib/shadercache/100"
exists "$lib/common/Game A"
exists "$lib/compatdata/0"
exists "$lib/common/Steam Controller Configs"
logged "ROW: FALSE | Shared Proton data (may contain saves)"
logged "ROW: FALSE | Steam Controller Configs"

# ---------------------------------------------------------------------------------
new_case "installed game folders are never listed"
installed_game 100 "Game A" "Game A"
manifest "$lib" 300 "Case Game" "case game"; mkdir -p "$lib/common/Case Game"
manifest "$lib" 400 "Slash Game" "Slash Game/"; mkdir -p "$lib/common/Slash Game"
manifest "$lib" 500 "Backslash Game" 'Backslash Game\\'; mkdir -p "$lib/common/Backslash Game"
run_app --list
not_listed "common/Case Game"
not_listed "common/Slash Game"
not_listed "common/Backslash Game"
run_app
exists "$lib/common/Case Game"
exists "$lib/common/Slash Game"
exists "$lib/common/Backslash Game"

# ---------------------------------------------------------------------------------
new_case "a damaged Steam record protects the library's game folders"
installed_game 100 "Game A" "Game A"
: > "$lib/appmanifest_300.acf"     # empty, as after a crash
mkdir -p "$lib/common/Big Game" "$lib/common/Old Game"
run_app --list
not_listed "common/Big Game"
listed "game folders were not checked"
run_app
exists "$lib/common/Big Game"
exists "$lib/common/Old Game"

# ---------------------------------------------------------------------------------
new_case "removing a prefix never follows its links"
leftover 200
mkdir -p "$case_dir/precious" "$lib/compatdata/200/pfx/dosdevices"
echo keep > "$case_dir/precious/file"
ln -s "$case_dir/precious" "$lib/compatdata/200/pfx/dosdevices/z:"
ln -s "$case_dir/precious/file" "$lib/compatdata/200/pfx/link-to-file"
run_app
gone "$lib/compatdata/200"
exists "$case_dir/precious/file"

# ---------------------------------------------------------------------------------
new_case "odd folder names are ignored and run nothing"
installed_game 100 "Game A" "Game A"
mkdir -p "$case_dir/outside"
echo keep > "$case_dir/outside/file"
mkdir -p "$lib/common/Old Game"
mkdir -p "$lib/common/Q"$'\n''b[$(touch PWNED)]'
mkdir -p "$lib/common/Z"$'\n''-'$'\t''Game folder'$'\t''5'$'\t''outside'
mkdir -p "$lib/compatdata/7"$'\n''0'
run_app --list
absent "$case_dir/PWNED"
run_app
logged "CHECKLIST:"
absent "$case_dir/PWNED"
exists "$case_dir/outside/file"
exists "$lib/common/Q"$'\n''b[$(touch PWNED)]'
exists "$lib/common/Game A"
gone "$lib/common/Old Game"

# ---------------------------------------------------------------------------------
new_case "a folder name with a tab is ignored"
installed_game 100 "Game A" "Game A"
mkdir -p "$lib/common/Old Game" "$lib/common/Tab"$'\t''Name'
run_app
logged "CHECKLIST:"
exists "$lib/common/Tab"$'\t''Name'
gone "$lib/common/Old Game"

# ---------------------------------------------------------------------------------
new_case "the last check before deleting refuses anything outside the libraries"
mkdir -p "$lib/common/Old Game" "$lib/compatdata/200" "$steam/userdata" "$case_dir/elsewhere/common/x"
# Loads the app's functions without starting it, then asks the check directly.
check_path() {
    HOME="$home" USER="plc-test-user" bash -c '
        source "$1"
        find_steam
        is_removable_path "$2"' _ "$app" "$1"
}
real_lib=$(realpath "$lib")
for path in "$real_lib/common/Old Game" "$real_lib/compatdata/200"; do
    if check_path "$path"; then pass; else fail "should be allowed: $path"; fi
done
for path in "$home" "$real_lib" "$real_lib/common" "$real_lib/common/." "$real_lib/common/.." \
            "$real_lib/common/../.." "$steam/userdata" "$real_lib/userdata/x" "common/Old Game" \
            "$case_dir/elsewhere/common/x" "/" ""; do
    if check_path "$path"; then fail "should be refused: $path"; else pass; fi
done
# And the delete step itself uses that check.
HOME="$home" USER="plc-test-user" bash -c '
    source "$1"
    find_steam
    remove_folder "$2"' _ "$app" "$case_dir/elsewhere/common/x"
exists "$case_dir/elsewhere/common/x"

# ---------------------------------------------------------------------------------
new_case "non-Steam data is skipped when Steam's list is missing"
mkdir -p "$steam/userdata/1/config"
leftover 2147483700
run_app --list
not_listed "compatdata/2147483700"
run_app
exists "$lib/compatdata/2147483700"

# ---------------------------------------------------------------------------------
new_case "non-Steam data is skipped when Steam's list is damaged"
mkdir -p "$steam/userdata/1/config"
printf '\x00shortcuts\x00\x00garbage' > "$steam/userdata/1/config/shortcuts.vdf"
leftover 2147483700
run_app
exists "$lib/compatdata/2147483700"

# ---------------------------------------------------------------------------------
new_case "only removed non-Steam games are listed"
mkdir -p "$steam/userdata/1/config"
shortcuts_vdf "$steam/userdata/1/config/shortcuts.vdf" 2147483700
leftover 2147483700
leftover 2147483800
run_app --list
not_listed "compatdata/2147483700"
listed "compatdata/2147483800"
run_app
exists "$lib/compatdata/2147483700"
gone "$lib/compatdata/2147483800"

# ---------------------------------------------------------------------------------
new_case "games on an unplugged drive are not offered"
cat > "$lib/libraryfolders.vdf" <<EOF
"libraryfolders"
{
	"0"
	{
		"path"		"$steam"
		"apps"
		{
			"100"		"1000"
		}
	}
	"1"
	{
		"path"		"$case_dir/unplugged/SteamLibrary"
		"apps"
		{
			"500"		"5000"
		}
	}
	"2"
	{
		"apps"
		{
			"700"		"7000"
		}
	}
}
EOF
installed_game 100 "Game A" "Game A"
leftover 500
leftover 600
leftover 700
run_app --list
not_listed "compatdata/500"
listed "compatdata/600"
listed "unplugged/SteamLibrary"
not_listed "compatdata/700"
run_app
logged "can't be reached"
exists "$lib/compatdata/500"
exists "$lib/compatdata/700"
gone "$lib/compatdata/600"

# ---------------------------------------------------------------------------------
new_case "cancelling removes nothing"
installed_game 100 "Game A" "Game A"
leftover 200
mkdir -p "$lib/common/Old Game"
before=$(snapshot)
FAKE_ZENITY_CHECKLIST=cancel run_app
FAKE_ZENITY_QUESTION=1 run_app
FAKE_ZENITY_QUESTION=1 FAKE_ZENITY_MENU="Data of an installed game" FAKE_ZENITY_GAME=100 \
    FAKE_ZENITY_WHAT="Shader cache and Proton prefix" run_app
FAKE_ZENITY_QUESTION=1 FAKE_ZENITY_MENU="Data of an installed game" FAKE_ZENITY_GAME=100 \
    FAKE_ZENITY_WHAT="Shader cache" run_app
if [[ "$(snapshot)" == "$before" ]]; then pass; else fail "files changed after cancelling"; fi

# ---------------------------------------------------------------------------------
new_case "--list deletes nothing"
installed_game 100 "Game A" "Game A"
leftover 200
mkdir -p "$lib/common/Old Game" "$lib/compatdata/0"
before=$(snapshot)
run_app --list
listed "compatdata/200"
if [[ "$(snapshot)" == "$before" ]]; then pass; else fail "--list changed files"; fi

# ---------------------------------------------------------------------------------
new_case "Steam running: leftovers wait for a yes"
leftover 200
FAKE_STEAM_RUNNING=1 FAKE_ZENITY_QUESTION=1 run_app
logged "Steam is running"
exists "$lib/compatdata/200"

# ---------------------------------------------------------------------------------
new_case "installed game reset touches only that game"
installed_game 100 "Command & Conquer" "CnC"
installed_game 101 "Other Game" "Other"
FAKE_ZENITY_MENU="Data of an installed game" FAKE_ZENITY_GAME=100 \
    FAKE_ZENITY_WHAT="Shader cache and Proton prefix" run_app
gone "$lib/compatdata/100"
gone "$lib/shadercache/100"
exists "$lib/common/CnC"
exists "$lib/compatdata/101/pfx/save.dat"
exists "$lib/shadercache/101"
logged "Command &amp; Conquer"
not_logged "Command & Conquer"

# ---------------------------------------------------------------------------------
echo
echo "$passes checks passed, $failures failed."
(( failures == 0 ))
