#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
WAIT_READY="${WAIT_READY:-10}"

usage() {
    cat <<'EOF'
Usage: ./scripts/smoke-check.sh [options]

Options:
  --base-url URL     Base URL (default: http://127.0.0.1:8080)
  --wait-ready SEC   Max wait for ready state in seconds (default: 10)
  -h, --help         Show help

Recommended Docker run:
  docker compose run --rm loadtest run-smoke-check
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url)
            BASE_URL="$2"
            shift 2
            ;;
        --wait-ready)
            WAIT_READY="$2"
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

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

require_command curl

passed=0
failed=0
http_status=0
http_body=""

print_result() {
    local name="$1"
    local ok="$2"
    local details="${3:-}"

    if [[ "$ok" == "1" ]]; then
        passed=$((passed + 1))
        echo "[PASS] ${name}"
    else
        failed=$((failed + 1))
        echo "[FAIL] ${name}"
    fi

    if [[ -n "$details" ]]; then
        echo "       ${details}"
    fi
}

request() {
    local url="$1"
    local body_file

    body_file="$(mktemp)"
    http_status="$(curl -s -o "$body_file" -w "%{http_code}" "$url" || true)"
    http_body="$(cat "$body_file" 2>/dev/null || true)"
    rm -f "$body_file"

    if ! [[ "$http_status" =~ ^[0-9]+$ ]]; then
        http_status="0"
    fi
}

json_get() {
    local body="$1"
    local key="$2"

    printf '%s' "$body" \
        | sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" \
        | head -n 1 \
        | sed 's#\\/#/#g'
}

wait_for_ready() {
    local url="$1"

    for ((attempt = 1; attempt <= WAIT_READY; attempt++)); do
        request "$url"

        second_status="$http_status"
        second_body="$http_body"
        second_status_value="$(json_get "$second_body" "status")"
        second_short_code="$(json_get "$second_body" "short_code")"
        second_short_url="$(json_get "$second_body" "short_url")"

        if [[ "$second_status" == "200" && "$second_status_value" == "ready" && -n "$second_short_code" && -n "$second_short_url" ]]; then
            return 0
        fi

        if [[ "$attempt" -lt "$WAIT_READY" ]]; then
            sleep 1
        fi
    done

    return 1
}

ensure_available() {
    local attempts=30
    local code

    for ((i = 1; i <= attempts; i++)); do
        request "${BASE_URL}/api/shortlink?url=https://smoke.local/health-check"
        code="$http_status"
        if [[ "$code" == "200" || "$code" == "202" ]]; then
            return 0
        fi
        sleep 1
    done

    echo "Service is unavailable or returned status: ${http_status}" >&2
    exit 1
}

redirect_check() {
    local short_code="$1"
    local first_line
    local location_line
    local status
    local location

    first_line="$(curl -s -I "${BASE_URL}/r/${short_code}" | head -n 1 || true)"
    location_line="$(curl -s -I "${BASE_URL}/r/${short_code}" | grep -i '^Location:' | head -n 1 || true)"
    status="$(printf '%s' "$first_line" | sed -n 's/HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p')"
    location="$(printf '%s' "$location_line" | sed -n 's/^[Ll]ocation:[[:space:]]*//p' | tr -d '\r')"

    echo "${status}|${location}"
}

echo
echo "ShortUrl smoke-check"
echo "Base URL: ${BASE_URL}"
echo

ensure_available

original_url="https://example.com/smoke-$(date +%s)-$RANDOM"
api_url="${BASE_URL}/api/shortlink?url=${original_url}"

request "$api_url"
first_status="$http_status"
first_body="$http_body"
first_status_value="$(json_get "$first_body" "status")"
first_original_value="$(json_get "$first_body" "original_url")"

if [[ "$first_status" == "202" && "$first_status_value" == "pending" && "$first_original_value" == "$original_url" ]]; then
    print_result "1. First request: 202 pending" "1" "HTTP ${first_status}; body: ${first_body}"
else
    print_result "1. First request: 202 pending" "0" "HTTP ${first_status}; body: ${first_body}"
fi

if wait_for_ready "$api_url"; then
    print_result "2. Second request: 200 ready" "1" "HTTP ${second_status}; short_code=${second_short_code}"
else
    print_result "2. Second request: 200 ready" "0" "HTTP ${second_status}; body: ${second_body}"
fi

if [[ -n "$second_short_code" ]]; then
    redirect_result="$(redirect_check "$second_short_code")"
    redirect_status="${redirect_result%%|*}"
    redirect_location="${redirect_result#*|}"

    if [[ "$redirect_status" == "302" && "$redirect_location" == "$original_url" ]]; then
        print_result "3. Redirect /r/{shortCode}: 302" "1" "HTTP ${redirect_status}; Location=${redirect_location}"
    else
        print_result "3. Redirect /r/{shortCode}: 302" "0" "HTTP ${redirect_status}; Location=${redirect_location}"
    fi
else
    print_result "3. Redirect /r/{shortCode}: 302" "0" "short_code missing"
fi

request "${BASE_URL}/api/shortlink"
missing_status="$http_status"
missing_body="$http_body"
missing_status_value="$(json_get "$missing_body" "status")"

if [[ "$missing_status" == "400" && "$missing_status_value" == "error" ]]; then
    print_result "4. Missing url: 400" "1" "HTTP ${missing_status}"
else
    print_result "4. Missing url: 400" "0" "HTTP ${missing_status}; body: ${missing_body}"
fi

request "${BASE_URL}/api/shortlink?url=not-a-valid-url"
invalid_status="$http_status"
invalid_body="$http_body"
invalid_status_value="$(json_get "$invalid_body" "status")"

if [[ "$invalid_status" == "400" && "$invalid_status_value" == "error" ]]; then
    print_result "5. Invalid url: 400" "1" "HTTP ${invalid_status}"
else
    print_result "5. Invalid url: 400" "0" "HTTP ${invalid_status}; body: ${invalid_body}"
fi

if [[ -n "$second_short_code" ]]; then
    request "$api_url"
    third_status="$http_status"
    third_body="$http_body"
    third_short_code="$(json_get "$third_body" "short_code")"

    if [[ "$third_status" == "200" && "$third_short_code" == "$second_short_code" ]]; then
        print_result "6. Idempotency: same short_code" "1" "short_code=${third_short_code}"
    else
        print_result "6. Idempotency: same short_code" "0" "HTTP ${third_status}; short_code=${third_short_code}"
    fi
else
    print_result "6. Idempotency: same short_code" "0" "short_code missing"
fi

echo
echo "Total: ${passed} passed, ${failed} failed"
echo

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi

exit 0
