#!/usr/bin/env bash
#
# Proton Leftover Cleaner
#
# Steam keeps a Proton prefix (steamapps/compatdata/<id>) and a shader cache
# (steamapps/shadercache/<id>) for every game it runs through Proton, and it
# often leaves them behind when a game is uninstalled. Files a game or mod
# created in its install folder (steamapps/common/<game>) stay behind too.
# This tool finds those leftovers and removes the ones you pick. It can also
# reset the Proton prefix and/or shader cache of a game that is still installed.
#
# This is free and unencumbered software released into the public domain.
# See the LICENSE file or <https://unlicense.org> for details.

# How the script is laid out (top to bottom):
#   1. Settings and small helpers
#   2. Reading Steam's files: where Steam and its libraries are, which games are
#      installed, game names, and which non-Steam games exist
#   3. Finding leftovers: folders that belong to no installed game
#   4. The terminal mode (--list), which only lists and never deletes
#   5. The graphical mode (zenity windows), the only place anything is deleted
#   6. Start: reads the command line options and runs one of the two modes

# A failing command anywhere in a pipe (a | b) counts as a failure.
set -o pipefail
# A pattern like "folder/*" that matches nothing expands to nothing, instead of
# staying as the literal text "folder/*" (which would look like a real folder).
shopt -s nullglob

readonly APP_NAME="Proton Leftover Cleaner"
readonly APP_VERSION="1.1.0"

# App IDs Steam gives to non-Steam games ("shortcuts") start here. They don't
# appear in any appmanifest, so they're checked against Steam's shortcut list
# instead (see read_current_shortcuts).
readonly FIRST_SHORTCUT_ID=2147483648

# Where Steam can be installed (regular package and Flatpak).
readonly STEAM_LOCATIONS=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.steam/root"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"
)

###############################################################################
# Small helpers
###############################################################################

# Prints an error message and stops the script.
die() {
    echo "$APP_NAME: $*" >&2
    exit 1
}

# "1536" -> "1.5 KB", "3221225472" -> "3.0 GB"
pretty_size() {
    numfmt --to=iec --format='%.1f' -- "${1:-0}" 2>/dev/null \
        | sed -E 's/^([0-9.]+)([KMGTPE])$/\1 \2B/; s/^([0-9.]+)$/\1 B/; s/^([0-9]+)\.0 B$/\1 B/'
}

# Total size of a folder in bytes (empty if it doesn't exist).
folder_bytes() {
    du -sb -- "$1" 2>/dev/null | cut -f1
}

# True if an App ID belongs to a non-Steam game. "10#" makes bash read IDs
# like "0123" as decimal instead of octal.
is_shortcut_id() {
    (( 10#$1 >= FIRST_SHORTCUT_ID ))
}

# Turns a path into its real location, so the same folder reached through
# different symlinks is only counted once.
real_path() {
    realpath -e -- "$1" 2>/dev/null
}

###############################################################################
# Reading Steam's own files
###############################################################################

declare -a steam_installs=()    # Steam folders found on this computer
declare -a libraries=()         # "steamapps" folders of all libraries
declare -a offline_libraries=() # libraries Steam knows about that aren't reachable
declare -A known_paths=()      # "kind:path" -> 1, so nothing is added twice

# Values of a key in a text VDF/ACF file, e.g. vdf_values path libraryfolders.vdf
# Those files are made of lines like:   "key"   "value"
# Splitting on quotes makes the key field 2 and the value field 4. Steam writes
# backslashes doubled, so they're turned back into single ones.
vdf_values() {
    awk -F'"' -v key="$1" 'tolower($2) == key { v = $4; gsub(/\\\\/, "\\", v); print v }' "$2" 2>/dev/null
}

# Adds <folder>/steamapps to the list of libraries if it exists.
# Returns failure if it doesn't, so callers can tell a library is offline.
add_library_folder() {
    local folder="$1" apps real
    apps=$(real_path "$folder/steamapps") || return 1
    [[ -d "$apps" ]] || return 1
    [[ -n "${known_paths[lib:$apps]}" ]] && return 0
    known_paths[lib:$apps]=1
    libraries+=("$apps")
}

# Fills steam_installs and libraries. Steam's own library list
# (libraryfolders.vdf) names every library, including ones on other drives.
# Libraries in that list that can't be reached go into offline_libraries, so
# the user can be warned: games installed there would look uninstalled.
find_steam() {
    local location install folder list

    for location in "${STEAM_LOCATIONS[@]}"; do
        install=$(real_path "$location") || continue
        [[ -d "$install/steamapps" || -d "$install/userdata" ]] || continue
        [[ -n "${known_paths[steam:$install]}" ]] && continue
        known_paths[steam:$install]=1
        steam_installs+=("$install")
    done

    for install in "${steam_installs[@]}"; do
        add_library_folder "$install"
        for list in "$install/steamapps/libraryfolders.vdf" "$install/config/libraryfolders.vdf"; do
            while IFS= read -r folder; do
                [[ -z "$folder" ]] && continue
                if ! add_library_folder "$folder" && [[ -z "${known_paths[offline:$folder]}" ]]; then
                    known_paths[offline:$folder]=1
                    offline_libraries+=("$folder")
                fi
            done < <(vdf_values path "$list")
        done
    done

    # Libraries on removable drives that Steam's list might not mention.
    for folder in /run/media/"$USER"/*/SteamLibrary /media/"$USER"/*/SteamLibrary; do
        add_library_folder "$folder"
    done
}

declare -A installed_name=()   # App ID -> name, for everything installed
declare -A is_game=()          # App ID -> 1 for real games (not Proton etc.)
declare -A claimed_folder=()   # steamapps/common/<folder> -> 1 if an installed app uses it
declare -A has_manifests=()    # steamapps folder -> 1 if any app is installed there

# Steam writes one appmanifest_<App ID>.acf per installed app into the library
# that holds it. These files are the single source of truth for what's
# installed: anything without one counts as uninstalled. The manifest's
# "installdir" names the app's folder in steamapps/common.
read_installed_apps() {
    local apps manifest id name installdir
    for apps in "${libraries[@]}"; do
        for manifest in "$apps"/appmanifest_*.acf; do
            id=${manifest##*/appmanifest_}
            id=${id%.acf}
            [[ "$id" =~ ^[0-9]+$ ]] || continue
            has_manifests[$apps]=1
            name=$(vdf_values name "$manifest" | head -n 1)
            installed_name[$id]="${name:-App $id}"
            while IFS= read -r installdir; do
                [[ -n "$installdir" ]] && claimed_folder[$apps/common/$installdir]=1
            done < <(vdf_values installdir "$manifest")
            # Proton versions and Steam's runtimes are installed like games, but
            # they shouldn't be offered under "Data of an installed game".
            case "$name" in
                Proton\ *|Proton-*|Steam\ Linux\ Runtime*|Steamworks\ Common\ Redistributables*|Steamworks\ Shared*) ;;
                *) is_game[$id]=1 ;;
            esac
        done
    done
}

# Python helper for Steam's binary files. Bash can't read binary data well,
# so this small Python program is embedded here and run with python3.
# If python3 is missing, names are skipped and non-Steam data is left alone.
# Commands:
#   names <appinfo.vdf> <id>...   prints "id<TAB>name" from Steam's app cache
#   shortcuts <shortcuts.vdf>...  prints the App ID of every non-Steam game
read -r -d '' STEAM_BINARY_HELPER <<'PYTHON'
import struct
import sys
import zlib


class BinaryKeyValues:
    """Reader for Valve's binary key/value format.

    Each entry is one type byte, a key, then a value. Type 0x00 starts a nested
    section, 0x01 is text, 0x02 a 32-bit number, 0x08/0x0B end a section. Other
    types are skipped because nothing here needs them.
    """

    END_MARKERS = (0x08, 0x0B)

    def __init__(self, data, offset=0, key_table=None):
        self.data = data
        self.offset = offset
        self.key_table = key_table

    def _take(self, fmt):
        value = struct.unpack_from(fmt, self.data, self.offset)[0]
        self.offset += struct.calcsize(fmt)
        return value

    def _text(self):
        end = self.data.index(b"\x00", self.offset)
        text = self.data[self.offset:end].decode("utf-8", "replace")
        self.offset = end + 1
        return text

    def _key(self):
        if self.key_table is None:
            return self._text()
        return self.key_table[self._take("<i")]

    def read_section(self):
        section = {}
        while True:
            kind = self._take("B")
            if kind in self.END_MARKERS:
                return section
            key = self._key().lower()
            if kind == 0x00:
                section[key] = self.read_section()
            elif kind == 0x01:
                section[key] = self._text()
            elif kind == 0x02:
                section[key] = self._take("<i")
            elif kind in (0x03, 0x04, 0x06):
                self.offset += 4
            elif kind in (0x07, 0x0A):
                self.offset += 8
            elif kind == 0x05:
                while self.data[self.offset:self.offset + 2] != b"\x00\x00":
                    self.offset += 2
                self.offset += 2
            else:
                raise ValueError("unknown value type %d" % kind)


def app_names(path, wanted_ids):
    """Game names from appcache/appinfo.vdf (formats 0x26-0x29)."""
    wanted = {int(i) for i in wanted_ids}
    with open(path, "rb") as f:
        data = f.read()
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic not in (0x07564426, 0x07564427, 0x07564428, 0x07564429):
        return
    offset = 8
    key_table = None
    if magic == 0x07564429:
        table_at = struct.unpack_from("<q", data, offset)[0]
        offset += 8
        count = struct.unpack_from("<I", data, table_at)[0]
        reader = BinaryKeyValues(data, table_at + 4)
        key_table = [reader._text() for _ in range(count)]
    # per app: state, last change, token, sha1, change number (+ sha1 of data)
    skip = 40 + (20 if magic >= 0x07564428 else 0)
    while wanted and offset + 8 <= len(data):
        app_id, size = struct.unpack_from("<II", data, offset)
        if app_id == 0:
            break
        entry = offset + 8
        offset = entry + size
        if app_id not in wanted:
            continue
        wanted.discard(app_id)
        try:
            info = BinaryKeyValues(data, entry + skip, key_table).read_section()
            name = info["appinfo"]["common"]["name"]
        except Exception:
            continue
        if isinstance(name, str) and name.strip():
            print("%d\t%s" % (app_id, " ".join(name.split())))


def shortcut_ids(paths):
    """App IDs of the non-Steam games listed in userdata/*/config/shortcuts.vdf."""
    for path in paths:
        with open(path, "rb") as f:
            data = f.read()
        if not data.strip(b"\x00"):
            continue
        root = BinaryKeyValues(data).read_section()
        for entry in root.get("shortcuts", {}).values():
            if not isinstance(entry, dict):
                continue
            if isinstance(entry.get("appid"), int):
                print(entry["appid"] & 0xFFFFFFFF)
            else:
                # Older Steam versions derive the ID from program and name.
                seed = (entry.get("exe", "") + entry.get("appname", "")).encode("utf-8")
                print(zlib.crc32(seed) | 0x80000000)


if __name__ == "__main__":
    command, arguments = sys.argv[1], sys.argv[2:]
    if command == "names":
        try:
            app_names(arguments[0], arguments[1:])
        except Exception:
            pass
    elif command == "shortcuts":
        shortcut_ids(arguments)  # errors make the exit code non-zero
PYTHON

# Runs the Python helper above. Fails if python3 isn't installed.
steam_binary_helper() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c "$STEAM_BINARY_HELPER" "$@" 2>/dev/null
}

declare -A game_name_cache=()  # App ID -> name, for games that aren't installed

# Looks up names of games that are no longer installed (offline, from Steam's cache).
load_names_for() {
    local cache install id name
    (( $# > 0 )) || return 0
    for install in "${steam_installs[@]}"; do
        [[ -f "$install/appcache/appinfo.vdf" ]] && { cache="$install/appcache/appinfo.vdf"; break; }
    done
    [[ -n "$cache" ]] || return 0
    while IFS=$'\t' read -r id name; do
        game_name_cache[$id]="$name"
    done < <(steam_binary_helper names "$cache" "$@")
}

declare -A current_shortcuts=() # App ID -> 1 for non-Steam games still in Steam
shortcuts_known=false            # true once that list was read successfully

# Reads which non-Steam games are currently added to Steam. If that can't be
# done reliably, shortcuts_known stays false and non-Steam data is left alone.
read_current_shortcuts() {
    local install account ids id
    local -a lists=() accounts=()
    for install in "${steam_installs[@]}"; do
        for account in "$install"/userdata/*/config; do
            accounts+=("$account")
            [[ -f "$account/shortcuts.vdf" ]] && lists+=("$account/shortcuts.vdf")
        done
    done
    (( ${#accounts[@]} > 0 )) || return 0
    if (( ${#lists[@]} > 0 )); then
        ids=$(steam_binary_helper shortcuts "${lists[@]}") || return 0
        while read -r id; do
            [[ "$id" =~ ^[0-9]+$ ]] && current_shortcuts[$id]=1
        done <<< "$ids"
    fi
    shortcuts_known=true
}

###############################################################################
# Finding leftovers
###############################################################################

# The rules for what counts as a leftover:
#   - compatdata/<id> and shadercache/<id>: leftover if no installed app has
#     that App ID.
#   - ID 0: Proton sometimes creates compatdata/0 and shadercache/0. They
#     belong to no game, so they're always listed (compatdata/0 unticked,
#     since non-Steam games can keep saves there).
#   - Non-Steam game IDs: leftover only if the game was removed from Steam.
#     If Steam's shortcut list couldn't be read, they're never listed.
#   - steamapps/common/<folder>: leftover if no installed app's appmanifest
#     names it as its "installdir".
#
# Prints one line per leftover folder:
#   <App ID> TAB <"Proton prefix"|"Shader cache"|"Game folder"> TAB <bytes> TAB <path>
# Game folders have no App ID; theirs is "-".
find_leftovers() {
    local apps type folder id
    for apps in "${libraries[@]}"; do
        for type in compatdata shadercache; do
            for folder in "$apps/$type"/*/; do
                folder=${folder%/}
                id=${folder##*/}
                [[ "$id" =~ ^[0-9]+$ ]] || continue
                id=$((10#$id))   # "0042" -> 42
                if (( id == 0 )); then
                    :   # Proton data that belongs to no game at all
                elif is_shortcut_id "$id"; then
                    [[ "$shortcuts_known" == true ]] || continue
                    [[ -n "${current_shortcuts[$id]}" ]] && continue
                else
                    [[ -n "${installed_name[$id]}" ]] && continue
                fi
                printf '%s\t%s\t%s\t%s\n' "$id" \
                    "$([[ $type == compatdata ]] && echo "Proton prefix" || echo "Shader cache")" \
                    "$(folder_bytes "$folder")" "$folder"
            done
        done

        # Install folders no installed game uses anymore. A library without a
        # single installed app is skipped, in case Steam's files there can't be read.
        [[ -n "${has_manifests[$apps]}" ]] || continue
        for folder in "$apps/common"/*/; do
            folder=${folder%/}
            [[ -n "${claimed_folder[$folder]}" ]] && continue
            printf '%s\t%s\t%s\t%s\n' "-" "Game folder" "$(folder_bytes "$folder")" "$folder"
        done
    done
}

# The name shown for a leftover in the list.
leftover_title() {
    local id="$1" type="$2" folder="$3"
    if [[ "$type" == "Game folder" ]]; then
        echo "${folder##*/}"
    elif (( id == 0 )) && [[ "$type" == "Proton prefix" ]]; then
        echo "Shared Proton data (may contain saves)"
    elif (( id == 0 )); then
        echo "Proton data without a game"
    elif is_shortcut_id "$id"; then
        echo "Removed non-Steam game"
    else
        echo "${game_name_cache[$id]:-Unknown game}"
    fi
}

# Adds names to find_leftovers output and sorts it by name:
#   <name> TAB <App ID> TAB <type> TAB <bytes> TAB <path>
named_leftovers() {
    local list="$1" id type bytes folder
    load_names_for $(cut -f1 "$list" | sort -un | awk -v max="$FIRST_SHORTCUT_ID" '$1 ~ /^[0-9]+$/ && $1 > 0 && $1 < max')
    while IFS=$'\t' read -r id type bytes folder; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$(leftover_title "$id" "$type" "$folder")" "$id" "$type" "${bytes:-0}" "$folder"
    done < "$list" | sort -f -t $'\t' -k1,1 -k2,2n -k3,3
}

###############################################################################
# Command line mode: --list
###############################################################################

# --list: prints every leftover with its size and path. Deletes nothing.
list_in_terminal() {
    local list name id type bytes folder total=0 count=0
    list=$(mktemp) || die "could not create a temporary file"
    find_leftovers > "$list"
    if [[ ! -s "$list" ]]; then
        echo "No leftovers found."
        rm -f -- "$list"
        return 0
    fi
    while IFS=$'\t' read -r name id type bytes folder; do
        printf '%10s  %-13s  %-10s  %s\n            %s\n' "$(pretty_size "$bytes")" "$type" "$id" "$name" "$folder"
        total=$((total + bytes))
        count=$((count + 1))
    done < <(named_leftovers "$list")
    rm -f -- "$list"
    echo
    echo "$count leftover folder(s), $(pretty_size "$total") in total. Nothing was deleted."
    if [[ "$shortcuts_known" != true ]]; then
        echo "Note: Steam's list of non-Steam games could not be read, so their data was skipped."
    fi
    if (( ${#offline_libraries[@]} > 0 )); then
        echo "Note: these Steam libraries are not reachable right now:"
        printf '  %s\n' "${offline_libraries[@]}"
    fi
}

###############################################################################
# Graphical mode (zenity)
###############################################################################

# Hide zenity's harmless GTK layout warnings, keep everything else.
# This function has the same name as the zenity program, so every "zenity"
# below goes through it. "command zenity" skips the function and runs the real
# program; without "command" it would call itself forever.
zenity() {
    command zenity "$@" 2> >(grep -Ev '^\(zenity:[0-9]+\): [A-Za-z]+-WARNING \*\*|^$' >&2)
}

# Shortcuts for the three kinds of message windows.
notice() { zenity --info --title="$APP_NAME" --width=420 --text="$1"; }
problem() { zenity --error --title="$APP_NAME" --width=480 --text="$1"; }
ask() {  # ask "<text>" "<yes button>"
    zenity --question --title="$APP_NAME" --width=460 --ok-label="$2" --cancel-label="Cancel" --text="$1"
}

# Folders that couldn't be deleted (for example because of permissions).
declare -a not_removed=()

# Deletes a folder permanently (no trash). Failures are collected in not_removed.
remove_folder() {
    [[ -d "$1" ]] || return 1
    rm -rf -- "$1" && return 0
    not_removed+=("$1")
    return 1
}

report_not_removed() {
    problem "These folders could not be removed:\n\n$(printf '%s\n' "${not_removed[@]}")"
}

# True if Steam is open (pgrep -x looks for a process named exactly "steam").
steam_is_running() {
    pgrep -x steam >/dev/null 2>&1
}

# "Leftovers of uninstalled games": scan, show a checklist, ask once more,
# then delete what was picked. Rows are numbered (hidden column "n") so the
# checklist answer can be matched back to paths[], sizes[] and types[].
clean_leftovers_gui() {
    local workdir="$1" list="$1/leftovers"

    if (( ${#offline_libraries[@]} > 0 )); then
        ask "Steam knows about libraries that can't be reached right now:\n\n$(printf '%s\n' "${offline_libraries[@]}")\n\nGames installed there would look uninstalled, so their data could show up as leftovers. Connect the drive first if you can." \
            "Scan anyway" || return 0
    fi

    {
        echo "# Scanning Steam libraries…"
        find_leftovers > "$list"
    } | zenity --progress --pulsate --auto-close --no-cancel \
            --title="$APP_NAME" --text="Scanning Steam libraries…" --width=420

    if [[ ! -s "$list" ]]; then
        notice "Nothing to clean up.\n\nNo leftovers from uninstalled games were found."
        return 0
    fi

    local -a rows=() paths=() sizes=() types=()
    local name id type bytes folder total=0 n=0 tick
    while IFS=$'\t' read -r name id type bytes folder; do
        # compatdata/0 can hold saves of non-Steam games, so it's only removed when picked.
        tick=TRUE
        [[ "$type" == "Proton prefix" ]] && (( id == 0 )) && tick=FALSE
        rows+=("$tick" "$name" "$id" "$type" "$(pretty_size "$bytes")" "$n")
        paths+=("$folder")
        sizes+=("$bytes")
        types+=("$type")
        total=$((total + bytes))
        n=$((n + 1))
    done < <(named_leftovers "$list")

    local picked
    picked=$(zenity --list --checklist \
        --title="Leftovers found" \
        --text="$n item(s), $(pretty_size "$total") in total.\nEverything except shared Proton data is selected — untick what you want to keep." \
        --column="Remove" --column="Game" --column="App ID" --column="Data" --column="Size" --column="n" \
        --hide-column=6 --print-column=6 --separator=" " \
        --width=720 --height=620 \
        "${rows[@]}") || return 0

    local -a chosen=()
    local i selected_bytes=0 prefixes=0 shortcut_prefixes=0 shared_prefix=0 game_folders=0
    for i in $picked; do
        [[ "$i" =~ ^[0-9]+$ && -n "${paths[$i]}" ]] || continue
        chosen+=("$i")
        selected_bytes=$((selected_bytes + sizes[i]))
        if [[ "${types[$i]}" == "Game folder" ]]; then
            game_folders=$((game_folders + 1))
        elif [[ "${paths[$i]}" == */compatdata/* ]]; then
            if [[ "${paths[$i]##*/}" =~ ^0+$ ]]; then
                shared_prefix=1
            elif is_shortcut_id "${paths[$i]##*/}"; then
                shortcut_prefixes=$((shortcut_prefixes + 1))
            else
                prefixes=$((prefixes + 1))
            fi
        fi
    done
    if (( ${#chosen[@]} == 0 )); then
        notice "Nothing was selected, so nothing was removed."
        return 0
    fi

    local message="Remove ${#chosen[@]} item(s) and free $(pretty_size "$selected_bytes")?"
    (( prefixes > 0 )) && message+="\n\n$prefixes Proton prefix(es) selected. Games often keep save files there; saves that aren't in Steam Cloud will be gone for good."
    (( shortcut_prefixes > 0 )) && message+="\n\n$shortcut_prefixes prefix(es) of removed non-Steam games selected. If a game was installed inside its prefix, the game itself is removed too."
    (( game_folders > 0 )) && message+="\n\n$game_folders game folder(s) selected. These hold what was added after installing, like mods, mod settings or logs, and sometimes saves."
    (( shared_prefix > 0 )) && message+="\n\nShared Proton data (compatdata/0) selected. It can hold save files of non-Steam games; those will be gone for good."
    ask "$message" "Remove" || return 0

    local freed=0
    for i in "${chosen[@]}"; do
        remove_folder "${paths[$i]}" && freed=$((freed + sizes[i]))
    done

    if (( ${#not_removed[@]} > 0 )); then
        report_not_removed
    else
        notice "Done. $(pretty_size "$freed") freed."
    fi
}

# "Data of an installed game": pick a game, then remove its shader cache,
# its Proton prefix, or both. Steam recreates them on the next launch.
clean_installed_game_gui() {
    local workdir="$1" sizes_file="$1/sizes"
    local id

    if (( ${#is_game[@]} == 0 )); then
        problem "No installed Steam games were found."
        return 0
    fi

    # Size of each game's Proton prefix + shader cache.
    {
        echo "# Measuring game data…"
        for id in "${!is_game[@]}"; do
            local apps bytes=0 b
            for apps in "${libraries[@]}"; do
                for b in "$(folder_bytes "$apps/compatdata/$id")" "$(folder_bytes "$apps/shadercache/$id")"; do
                    bytes=$((bytes + ${b:-0}))
                done
            done
            printf '%s\t%s\n' "$id" "$bytes" >> "$sizes_file"
        done
    } | zenity --progress --pulsate --auto-close --no-cancel \
            --title="$APP_NAME" --text="Measuring game data…" --width=420

    local -a rows=()
    local name bytes
    while IFS=$'\t' read -r name id bytes; do
        rows+=("$name" "$id" "$(pretty_size "$bytes")")
    done < <(while IFS=$'\t' read -r id bytes; do
                 printf '%s\t%s\t%s\n' "${installed_name[$id]}" "$id" "$bytes"
             done < "$sizes_file" | sort -f -t $'\t' -k1,1)

    id=$(zenity --list \
        --title="Installed games" \
        --text="Pick the game whose Proton data you want to reset:" \
        --column="Game" --column="App ID" --column="Proton data" \
        --print-column=2 --width=560 --height=680 \
        "${rows[@]}") || return 0
    id=${id%%|*}
    [[ "$id" =~ ^[0-9]+$ && -n "${is_game[$id]}" ]] || return 0
    name="${installed_name[$id]}"

    local what
    what=$(zenity --list \
        --title="$name" \
        --text="What should be removed? Steam recreates it the next time the game starts." \
        --column="Remove" --width=460 --height=280 \
        "Shader cache" \
        "Proton prefix (may contain saves)" \
        "Shader cache and Proton prefix") || return 0
    what=${what%%|*}
    [[ -n "$what" ]] || return 0

    if steam_is_running; then
        ask "Steam is running.\n\nMake sure $name is closed before you continue." "Continue" || return 0
    fi
    if [[ "$what" == *"Proton prefix"* ]]; then
        ask "The Proton prefix holds the game's Windows environment and settings, and often its save files. Saves that aren't in Steam Cloud will be gone for good.\n\nRemove the Proton prefix of $name?" \
            "Remove" || return 0
    fi

    local apps removed_prefix=false removed_cache=false
    for apps in "${libraries[@]}"; do
        if [[ "$what" == "Shader cache"* ]]; then
            remove_folder "$apps/shadercache/$id" && removed_cache=true
        fi
        if [[ "$what" == *"Proton prefix"* ]]; then
            remove_folder "$apps/compatdata/$id" && removed_prefix=true
        fi
    done

    if (( ${#not_removed[@]} > 0 )); then
        report_not_removed
    elif [[ $removed_prefix == true && $removed_cache == true ]]; then
        notice "Removed the shader cache and Proton prefix of $name."
    elif [[ $removed_cache == true ]]; then
        notice "Removed the shader cache of $name."
    elif [[ $removed_prefix == true ]]; then
        notice "Removed the Proton prefix of $name."
    else
        notice "$name has no shader cache or Proton prefix to remove."
    fi
}

# The main window. A temporary folder holds scan results while the app runs;
# the "trap ... EXIT" line deletes it again when the script ends.
run_gui() {
    type -P zenity >/dev/null || {   # (type -P: the real program, not the wrapper above)
        command -v notify-send >/dev/null 2>&1 && notify-send "$APP_NAME" "Please install zenity to use $APP_NAME."
        die "zenity is needed for the graphical interface. Install it, or use --list in a terminal."
    }

    if (( ${#libraries[@]} == 0 )); then
        problem "No Steam library was found on this computer."
        exit 1
    fi

    local workdir choice
    workdir=$(mktemp -d) || die "could not create a temporary folder"
    trap "rm -rf -- '$workdir'" EXIT

    choice=$(zenity --list \
        --title="$APP_NAME" \
        --text="What would you like to clean up?" \
        --column="Task" --width=440 --height=260 \
        "Leftovers of uninstalled games" \
        "Data of an installed game") || return 0

    case "${choice%%|*}" in
        "Leftovers of uninstalled games") clean_leftovers_gui "$workdir" ;;
        "Data of an installed game")      clean_installed_game_gui "$workdir" ;;
    esac
}

###############################################################################
# Start
###############################################################################

case "${1:-}" in
    -h|--help)
        cat <<EOF
$APP_NAME $APP_VERSION
Finds and removes Proton prefixes, shader caches and game folders left behind by Steam games.

Usage: ${0##*/} [option]

  (no option)   open the graphical interface (needs zenity)
  --list        list leftovers in the terminal without deleting anything
  --version     show the version
  --help        show this help
EOF
        exit 0 ;;
    --version)
        echo "$APP_NAME $APP_VERSION"
        exit 0 ;;
    --list|"") ;;
    *)
        die "unknown option '$1' (see --help)" ;;
esac

# Both modes need the same information first: where Steam and its libraries
# are, which apps are installed, and which non-Steam games exist.
find_steam
read_installed_apps
read_current_shortcuts

if [[ "${1:-}" == "--list" ]]; then
    (( ${#libraries[@]} > 0 )) || die "no Steam library was found on this computer"
    list_in_terminal
else
    run_gui
fi
