#!/bin/bash

set -u

LOGIN1_SERVICE="org.freedesktop.login1"
LOGIN1_PATH="/org/freedesktop/login1"
LOGIN1_MANAGER="org.freedesktop.login1.Manager"

usage() {
    printf 'usage: %s [--policy-only]\n' "${0##*/}" >&2
}

print_remediation() {
    printf '%s\n' \
        'INFO Inspect effective policy with: systemd-analyze cat-config systemd/logind.conf' \
        'INFO Inspect lid inhibitors with: systemd-inhibit --list --what=handle-lid-switch --no-pager' \
        'INFO This installer does not modify /etc or systemd-logind policy.'
}

read_manager_string_property() {
    local property=$1
    local raw_value

    if ! raw_value=$(busctl get-property \
        "$LOGIN1_SERVICE" \
        "$LOGIN1_PATH" \
        "$LOGIN1_MANAGER" \
        "$property"); then
        printf 'ERROR Could not read effective logind property %s.\n' "$property" >&2
        return 2
    fi

    if [[ "$raw_value" =~ ^s[[:space:]]+\"([^\"]*)\"$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    printf 'ERROR Unexpected value for logind property %s: %s\n' \
        "$property" "$raw_value" >&2
    return 2
}

check_lid_power_policy() {
    local handle_lid_switch handle_lid_switch_docked
    local handle_lid_switch_external_power inhibitor_output
    local policy_status=0

    if ! handle_lid_switch=$(read_manager_string_property HandleLidSwitch); then
        print_remediation
        return 2
    fi
    if ! handle_lid_switch_docked=$(read_manager_string_property HandleLidSwitchDocked); then
        print_remediation
        return 2
    fi
    if ! handle_lid_switch_external_power=$(read_manager_string_property HandleLidSwitchExternalPower); then
        print_remediation
        return 2
    fi
    if ! inhibitor_output=$(systemd-inhibit \
        --list \
        --what=handle-lid-switch \
        --no-pager \
        --no-legend); then
        printf 'ERROR Could not inspect handle-lid-switch inhibitors.\n' >&2
        print_remediation
        return 2
    fi

    if [[ "$handle_lid_switch" != "suspend" ]]; then
        printf 'FAIL HandleLidSwitch=%s expected=suspend\n' "$handle_lid_switch"
        policy_status=1
    else
        printf 'PASS HandleLidSwitch=suspend\n'
    fi

    if [[ "$handle_lid_switch_docked" != "ignore" ]]; then
        printf 'FAIL HandleLidSwitchDocked=%s expected=ignore\n' \
            "$handle_lid_switch_docked"
        policy_status=1
    else
        printf 'PASS HandleLidSwitchDocked=ignore\n'
    fi

    case "$handle_lid_switch_external_power" in
        "")
            printf 'PASS HandleLidSwitchExternalPower=<unset> fallback=HandleLidSwitch\n'
            ;;
        suspend)
            printf 'PASS HandleLidSwitchExternalPower=suspend\n'
            ;;
        *)
            printf 'FAIL HandleLidSwitchExternalPower=%s expected=<unset-or-suspend>\n' \
                "$handle_lid_switch_external_power"
            policy_status=1
            ;;
    esac

    if [[ -n "$inhibitor_output" && "$inhibitor_output" != "No inhibitors listed." ]]; then
        printf 'FAIL handle-lid-switch inhibitor present: %s\n' "$inhibitor_output"
        policy_status=1
    else
        printf 'PASS handle-lid-switch inhibitors=none\n'
    fi

    if (( policy_status != 0 )); then
        print_remediation
    fi

    return "$policy_status"
}

case "${1:-}" in
    ""|--policy-only)
        if (( $# > 1 )); then
            usage
            exit 2
        fi
        check_lid_power_policy
        ;;
    *)
        usage
        exit 2
        ;;
esac
