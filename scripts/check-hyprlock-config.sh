#!/usr/bin/env bash

set -uo pipefail

usage() {
    printf 'Usage: %s HYPRIDLE_CONFIG HYPRLAND_LUA_CONFIG\n' "${0##*/}" >&2
}

if (( $# != 2 )); then
    usage
    exit 2
fi

hypridle_config=$1
hyprland_config=$2

for config in "$hypridle_config" "$hyprland_config"; do
    if [[ ! -f "$config" || ! -r "$config" ]]; then
        printf 'Config must be a readable regular file: %s\n' "$config" >&2
        exit 2
    fi
done

violations=0

if ! awk -v source="$hypridle_config" '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }

    function assignment_value(line, value) {
        value = line
        sub(/^[^=]*=/, "", value)
        return trim(value)
    }

    function assignment_key(line, key) {
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        return trim(key)
    }

    function has_hyprlock(value) {
        return value ~ /(^|[^[:alnum:]_])hyprlock([^[:alnum:]_]|$)/
    }

    function report(line_number, message) {
        printf "%s:%s: %s\n", source, line_number, message > "/dev/stderr"
        bad = 1
    }

    {
        config_line = $0
        sub(/[[:space:]]+#.*/, "", config_line)
        config_line = trim(config_line)

        if (config_line == "" || config_line ~ /^#/) {
            next
        }

        if (config_line ~ /^[[:alnum:]_-]+[[:space:]]*[{][[:space:]]*$/) {
            section = config_line
            sub(/[[:space:]]*[{].*$/, "", section)
            next
        }

        if (config_line ~ /^[}][[:space:]]*$/) {
            section = ""
            next
        }

        if (config_line !~ /=/) {
            next
        }

        key = assignment_key(config_line)
        value = assignment_value(config_line)

        if (key == "lock_cmd") {
            if (section != "general") {
                report(NR, "lock_cmd must be inside general")
            } else {
                lock_commands++
                if (value != "pidof hyprlock || hyprlock") {
                    report(NR, "unguarded lock_cmd: expected \"pidof hyprlock || hyprlock\"")
                }
            }
            next
        }

        if (key == "unlock_cmd") {
            if (section == "general" && has_hyprlock(value)) {
                if (value ~ /^([^[:space:]]*[/])?(kill|killall|pkill)([[:space:]]|$)/) {
                    report(NR, "unlock_cmd terminates hyprlock")
                } else if (value ~ /^([^[:space:]]*[/])?systemctl([[:space:]]|$)/ &&
                           value ~ /(^|[[:space:]])(stop|kill|restart|try-restart)([[:space:]]|$)/) {
                    report(NR, "unlock_cmd controls hyprlock directly")
                } else {
                    report(NR, "unclassified hyprlock reference requires manual review: unlock_cmd")
                }
            }
            next
        }

        if (key == "before_sleep_cmd") {
            if (section != "general") {
                report(NR, "before_sleep_cmd must be inside general")
            } else {
                before_sleep_commands++
                if (value == "hyprlock") {
                    report(NR, "before_sleep_cmd launches hyprlock directly")
                } else if (value != "loginctl lock-session") {
                    report(NR, "before_sleep_cmd: expected \"loginctl lock-session\"")
                }
            }
            next
        }

        if ((section == "general" && key ~ /_cmd$/) ||
            (section == "listener" && (key == "on-timeout" || key == "on-resume"))) {
            if (value == "hyprlock") {
                report(NR, "competing hyprlock launcher: " key)
            } else if (has_hyprlock(value)) {
                report(NR, "unclassified hyprlock reference requires manual review: " key)
            }
        }
    }

    END {
        if (lock_commands == 0) {
            report("-", "missing lock_cmd: expected \"pidof hyprlock || hyprlock\"")
        } else if (lock_commands > 1) {
            report("-", "multiple lock_cmd assignments: expected exactly one")
        }

        if (before_sleep_commands == 0) {
            report("-", "missing before_sleep_cmd: expected \"loginctl lock-session\"")
        } else if (before_sleep_commands > 1) {
            report("-", "multiple before_sleep_cmd assignments: expected exactly one")
        }

        exit bad
    }
' < "$hypridle_config"; then
    violations=1
fi

if ! awk -v source="$hyprland_config" '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }

    function long_open_length(line, position, character, offset) {
        if (substr(line, position, 1) != "[") {
            return 0
        }

        for (offset = 1; position + offset <= length(line); offset++) {
            character = substr(line, position + offset, 1)
            if (character == "[") {
                return offset + 1
            }
            if (character != "=") {
                return 0
            }
        }

        return 0
    }

    function long_close(opening, equals) {
        equals = substr(opening, 2, length(opening) - 2)
        return "]" equals "]"
    }

    function has_hyprlock(value) {
        return value ~ /(^|[^[:alnum:]_])hyprlock([^[:alnum:]_]|$)/
    }

    function exec_call_count(line, count) {
        while (match(line, /exec_cmd[[:space:]]*[(]/)) {
            count++
            line = substr(line, RSTART + RLENGTH)
        }
        return count
    }

    function is_bare_hyprlock_call(line, normalized) {
        normalized = line
        gsub(/[[:space:]]/, "", normalized)
        return index(normalized, "exec_cmd(\"hyprlock\")") != 0 ||
               index(normalized, "exec_cmd(\047hyprlock\047)") != 0
    }

    function active_code(line, character, position, quoted, escaped, result, pair,
                         opening_length, opening, closing_length) {
        result = ""

        for (position = 1; position <= length(line); position++) {
            pair = substr(line, position, 2)

            if (lua_block_comment_close != "") {
                closing_length = length(lua_block_comment_close)
                if (substr(line, position, closing_length) == lua_block_comment_close) {
                    position += closing_length - 1
                    lua_block_comment_close = ""
                }
                continue
            }

            if (lua_long_string_close != "") {
                closing_length = length(lua_long_string_close)
                if (substr(line, position, closing_length) == lua_long_string_close) {
                    result = result lua_long_string_close
                    position += closing_length - 1
                    lua_long_string_close = ""
                } else {
                    result = result substr(line, position, 1)
                }
                continue
            }

            character = substr(line, position, 1)
            if (quoted != "") {
                result = result character
                if (escaped) {
                    escaped = 0
                } else if (character == "\\") {
                    escaped = 1
                } else if (character == quoted) {
                    quoted = ""
                }
            } else if (pair == "--") {
                opening_length = long_open_length(line, position + 2)
                if (opening_length == 0) {
                    return result
                }
                opening = substr(line, position + 2, opening_length)
                lua_block_comment_close = long_close(opening)
                position += opening_length + 1
            } else {
                opening_length = long_open_length(line, position)
                if (opening_length != 0) {
                    opening = substr(line, position, opening_length)
                    result = result opening
                    lua_long_string_close = long_close(opening)
                    position += opening_length - 1
                } else {
                    result = result character
                    if (character == "\"" || character == "\047") {
                        quoted = character
                    }
                }
            }
        }

        return result
    }

    function report(line_number, message) {
        printf "%s:%s: %s\n", source, line_number, message > "/dev/stderr"
        bad = 1
    }

    {
        config_line = active_code($0)
        config_line = trim(config_line)

        if (config_line == "") {
            next
        }

        if (config_line ~ /hl[[:space:]]*[.][[:space:]]*bind[[:space:]]*[(]/) {
            exec_calls = exec_call_count(config_line)
            if (exec_calls > 1) {
                report(NR, "multiple exec_cmd calls on one line are unsupported")
            } else if (exec_calls == 1 && is_bare_hyprlock_call(config_line)) {
                report(NR, "competing hyprlock launcher: Lua keybind")
            } else if (exec_calls == 1 && has_hyprlock(config_line)) {
                report(NR, "unclassified hyprlock reference requires manual review: Lua keybind")
            }
        }
    }

    END {
        exit bad
    }
' < "$hyprland_config"; then
    violations=1
fi

if (( violations != 0 )); then
    exit 1
fi

printf 'ok: guarded lock_cmd and pre-sleep request; no checked competing launcher\n'
