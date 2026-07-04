#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-shorturl}"
DB_USER="${DB_USER:-shorturl}"
DB_PASSWORD="${DB_PASSWORD:-shorturl}"
SIZES_CSV="${SIZES_CSV:-1000,50000,200000}"
DURATION="${DURATION:-20s}"
CONCURRENCY="${CONCURRENCY:-50}"
QPS_PER_WORKER="${QPS_PER_WORKER:-1}"
RACE_REQUESTS="${RACE_REQUESTS:-1000}"
RACE_URL="${RACE_URL:-https://bench.local/race-target}"
TARGET_URL="${TARGET_URL:-https://bench.local/scale-target}"
MAX_AVG_GROWTH="${MAX_AVG_GROWTH:-1.30}"
MAX_P95_GROWTH="${MAX_P95_GROWTH:-1.30}"
MAX_RPS_DROP="${MAX_RPS_DROP:-0.20}"
RUN_RACE=1
RUN_SCALING=1

usage() {
    cat <<'EOF'
Usage: ./scripts/load-test.sh [options]

Options:
  --base-url URL             Базовый URL API (default: http://127.0.0.1:8080)
  --db-host HOST             Хост PostgreSQL (default: 127.0.0.1)
  --db-port PORT             Порт PostgreSQL (default: 5432)
  --db-name NAME             Имя БД (default: shorturl)
  --db-user USER             Пользователь БД (default: shorturl)
  --db-password PASSWORD     Пароль БД (default: shorturl)
  --sizes CSV                Размеры БД через запятую (default: 1000,50000,200000)
  --duration VALUE           Длительность одного прогона hey (default: 20s)
  --concurrency N            Конкурентность (default: 50)
  --qps-per-worker N         QPS на воркер для hey (default: 1 => 50 RPS суммарно)
  --race-requests N          Кол-во запросов в race-тесте (default: 1000)
  --race-url URL             URL для race-теста
  --target-url URL           URL для scaling-теста
  --max-avg-growth X         Макс. рост среднего latency относительно базы
  --max-p95-growth X         Макс. рост p95 относительно базы
  --max-rps-drop X           Макс. просадка RPS относительно базы (доля)
  --skip-race                Пропустить race-тест
  --skip-scaling             Пропустить scaling-тест
  -h, --help                 Показать справку

Требования:
  - запущенный API
  - доступный PostgreSQL с таблицей shortlinks
  - установленные curl, psql, python3 и hey

Рекомендуемый запуск через Docker (без локальной установки зависимостей):
  docker compose run --rm loadtest run-load-test
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url)
            BASE_URL="$2"
            shift 2
            ;;
        --db-host)
            DB_HOST="$2"
            shift 2
            ;;
        --db-port)
            DB_PORT="$2"
            shift 2
            ;;
        --db-name)
            DB_NAME="$2"
            shift 2
            ;;
        --db-user)
            DB_USER="$2"
            shift 2
            ;;
        --db-password)
            DB_PASSWORD="$2"
            shift 2
            ;;
        --sizes)
            SIZES_CSV="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --concurrency)
            CONCURRENCY="$2"
            shift 2
            ;;
        --qps-per-worker)
            QPS_PER_WORKER="$2"
            shift 2
            ;;
        --race-requests)
            RACE_REQUESTS="$2"
            shift 2
            ;;
        --race-url)
            RACE_URL="$2"
            shift 2
            ;;
        --target-url)
            TARGET_URL="$2"
            shift 2
            ;;
        --max-avg-growth)
            MAX_AVG_GROWTH="$2"
            shift 2
            ;;
        --max-p95-growth)
            MAX_P95_GROWTH="$2"
            shift 2
            ;;
        --max-rps-drop)
            MAX_RPS_DROP="$2"
            shift 2
            ;;
        --skip-race)
            RUN_RACE=0
            shift
            ;;
        --skip-scaling)
            RUN_SCALING=0
            shift
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

if [[ "$RUN_RACE" -eq 0 && "$RUN_SCALING" -eq 0 ]]; then
    echo "Nothing to run: both --skip-race and --skip-scaling are set." >&2
    exit 1
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

require_command curl
require_command psql
require_command python3

if command -v hey >/dev/null 2>&1; then
    HEY_BIN="hey"
elif [[ -x "$HOME/go/bin/hey" ]]; then
    HEY_BIN="$HOME/go/bin/hey"
else
    echo "Required command not found: hey (or \$HOME/go/bin/hey)" >&2
    exit 1
fi

export PGPASSWORD="$DB_PASSWORD"
PSQL_BASE=(psql -X -q -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME")

sql_exec() {
    "${PSQL_BASE[@]}" -c "$1" >/dev/null
}

sql_query() {
    "${PSQL_BASE[@]}" -At -c "$1"
}

parse_hey_metrics() {
    local report_file="$1"

    python3 - "$report_file" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

def grab(pattern):
    match = re.search(pattern, text, re.MULTILINE)
    if match:
        return match.group(1)
    return ""

avg = grab(r"Average:\s*([0-9.]+)\s+secs")
p95 = grab(r"95%% in ([0-9.]+) secs")
rps = grab(r"Requests/sec:\s*([0-9.]+)")
codes = "|".join(re.findall(r"\[(\d+)\]\s+\d+\s+responses", text))
print(f"{avg},{p95},{rps},{codes}")
PY
}

validate_status_distribution() {
    local codes="$1"
    local label="$2"
    local code

    if [[ -z "$codes" ]]; then
        echo "${label} failed: empty status code distribution." >&2
        exit 1
    fi

    IFS='|' read -r -a parsed_codes <<<"${codes}"
    for code in "${parsed_codes[@]}"; do
        if [[ "$code" != "200" && "$code" != "202" ]]; then
            echo "${label} failed: unexpected status code distribution: ${codes}" >&2
            exit 1
        fi
    done
}

validate_http_availability() {
    local code
    local attempts=30

    for ((i=1; i<=attempts; i++)); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/shortlink?url=https://bench.local/health-check" || true)
        if [[ "$code" == "200" || "$code" == "202" ]]; then
            return 0
        fi

        sleep 1
    done

    echo "API is unavailable or returns unexpected status after ${attempts}s: $code" >&2
    exit 1
}

print_histogram_legend() {
    echo "Response time histogram legend:"
    echo "  <seconds> [count] |<bar>"
    echo "  <seconds> : верхняя граница latency-bucket (секунды)"
    echo "  [count]   : число ответов в bucket"
    echo "  <bar>     : относительная плотность bucket (длиннее = больше ответов)"
}

trim_table_and_seed() {
    local size="$1"

    sql_exec "TRUNCATE TABLE shortlinks RESTART IDENTITY;"
    sql_exec "INSERT INTO shortlinks (original_url, short_code, status, created_at, updated_at) SELECT 'https://bench.local/filler-' || gs::text, NULL, 'pending', NOW(), NOW() FROM generate_series(1, ${size}) AS gs;"
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

validate_http_availability
echo "Starting load test for ${BASE_URL}"
echo "DB: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "hey: ${HEY_BIN}"

if [[ "$RUN_RACE" -eq 1 ]]; then
    echo
    echo "== Race test =="
    print_histogram_legend
    trim_table_and_seed 0

    race_report="${tmp_dir}/race.txt"
    race_endpoint="${BASE_URL}/api/shortlink?url=${RACE_URL}"
    "${HEY_BIN}" -n "${RACE_REQUESTS}" -c "${CONCURRENCY}" "${race_endpoint}" | tee "${race_report}"

    rows_for_race=$(sql_query "SELECT count(*) FROM shortlinks WHERE original_url='${RACE_URL}';")
    if [[ "${rows_for_race}" != "1" ]]; then
        echo "Race test failed: expected 1 row for URL ${RACE_URL}, got ${rows_for_race}" >&2
        exit 1
    fi

    IFS=',' read -r race_avg race_p95 race_rps race_codes < <(parse_hey_metrics "${race_report}")
    if [[ -z "${race_avg}" || -z "${race_p95}" || -z "${race_rps}" ]]; then
        echo "Race test failed: unable to parse hey report." >&2
        exit 1
    fi
    validate_status_distribution "${race_codes}" "Race test"

    echo "Race test passed: single row preserved under concurrency."
fi

if [[ "$RUN_SCALING" -eq 1 ]]; then
    echo
    echo "== Scaling test (fixed 50 RPS profile) =="
    echo "Sizes: ${SIZES_CSV}"
    echo "Duration: ${DURATION}, concurrency: ${CONCURRENCY}, qps/worker: ${QPS_PER_WORKER}"

    metrics_csv="${tmp_dir}/metrics.csv"
    : > "${metrics_csv}"

    IFS=',' read -r -a sizes <<<"${SIZES_CSV}"
    for raw_size in "${sizes[@]}"; do
        size=$(echo "${raw_size}" | tr -d '[:space:]')
        if ! [[ "${size}" =~ ^[0-9]+$ ]]; then
            echo "Invalid dataset size: ${raw_size}" >&2
            exit 1
        fi

        echo
        echo "Dataset size: ${size}"
        print_histogram_legend
        trim_table_and_seed "${size}"
        curl -s -o /dev/null "${BASE_URL}/api/shortlink?url=${TARGET_URL}"

        report_file="${tmp_dir}/scale_${size}.txt"
        "${HEY_BIN}" -z "${DURATION}" -c "${CONCURRENCY}" -q "${QPS_PER_WORKER}" "${BASE_URL}/api/shortlink?url=${TARGET_URL}" | tee "${report_file}"

        IFS=',' read -r avg p95 rps codes < <(parse_hey_metrics "${report_file}")
        if [[ -z "${avg}" || -z "${p95}" || -z "${rps}" ]]; then
            echo "Scaling test failed: unable to parse hey report for size=${size}." >&2
            exit 1
        fi
        validate_status_distribution "${codes}" "Scaling test (size=${size})"

        echo "${size},${avg},${p95},${rps}" >> "${metrics_csv}"
    done

    echo
    echo "Summary metrics:"

    python3 - "${metrics_csv}" "${MAX_AVG_GROWTH}" "${MAX_P95_GROWTH}" "${MAX_RPS_DROP}" <<'PY'
import csv
import sys

metrics_path = sys.argv[1]
max_avg_growth = float(sys.argv[2])
max_p95_growth = float(sys.argv[3])
max_rps_drop = float(sys.argv[4])

def print_table(title, headers, rows):
    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    separator = "+-" + "-+-".join("-" * width for width in widths) + "-+"

    print(title)
    print(separator)
    print("| " + " | ".join(header.ljust(widths[index]) for index, header in enumerate(headers)) + " |")
    print(separator)
    for row in rows:
        print("| " + " | ".join(value.ljust(widths[index]) for index, value in enumerate(row)) + " |")
    print(separator)

with open(metrics_path, encoding="utf-8") as fh:
    rows = []
    for row in csv.reader(fh):
        rows.append(
            {
                "size": int(row[0]),
                "avg": float(row[1]),
                "p95": float(row[2]),
                "rps": float(row[3]),
            }
        )

if not rows:
    print("No scaling metrics found.", file=sys.stderr)
    sys.exit(1)

base = rows[0]
min_rps_ratio = 1.0 - max_rps_drop
violations = []
ratio_rows = []
summary_rows = []

for row in rows:
    avg_ratio = row["avg"] / base["avg"]
    p95_ratio = row["p95"] / base["p95"]
    rps_ratio = row["rps"] / base["rps"]

    summary_rows.append(
        [
            str(row["size"]),
            f"{row['avg']:.4f}",
            f"{row['p95']:.4f}",
            f"{row['rps']:.4f}",
        ]
    )
    ratio_rows.append(
        [
            str(row["size"]),
            f"{avg_ratio:.4f}",
            f"{p95_ratio:.4f}",
            f"{rps_ratio:.4f}",
        ]
    )

    if avg_ratio > max_avg_growth:
        violations.append(
            f"avg ratio {avg_ratio:.4f} exceeds limit {max_avg_growth:.4f} at size={row['size']}"
        )
    if p95_ratio > max_p95_growth:
        violations.append(
            f"p95 ratio {p95_ratio:.4f} exceeds limit {max_p95_growth:.4f} at size={row['size']}"
        )
    if rps_ratio < min_rps_ratio:
        violations.append(
            f"rps ratio {rps_ratio:.4f} below limit {min_rps_ratio:.4f} at size={row['size']}"
        )

print_table(
    "Raw metrics table:",
    ["size", "avg_latency_sec", "p95_latency_sec", "rps"],
    summary_rows,
)
print_table(
    "Relative ratios table:",
    ["size", "avg_ratio", "p95_ratio", "rps_ratio"],
    ratio_rows,
)

if violations:
    print("Scaling criteria FAILED:", file=sys.stderr)
    for violation in violations:
        print(f"- {violation}", file=sys.stderr)
    sys.exit(1)

print("Scaling criteria PASSED.")
PY
fi

echo
echo "Load test completed successfully."
