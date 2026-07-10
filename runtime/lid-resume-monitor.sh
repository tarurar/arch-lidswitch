#!/bin/bash

MAX_NOTIFY_ATTEMPTS=3
NOTIFY_RETRY_DELAY=0.1
RECONNECT_DELAY=1
LOGIN1_SERVICE=org.freedesktop.login1
LOGIN1_PATH=/org/freedesktop/login1
LOGIN1_MANAGER=org.freedesktop.login1.Manager
LOGIN1_SIGNAL=PrepareForSleep

log_record() {
    local level=$1
    local event=$2
    shift 2

    printf 'level=%s component=lid-resume-monitor event=%s' "$level" "$event"
    if (( $# > 0 )); then
        printf ' %s' "$@"
    fi
    printf '\n'
}

log_info() {
    log_record info "$@"
}

log_error() {
    log_record error "$@" >&2
}

notify_main_monitor() {
    local attempt

    for ((attempt = 1; attempt <= MAX_NOTIFY_ATTEMPTS; attempt++)); do
        if systemctl --user kill --kill-whom=main --signal=USR1 \
            lid-monitor.service; then
            log_info resume_notification_succeeded attempt="$attempt"
            return 0
        fi
        log_error resume_notification_failed attempt="$attempt" status=3
        if (( attempt < MAX_NOTIFY_ATTEMPTS )); then
            sleep "$NOTIFY_RETRY_DELAY"
        fi
    done
    return 3
}

handle_prepare_for_sleep_event() {
    local event_json=$1

    case "$event_json" in
        '{"type":"b","data":[true]}')
            log_info prepare_for_sleep state=true action=none
            return 0
            ;;
        '{"type":"b","data":[false]}')
            log_info prepare_for_sleep state=false action=notify
            notify_main_monitor
            ;;
        *)
            log_error prepare_for_sleep_invalid status=2 payload="$event_json"
            return 2
            ;;
    esac
}

run_subscription() {
    local message_limit=$1
    local once_mode=$2
    local stream_fd stream_pid event_json
    local event_status=0 wait_status=0 received_event=false
    local abort_subscription=false

    coproc RESUME_EVENTS {
        exec stdbuf -oL busctl --system --json=short \
            --limit-messages="$message_limit" wait \
            "$LOGIN1_SERVICE" "$LOGIN1_PATH" "$LOGIN1_MANAGER" \
            "$LOGIN1_SIGNAL"
    }
    exec {stream_fd}<&"${RESUME_EVENTS[0]}"
    stream_pid=$RESUME_EVENTS_PID

    while IFS= read -r -u "$stream_fd" event_json 2>/dev/null; do
        received_event=true
        if handle_prepare_for_sleep_event "$event_json"; then
            :
        else
            event_status=$?
            if [[ "$once_mode" != true ]]; then
                abort_subscription=true
                break
            fi
        fi
        if [[ "$once_mode" == true ]]; then
            break
        fi
    done
    exec {stream_fd}<&-
    if [[ "$abort_subscription" == true ]]; then
        kill "$stream_pid" 2>/dev/null || true
        sleep 0.1
        kill -KILL "$stream_pid" 2>/dev/null || true
        log_error subscription_aborted status="$event_status" \
            reason=invalid_or_unhandled_event
    fi
    wait "$stream_pid" 2>/dev/null || wait_status=$?

    if (( event_status != 0 )); then
        return "$event_status"
    fi
    if (( wait_status != 0 )); then
        log_error subscription_failed status=2 busctl_status="$wait_status"
        return 2
    fi
    if [[ "$received_event" != true ]]; then
        log_error subscription_failed status=2 reason=no_event
        return 2
    fi
    if [[ "$once_mode" != true ]]; then
        log_error subscription_ended status=2 reason=unexpected_eof
        return 2
    fi
}

case "${1:-}" in
    --once)
        run_subscription 1 true
        exit $?
        ;;
    "")
        ;;
    *)
        log_error invalid_arguments status=1
        exit 1
        ;;
esac

while true; do
    run_subscription infinity false || true
    sleep "$RECONNECT_DELAY"
done
