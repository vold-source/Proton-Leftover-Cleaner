#!/usr/bin/env bash
#
# Proton Leftover Cleaner
#
# Steam keeps a Proton prefix (steamapps/compatdata/<id>) and a shader cache
# (steamapps/shadercache/<id>) for every game it runs through Proton, and it
# often leaves them behind when a game is uninstalled. This tool finds those
# leftovers and removes the ones you pick. It can also reset the Proton prefix
# and/or shader cache of a game that is still installed.
#
# This is free and unencumbered software released into the public domain.
# See the LICENSE file or <https://unlicense.org> for details.

set -o pipefail
shopt -s nullglob

readonly APP_NAME="Proton Leftover Cleaner"
readonly APP_VERSION="1.0.0"

# App IDs Steam gives to non-Steam games ("shortcuts") start here.
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

die() {
    echo "$APP_NAME: $*" >&2
    exit 1
}

# "1536" -> "1.5 KB", "3221225472" -> "3.0 GB"
pretty_size() {
    numfmt --to=iec --format='%.1f' -- "${1:-0}" 2>/dev/null \
        | sed -E 's/^([0-9.]+)([KMGTPE])$/\1 \2B/; s/^([0-9.]+)$/\1 B/; s/^([0-9]+)\.0 B$/\1 B/'
}

folder_bytes() {
    du -sb -- "$1" 2>/dev/null | cut -f1
}

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
declare -A known_paths=()

# Values of a key in a text VDF/ACF file, e.g. vdf_values path libraryfolders.vdf
vdf_values() {
    awk -F'"' -v key="$1" 'tolower($2) == key { v = $4; gsub(/\\\\/, "\\", v); print v }' "$2" 2>/dev/null
}

add_library_folder() {
    local folder="$1" apps real
    apps=$(real_path "$folder/steamapps") || return 1
    [[ -d "$apps" ]] || return 1
    [[ -n "${known_paths[lib:$apps]}" ]] && return 0
    known_paths[lib:$apps]=1
    libraries+=("$apps")
}

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

read_installed_apps() {
    local apps manifest id name
    for apps in "${libraries[@]}"; do
        for manifest in "$apps"/appmanifest_*.acf; do
            id=${manifest##*/appmanifest_}
            id=${id%.acf}
            [[ "$id" =~ ^[0-9]+$ ]] || continue
            name=$(vdf_values name "$manifest" | head -n 1)
            installed_name[$id]="${name:-App $id}"
            case "$name" in
                Proton\ *|Proton-*|Steam\ Linux\ Runtime*|Steamworks\ Common\ Redistributables*|Steamworks\ Shared*) ;;
                *) is_game[$id]=1 ;;
            esac
        done
    done
}

# Python helper for Steam's binary files. Commands:
#   names <appinfo.vdf> <id>...   prints "id<TAB>name" from Steam's app cache
#   shortcuts <shortcuts.vdf>...  prints the App ID of every non-Steam game
read -r -d '' STEAM_BINARY_HELPER <<'PYTHON'
import struct
import sys
import zlib


class BinaryKeyValues:
    """Reader for Valve's binary key/value format."""

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

steam_binary_helper() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c "$STEAM_BINARY_HELPER" "$@" 2>/dev/null
}

declare -A game_name_cache=()

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

declare -A current_shortcuts=()
shortcuts_known=false

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

# Prints one line per leftover folder:
#   <App ID> TAB <"Proton prefix"|"Shader cache"> TAB <bytes> TAB <path>
find_leftovers() {
    local apps type folder id
    for apps in "${libraries[@]}"; do
        for type in compatdata shadercache; do
            for folder in "$apps/$type"/*/; do
                folder=${folder%/}
                id=${folder##*/}
                [[ "$id" =~ ^[0-9]+$ ]] || continue
                id=$((10#$id))
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
    done
}

leftover_title() {
    local id="$1"
    if (( id == 0 )); then
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
    load_names_for $(cut -f1 "$list" | sort -un | awk -v max="$FIRST_SHORTCUT_ID" '$1 > 0 && $1 < max')
    while IFS=$'\t' read -r id type bytes folder; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$(leftover_title "$id")" "$id" "$type" "${bytes:-0}" "$folder"
    done < "$list" | sort -f -t $'\t' -k1,1 -k2,2n -k3,3
}

###############################################################################
# Command line mode: --list
###############################################################################

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
zenity() {
    command zenity "$@" 2> >(grep -Ev '^\(zenity:[0-9]+\): [A-Za-z]+-WARNING \*\*|^$' >&2)
}

notice() { zenity --info --title="$APP_NAME" --width=420 --text="$1"; }
problem() { zenity --error --title="$APP_NAME" --width=480 --text="$1"; }
ask() {  # ask "<text>" "<yes button>"
    zenity --question --title="$APP_NAME" --width=460 --ok-label="$2" --cancel-label="Cancel" --text="$1"
}

declare -a not_removed=()

remove_folder() {
    [[ -d "$1" ]] || return 1
    rm -rf -- "$1" && return 0
    not_removed+=("$1")
    return 1
}

report_not_removed() {
    problem "These folders could not be removed:\n\n$(printf '%s\n' "${not_removed[@]}")"
}

steam_is_running() {
    pgrep -x steam >/dev/null 2>&1
}

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

    local -a rows=() paths=() sizes=()
    local name id type bytes folder total=0 n=0
    while IFS=$'\t' read -r name id type bytes folder; do
        rows+=(TRUE "$name" "$id" "$type" "$(pretty_size "$bytes")" "$n")
        paths+=("$folder")
        sizes+=("$bytes")
        total=$((total + bytes))
        n=$((n + 1))
    done < <(named_leftovers "$list")

    local picked
    picked=$(zenity --list --checklist \
        --title="Leftovers found" \
        --text="$n item(s), $(pretty_size "$total") in total.\nEverything is selected — untick what you want to keep." \
        --column="Remove" --column="Game" --column="App ID" --column="Data" --column="Size" --column="n" \
        --hide-column=6 --print-column=6 --separator=" " \
        --width=720 --height=620 \
        "${rows[@]}") || return 0

    local -a chosen=()
    local i selected_bytes=0 prefixes=0 shortcut_prefixes=0
    for i in $picked; do
        [[ "$i" =~ ^[0-9]+$ && -n "${paths[$i]}" ]] || continue
        chosen+=("$i")
        selected_bytes=$((selected_bytes + sizes[i]))
        if [[ "${paths[$i]}" == */compatdata/* ]]; then
            if is_shortcut_id "${paths[$i]##*/}"; then
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
Finds and removes Proton prefixes and shader caches left behind by Steam games.

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

find_steam
read_installed_apps
read_current_shortcuts

if [[ "${1:-}" == "--list" ]]; then
    (( ${#libraries[@]} > 0 )) || die "no Steam library was found on this computer"
    list_in_terminal
else
    run_gui
fi
