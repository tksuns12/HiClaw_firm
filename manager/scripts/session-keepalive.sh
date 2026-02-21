#!/bin/bash
# session-keepalive.sh - Matrix room session keepalive management
#
# OpenClaw resets group room sessions after 2 days (2880 minutes) of inactivity
# (configured in openclaw.json: session.resetByType.group.idleMinutes = 2880).
# DM sessions reset daily at 04:00 (resetByType.dm).
#
# Each day at 10:00, the Manager notifies the Human Admin about active group rooms
# and asks which ones to keep alive. The Human Admin's preferences are stored in
# a prefs file for daily reuse.
#
# Usage:
#   session-keepalive.sh --action list-rooms
#   session-keepalive.sh --action load-prefs
#   session-keepalive.sh --action mark-notified
#   session-keepalive.sh --action save-prefs --rooms "!id1:domain !id2:domain ..."
#   session-keepalive.sh --action apply-prefs
#   session-keepalive.sh --action keepalive --room <room_id>

set -euo pipefail

MATRIX_URL="http://127.0.0.1:6167"
MATRIX_TOKEN="${MANAGER_MATRIX_TOKEN:-}"

REGISTRY_FILE="${HOME}/manager-workspace/workers-registry.json"
LIFECYCLE_FILE="${HOME}/manager-workspace/worker-lifecycle.json"
LIFECYCLE_SCRIPT="/opt/hiclaw/agent/skills/worker-management/scripts/lifecycle-worker.sh"
PREFS_FILE="${HOME}/manager-workspace/session-keepalive-prefs.json"

_log() {
    echo "[session-keepalive $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

_matrix_get() {
    curl -s -H "Authorization: Bearer ${MATRIX_TOKEN}" "${MATRIX_URL}$1"
}

_matrix_send() {
    local room_id="$1"
    local body="$2"
    local encoded_room
    encoded_room=$(echo "$room_id" | sed 's/!/%21/g; s/:/%3A/g')
    local txn_id="keepalive-$(date -u +%s)-$$"
    local payload
    payload=$(jq -n --arg b "$body" '{"msgtype":"m.text","body":$b}')
    curl -s -X PUT \
        -H "Authorization: Bearer ${MATRIX_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${MATRIX_URL}/_matrix/client/v3/rooms/${encoded_room}/send/m.room.message/${txn_id}"
}

# Get joined member user IDs for a room (newline-separated)
_room_members() {
    local room_id="$1"
    local encoded
    encoded=$(echo "$room_id" | sed 's/!/%21/g; s/:/%3A/g')
    _matrix_get "/_matrix/client/v3/rooms/${encoded}/members?membership=join" | \
        jq -r '.chunk[].state_key' 2>/dev/null
}

# Look up worker name from Matrix user ID; empty if not a worker
_worker_from_matrix_id() {
    [ -f "$REGISTRY_FILE" ] || return
    jq -r --arg id "$1" \
        '.workers | to_entries[] | select(.value.matrix_user_id == $id) | .key' \
        "$REGISTRY_FILE" 2>/dev/null
}

# Emit all known active group room IDs as TSV: <room_id>\t<type>\t<name>
# type is "worker" or "project"
_collect_rooms() {
    if [ -f "$REGISTRY_FILE" ]; then
        jq -r '.workers | to_entries[] | "\(.value.room_id)\tworker\t\(.key)"' \
            "$REGISTRY_FILE" 2>/dev/null
    fi
    for meta in "${HOME}/hiclaw-fs/shared/projects"/*/meta.json; do
        [ -f "$meta" ] || continue
        local status room_id name
        status=$(jq -r '.status // empty' "$meta" 2>/dev/null)
        room_id=$(jq -r '.room_id // empty' "$meta" 2>/dev/null)
        name=$(jq -r '.title // .name // empty' "$meta" 2>/dev/null)
        [ "$status" = "active" ] && [ -n "$room_id" ] || continue
        printf '%s\tproject\t%s\n' "$room_id" "${name:-unknown}"
    done
}

# ─── Actions ─────────────────────────────────────────────────────────────────

# list-rooms: output all active group rooms as ROOM: lines
action_list_rooms() {
    while IFS=$'\t' read -r room_id room_type room_name; do
        [ -n "$room_id" ] || continue
        printf 'ROOM: %s\t%s\t%s\n' "$room_id" "$room_type" "$room_name"
    done < <(_collect_rooms)
}

# load-prefs: read preferences file and output structured lines
action_load_prefs() {
    local today
    today=$(date '+%Y-%m-%d')

    if [ ! -f "$PREFS_FILE" ]; then
        echo "PREFS_DATE: "
        echo "PREFS_APPLIED: no"
        return 0
    fi

    local prefs_date applied_at
    prefs_date=$(jq -r '.date // ""' "$PREFS_FILE" 2>/dev/null)
    applied_at=$(jq -r '.applied_at // ""' "$PREFS_FILE" 2>/dev/null)

    echo "PREFS_DATE: ${prefs_date}"
    if [ -n "$applied_at" ] && [ "$prefs_date" = "$today" ]; then
        echo "PREFS_APPLIED: yes"
    else
        echo "PREFS_APPLIED: no"
    fi

    # Output each selected room as a PREFS_ROOM line
    # We match against live room data to get type and name
    local selected_rooms
    selected_rooms=$(jq -r '.selected_rooms[]? // empty' "$PREFS_FILE" 2>/dev/null)
    if [ -z "$selected_rooms" ]; then
        return 0
    fi

    # Build a lookup of room_id -> type\tname from live data
    while IFS= read -r room_id; do
        [ -n "$room_id" ] || continue
        # Try to find type and name from live registry
        local found_type="" found_name=""
        if [ -f "$REGISTRY_FILE" ]; then
            local worker_entry
            worker_entry=$(jq -r --arg rid "$room_id" \
                '.workers | to_entries[] | select(.value.room_id == $rid) | .key' \
                "$REGISTRY_FILE" 2>/dev/null)
            if [ -n "$worker_entry" ]; then
                found_type="worker"
                found_name="$worker_entry"
            fi
        fi
        if [ -z "$found_type" ]; then
            for meta in "${HOME}/hiclaw-fs/shared/projects"/*/meta.json; do
                [ -f "$meta" ] || continue
                local meta_room
                meta_room=$(jq -r '.room_id // empty' "$meta" 2>/dev/null)
                if [ "$meta_room" = "$room_id" ]; then
                    found_type="project"
                    found_name=$(jq -r '.title // .name // "unknown"' "$meta" 2>/dev/null)
                    break
                fi
            done
        fi
        if [ -z "$found_type" ]; then
            found_type="unknown"
            found_name="unknown"
        fi
        printf 'PREFS_ROOM: %s\t%s\t%s\n' "$room_id" "$found_type" "$found_name"
    done <<< "$selected_rooms"
}

# mark-notified: write today's date and notified_at to prefs (preserve selected_rooms)
action_mark_notified() {
    local today
    today=$(date '+%Y-%m-%d')
    local now_iso
    now_iso=$(date -Iseconds)

    local selected_rooms_json="[]"
    if [ -f "$PREFS_FILE" ]; then
        # Preserve selected_rooms from existing prefs (only if from today)
        local existing_date
        existing_date=$(jq -r '.date // ""' "$PREFS_FILE" 2>/dev/null)
        if [ "$existing_date" = "$today" ]; then
            selected_rooms_json=$(jq -c '.selected_rooms // []' "$PREFS_FILE" 2>/dev/null)
        fi
    fi

    jq -n \
        --arg date "$today" \
        --argjson rooms "$selected_rooms_json" \
        --arg notified_at "$now_iso" \
        '{date: $date, selected_rooms: $rooms, notified_at: $notified_at}' \
        > "$PREFS_FILE"
    _log "Marked notified at ${now_iso}"
}

# save-prefs: update selected_rooms in prefs file
action_save_prefs() {
    local rooms_arg="$1"
    local today
    today=$(date '+%Y-%m-%d')
    local now_iso
    now_iso=$(date -Iseconds)

    # Parse space-separated room IDs into JSON array
    local rooms_json
    if [ -z "$rooms_arg" ]; then
        rooms_json="[]"
    else
        rooms_json=$(printf '%s\n' $rooms_arg | jq -R . | jq -s .)
    fi

    # Read existing prefs to preserve notified_at
    local notified_at=""
    if [ -f "$PREFS_FILE" ]; then
        notified_at=$(jq -r '.notified_at // ""' "$PREFS_FILE" 2>/dev/null)
    fi

    jq -n \
        --arg date "$today" \
        --argjson rooms "$rooms_json" \
        --arg notified_at "$notified_at" \
        '{date: $date, selected_rooms: $rooms, notified_at: $notified_at}' \
        > "$PREFS_FILE"
    _log "Saved prefs: ${rooms_json}"
}

# apply-prefs: run keepalive for each room in selected_rooms, update applied_at
action_apply_prefs() {
    if [ ! -f "$PREFS_FILE" ]; then
        _log "No prefs file found at ${PREFS_FILE}"
        return 0
    fi

    local selected_rooms
    selected_rooms=$(jq -r '.selected_rooms[]? // empty' "$PREFS_FILE" 2>/dev/null)
    if [ -z "$selected_rooms" ]; then
        _log "No rooms selected for keepalive"
        return 0
    fi

    while IFS= read -r room_id; do
        [ -n "$room_id" ] || continue
        _log "Applying keepalive for room: ${room_id}"
        action_keepalive "$room_id"
    done <<< "$selected_rooms"

    # Update applied_at
    local now_iso
    now_iso=$(date -Iseconds)
    local tmp
    tmp=$(mktemp)
    jq --arg applied_at "$now_iso" '.applied_at = $applied_at' "$PREFS_FILE" > "$tmp"
    mv "$tmp" "$PREFS_FILE"
    _log "apply-prefs complete, applied_at=${now_iso}"
}

# keepalive: wake stopped containers, wait 30s, @mention all members in room
action_keepalive() {
    local room_id="$1"
    _log "Sending keepalive to room $room_id"

    local members
    members=$(_room_members "$room_id")
    if [ -z "$members" ]; then
        _log "ERROR: Could not get members for room $room_id"
        return 1
    fi

    # Wake any stopped Worker containers first
    local woke_any=false
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        local worker_name
        worker_name=$(_worker_from_matrix_id "$member")
        [ -n "$worker_name" ] || continue
        local container_status="unknown"
        if [ -f "$LIFECYCLE_FILE" ]; then
            container_status=$(jq -r --arg w "$worker_name" \
                '.workers[$w].container_status // "unknown"' \
                "$LIFECYCLE_FILE" 2>/dev/null)
        fi
        if [ "$container_status" = "stopped" ] || [ "$container_status" = "exited" ]; then
            _log "Worker $worker_name is stopped — waking up"
            bash "${LIFECYCLE_SCRIPT}" --action start --worker "$worker_name" || true
            woke_any=true
        fi
    done <<< "$members"

    if [ "$woke_any" = true ]; then
        _log "Waiting 30 seconds for workers to start..."
        sleep 30
    fi

    # Build mention string and send
    local mention_str=""
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        mention_str="${mention_str}${member} "
    done <<< "$members"
    mention_str="${mention_str% }"

    local body="[Session keepalive] ${mention_str} — maintaining conversation history for this room."
    _matrix_send "$room_id" "$body" | jq -r '.event_id // "ERROR"' 2>/dev/null
    _log "Keepalive message sent to room $room_id"
}

# ─── Argument parsing ─────────────────────────────────────────────────────────

ACTION=""
ROOM=""
ROOMS_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --action) ACTION="$2"; shift 2 ;;
        --room)   ROOM="$2";   shift 2 ;;
        --rooms)  ROOMS_ARG="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$MATRIX_TOKEN" ]; then
    echo "ERROR: MANAGER_MATRIX_TOKEN is not set" >&2
    exit 1
fi

if [ -z "$ACTION" ]; then
    echo "Usage: $0 --action <list-rooms|load-prefs|mark-notified|save-prefs|apply-prefs|keepalive> [--room <room_id>] [--rooms \"!id1 !id2 ...\"]" >&2
    exit 1
fi

case "$ACTION" in
    list-rooms)
        action_list_rooms
        ;;
    load-prefs)
        action_load_prefs
        ;;
    mark-notified)
        action_mark_notified
        ;;
    save-prefs)
        action_save_prefs "$ROOMS_ARG"
        ;;
    apply-prefs)
        action_apply_prefs
        ;;
    keepalive)
        if [ -z "$ROOM" ]; then
            echo "ERROR: --room required for action 'keepalive'" >&2
            exit 1
        fi
        action_keepalive "$ROOM"
        ;;
    *)
        echo "ERROR: Unknown action '$ACTION'. Use: list-rooms, load-prefs, mark-notified, save-prefs, apply-prefs, keepalive" >&2
        exit 1
        ;;
esac
