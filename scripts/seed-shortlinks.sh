#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
COUNT="${COUNT:-1000}"
BATCH_SIZE="${BATCH_SIZE:-60}"
PREFIX="${PREFIX:-https://demo.local/item}"
WAIT_READY=1
MAX_WAIT="${MAX_WAIT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
WAIT_MODE="${WAIT_MODE:-db}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-3}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"
CREATE_RETRIES="${CREATE_RETRIES:-5}"
CREATE_RETRY_DELAY="${CREATE_RETRY_DELAY:-1}"
DOCKER_CMD=()
FAIL_FILE=""

usage() {
    cat <<'EOF'
Usage: ./scripts/seed-shortlinks.sh [options]

Options:
  --base-url URL         API base URL (default: http://127.0.0.1:8080)
  --count N              Number of URLs to create (default: 1000)
  --batch-size N         Parallel requests per batch (default: 60)
  --prefix URL_PREFIX    URL prefix for generated records (default: https://demo.local/item)
  --wait-ready           Wait until all records become ready (default: enabled)
  --no-wait-ready        Only create records, do not wait for ready
  --max-wait SEC         Max wait time for ready-state (default: 300)
  --poll-interval SEC    Poll interval while waiting (default: 2)
  --wait-mode MODE       Wait mode: db | api (default: db)
  --curl-timeout SEC     Max time for one API request (default: 20)
  --create-retries N     Retries for create request on transport errors (default: 5)
  --retry-delay SEC      Delay between create retries (default: 1)
  -h, --help             Show help

Example:
  bash ./scripts/seed-shortlinks.sh --count 1000 --prefix "https://demo.local/item"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url)
            BASE_URL="$2"
            shift 2
            ;;
        --count)
            COUNT="$2"
            shift 2
            ;;
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --wait-ready)
            WAIT_READY=1
            shift
            ;;
        --no-wait-ready)
            WAIT_READY=0
            shift
            ;;
        --max-wait)
            MAX_WAIT="$2"
            shift 2
            ;;
        --poll-interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --wait-mode)
            WAIT_MODE="$2"
            shift 2
            ;;
        --curl-timeout)
            CURL_MAX_TIME="$2"
            shift 2
            ;;
        --create-retries)
            CREATE_RETRIES="$2"
            shift 2
            ;;
        --retry-delay)
            CREATE_RETRY_DELAY="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
    echo "Invalid --count value: ${COUNT}" >&2
    exit 1
fi

if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [[ "$BATCH_SIZE" -lt 1 ]]; then
    echo "Invalid --batch-size value: ${BATCH_SIZE}" >&2
    exit 1
fi

if ! [[ "$MAX_WAIT" =~ ^[0-9]+$ ]] || [[ "$MAX_WAIT" -lt 1 ]]; then
    echo "Invalid --max-wait value: ${MAX_WAIT}" >&2
    exit 1
fi

if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$POLL_INTERVAL" -lt 1 ]]; then
    echo "Invalid --poll-interval value: ${POLL_INTERVAL}" >&2
    exit 1
fi

if [[ "$WAIT_MODE" != "db" && "$WAIT_MODE" != "api" ]]; then
    echo "Invalid --wait-mode value: ${WAIT_MODE} (allowed: db|api)" >&2
    exit 1
fi

if ! [[ "$CURL_MAX_TIME" =~ ^[0-9]+$ ]] || [[ "$CURL_MAX_TIME" -lt 1 ]]; then
    echo "Invalid --curl-timeout value: ${CURL_MAX_TIME}" >&2
    exit 1
fi

if ! [[ "$CREATE_RETRIES" =~ ^[0-9]+$ ]] || [[ "$CREATE_RETRIES" -lt 1 ]]; then
    echo "Invalid --create-retries value: ${CREATE_RETRIES}" >&2
    exit 1
fi

if ! [[ "$CREATE_RETRY_DELAY" =~ ^[0-9]+$ ]] || [[ "$CREATE_RETRY_DELAY" -lt 0 ]]; then
    echo "Invalid --retry-delay value: ${CREATE_RETRY_DELAY}" >&2
    exit 1
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

require_command curl
require_command sed

init_compose_cmd() {
    if docker.exe compose version >/dev/null 2>&1; then
        DOCKER_CMD=(docker.exe compose)
        return 0
    fi

    if docker compose version >/dev/null 2>&1; then
        DOCKER_CMD=(docker compose)
        return 0
    fi

    return 1
}

compose() {
    "${DOCKER_CMD[@]}" "$@"
}

json_get() {
    local body="$1"
    local key="$2"

    printf '%s' "$body" \
        | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
        | sed 's#\\/#/#g' \
        | sed -n '1p'
}

create_shortlink_request() {
    local url="$1"

    (
        local status=""
        local curl_exit=0
        local attempt=1

        while (( attempt <= CREATE_RETRIES )); do
            if status="$(curl -s --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -o /dev/null -w "%{http_code}" -G --data-urlencode "url=${url}" "${BASE_URL}/api/shortlink")"; then
                curl_exit=0
            else
                curl_exit=$?
            fi

            if [[ "$status" == "200" || "$status" == "202" ]]; then
                exit 0
            fi

            if (( attempt < CREATE_RETRIES )); then
                sleep "${CREATE_RETRY_DELAY}"
            fi

            attempt=$((attempt + 1))
        done

        echo "${url},http=${status:-000},curl_exit=${curl_exit},attempts=${CREATE_RETRIES}" >>"${FAIL_FILE}"
    ) &
}

probe_shortlink_status() {
    local url="$1"
    local body_file
    local status
    local body
    local state
    local short_code

    body_file="$(mktemp)"
    status="$(curl -s --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -o "$body_file" -w "%{http_code}" -G --data-urlencode "url=${url}" "${BASE_URL}/api/shortlink" || true)"
    body="$(cat "$body_file" 2>/dev/null || true)"
    rm -f "$body_file"

    state="$(json_get "$body" "status")"
    short_code="$(json_get "$body" "short_code")"

    if [[ "$status" == "200" && "$state" == "ready" && -n "$short_code" ]]; then
        echo "ready"
        return 0
    fi

    if [[ "$status" == "202" && "$state" == "pending" ]]; then
        echo "pending"
        return 0
    fi

    echo "unknown:${status}"
    return 0
}

wait_until_ready_via_db() {
    local escaped_prefix
    local counts
    local ready
    local total
    local deadline

    escaped_prefix="${PREFIX//\'/\'\'}"
    deadline=$(( $(date +%s) + MAX_WAIT ))

    while true; do
        counts="$(compose exec -T db psql -U shorturl -d shorturl -At -F, -c "SELECT count(*) FILTER (WHERE status='ready' AND short_code IS NOT NULL), count(*) FROM shortlinks WHERE original_url LIKE '${escaped_prefix}-%';" 2>/dev/null || true)"
        if [[ -z "$counts" ]]; then
            echo "DB wait mode failed (cannot read counts)." >&2
            return 1
        fi

        ready="${counts%,*}"
        total="${counts#*,}"

        if ! [[ "$ready" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]]; then
            echo "DB wait mode failed (unexpected counts format: ${counts})." >&2
            return 1
        fi

        echo "Ready progress (db): ${ready}/${COUNT} (total_rows=${total})"

        if [[ "$ready" -ge "$COUNT" && "$total" -ge "$COUNT" ]]; then
            echo "All shortlinks are ready."
            return 0
        fi

        if (( $(date +%s) >= deadline )); then
            echo "Timeout: not all records became ready within ${MAX_WAIT}s." >&2
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

wait_until_ready_via_api() {
    local pending_urls
    local deadline
    local ready_count
    local unknown_count
    local next_pending
    local url
    local result
    local pending_count
    local total_ready

    mapfile -t pending_urls <"${URLS_FILE}"
    deadline=$(( $(date +%s) + MAX_WAIT ))

    while true; do
        ready_count=0
        unknown_count=0
        next_pending=()

        for url in "${pending_urls[@]}"; do
            result="$(probe_shortlink_status "$url")"

            case "$result" in
                ready)
                    ready_count=$((ready_count + 1))
                    ;;
                pending)
                    next_pending+=("$url")
                    ;;
                *)
                    unknown_count=$((unknown_count + 1))
                    next_pending+=("$url")
                    ;;
            esac
        done

        pending_count="${#next_pending[@]}"
        total_ready=$(( COUNT - pending_count ))
        echo "Ready progress (api): ${total_ready}/${COUNT} (pending=${pending_count}, unknown=${unknown_count})"

        if [[ "$pending_count" -eq 0 ]]; then
            echo "All shortlinks are ready."
            return 0
        fi

        if (( $(date +%s) >= deadline )); then
            echo "Timeout: not all records became ready within ${MAX_WAIT}s." >&2
            return 1
        fi

        pending_urls=("${next_pending[@]}")
        sleep "$POLL_INTERVAL"
    done
}

echo
echo "Seed shortlinks via API"
echo "Base URL: ${BASE_URL}"
echo "Records: ${COUNT}, batch size: ${BATCH_SIZE}"
echo "Prefix: ${PREFIX}"
echo "Wait mode: ${WAIT_MODE}"
echo "Create retries: ${CREATE_RETRIES}, retry delay: ${CREATE_RETRY_DELAY}s"
echo

FAIL_FILE="$(mktemp)"
URLS_FILE="$(mktemp)"
trap 'rm -f "${FAIL_FILE}" "${URLS_FILE}"' EXIT

for ((index = 1; index <= COUNT; index++)); do
    url="${PREFIX}-${index}"
    printf '%s\n' "$url" >>"${URLS_FILE}"
    create_shortlink_request "$url"

    if (( index % BATCH_SIZE == 0 )); then
        wait
        echo "Create progress: ${index}/${COUNT}"
    fi
done
wait

failed_creates="$(wc -l <"${FAIL_FILE}" | tr -d '[:space:]')"
if [[ "$failed_creates" != "0" ]]; then
    echo "Create step failed for ${failed_creates} requests." >&2
    echo "Sample failures (url,http,curl_exit,attempts):" >&2
    sed -n '1,10p' "${FAIL_FILE}" >&2
    exit 1
fi

echo "Create step completed: ${COUNT}/${COUNT}"

if [[ "$WAIT_READY" -eq 0 ]]; then
    echo "Wait step skipped (--no-wait-ready)."
    exit 0
fi

if [[ "$WAIT_MODE" == "db" ]]; then
    if init_compose_cmd; then
        if ! wait_until_ready_via_db; then
            echo "Falling back to API wait mode..."
            wait_until_ready_via_api
        fi
    else
        echo "Docker Compose command not found, falling back to API wait mode..."
        wait_until_ready_via_api
    fi
else
    wait_until_ready_via_api
fi

echo
echo "Done. Records remain in DB until next load-test/TRUNCATE or volume reset."
