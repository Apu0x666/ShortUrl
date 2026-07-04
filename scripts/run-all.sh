#!/usr/bin/env bash

set -euo pipefail

MODE="quick"
RUN_UNIT_TESTS=1
RUN_SMOKE=1
RUN_LOAD=1
SMOKE_WAIT=10
DOCKER_CMD=()

usage() {
    cat <<'EOF'
Usage: ./scripts/run-all.sh [options]

Options:
  --mode MODE          quick | full (default: quick)
  --skip-unit          Skip PHPUnit run
  --skip-smoke         Skip smoke-check run
  --skip-load          Skip load-test run
  --smoke-wait SEC     Max wait for smoke ready-state (default: 10)
  -h, --help           Show help

Examples:
  bash ./scripts/run-all.sh
  bash ./scripts/run-all.sh --mode full
  bash ./scripts/run-all.sh --skip-load
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --skip-unit)
            RUN_UNIT_TESTS=0
            shift
            ;;
        --skip-smoke)
            RUN_SMOKE=0
            shift
            ;;
        --skip-load)
            RUN_LOAD=0
            shift
            ;;
        --smoke-wait)
            SMOKE_WAIT="$2"
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

if [[ "$MODE" != "quick" && "$MODE" != "full" ]]; then
    echo "Invalid mode: $MODE (allowed: quick|full)" >&2
    exit 1
fi

run_step() {
    local name="$1"
    shift
    echo
    echo "==> ${name}"
    "$@"
}

init_compose_cmd() {
    if docker.exe compose version >/dev/null 2>&1; then
        DOCKER_CMD=(docker.exe compose)
        return 0
    fi

    if docker compose version >/dev/null 2>&1; then
        DOCKER_CMD=(docker compose)
        return 0
    fi

    echo "Docker Compose command not found." >&2
    return 1
}

compose() {
    "${DOCKER_CMD[@]}" "$@"
}

run_script_in_loadtest() {
    local script_name="$1"
    shift

    local normalized_script="/tmp/${script_name}"
    local command="tr -d '\\r' < /workspace/scripts/${script_name} > ${normalized_script} && chmod +x ${normalized_script} && bash ${normalized_script}"

    if [[ "$#" -gt 0 ]]; then
        command="${command} $*"
    fi

    compose run --rm loadtest sh -lc "$command"
}

run_smoke_check_in_container() {
    run_script_in_loadtest smoke-check.sh --base-url http://nginx --wait-ready "$SMOKE_WAIT"
}

run_quick_load_test_in_container() {
    run_script_in_loadtest load-test.sh \
        --sizes 100,1000 \
        --duration 5s \
        --race-requests 200 \
        --max-avg-growth 100 \
        --max-p95-growth 100 \
        --max-rps-drop 1
}

run_full_load_test_in_container() {
    run_script_in_loadtest load-test.sh
}

composer_install_with_retry() {
    local max_attempts=5
    local attempt=1

    while [[ "$attempt" -le "$max_attempts" ]]; do
        echo "Composer install attempt ${attempt}/${max_attempts}"
        if compose run --rm app composer install --no-interaction; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 10
    done

    echo "composer install failed after ${max_attempts} attempts" >&2
    return 1
}

echo "ShortUrl one-command pipeline"
echo "Mode: ${MODE}"

init_compose_cmd
echo "Compose command: ${DOCKER_CMD[*]}"

if [[ ! -f ".env" ]]; then
    run_step "Create .env from .env.example" cp .env.example .env
fi

run_step "Stop previous stack (keep volumes)" compose down --remove-orphans
run_step "Build and start app stack" compose up -d --build db rabbitmq app nginx worker
run_step "Build loadtest image" compose build loadtest
run_step "Install composer dependencies (with retry)" composer_install_with_retry
run_step "Ensure worker is running (post-install)" compose up -d worker
run_step "Create database if needed" compose exec app php bin/console doctrine:database:create --if-not-exists
run_step "Run migrations" compose exec app php bin/console doctrine:migrations:migrate --no-interaction
run_step "Setup messenger transports" compose exec app php bin/console messenger:setup-transports
run_step "Fix writable permissions for var/" compose exec app sh -lc "mkdir -p var/cache var/log && chown -R www-data:www-data var && chmod -R ug+rwX var"

if [[ "$RUN_UNIT_TESTS" -eq 1 ]]; then
    run_step "Run PHPUnit" compose run --rm app composer test
fi

if [[ "$RUN_SMOKE" -eq 1 ]]; then
    run_step "Run smoke-check" run_smoke_check_in_container
fi

if [[ "$RUN_LOAD" -eq 1 ]]; then
    if [[ "$MODE" == "quick" ]]; then
        run_step "Run quick load-test" run_quick_load_test_in_container
    else
        run_step "Run full load-test" run_full_load_test_in_container
    fi
fi

echo
echo "Pipeline completed successfully."
