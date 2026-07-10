#!/bin/bash

read_lid_state() {
    local lid_root="${HYPR_LID_STATE_ROOT:-/proc/acpi/button/lid}"
    local nullglob_was_enabled=0
    local state_file state_line state observed_state=""
    local -a state_files

    if shopt -q nullglob; then
        nullglob_was_enabled=1
    else
        shopt -s nullglob
    fi
    state_files=("$lid_root"/*/state)
    if (( ! nullglob_was_enabled )); then
        shopt -u nullglob
    fi

    if (( ${#state_files[@]} == 0 )); then
        printf 'No ACPI lid state files found under %s\n' "$lid_root" >&2
        printf '%s\n' unknown
        return 1
    fi

    for state_file in "${state_files[@]}"; do
        if [[ ! -f "$state_file" || ! -r "$state_file" ]] || ! state_line=$(<"$state_file"); then
            printf 'Unable to read ACPI lid state: %s\n' "$state_file" >&2
            printf '%s\n' unknown
            return 1
        fi

        if [[ "$state_line" =~ ^[[:space:]]*(state:[[:space:]]*)?(open|closed)[[:space:]]*$ ]]; then
            state="${BASH_REMATCH[2]}"
        else
            printf 'Malformed ACPI lid state: %s\n' "$state_file" >&2
            printf '%s\n' unknown
            return 1
        fi

        if [[ -z "$observed_state" ]]; then
            observed_state="$state"
        elif [[ "$state" != "$observed_state" ]]; then
            printf 'Conflicting ACPI lid states found under %s\n' "$lid_root" >&2
            printf '%s\n' unknown
            return 1
        fi
    done

    printf '%s\n' "$observed_state"
}
