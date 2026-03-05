#!/bin/bash
set -uo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

BINARY_NAME="SwiftCodeEmbedded"
BINARY_PATH=".build/release/$BINARY_NAME"
MAC_LOG=$(mktemp)
LINUX_LOG=$(mktemp)
trap 'rm -f "$MAC_LOG" "$LINUX_LOG"' EXIT

human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1048576 ]; then
        echo "$((bytes / 1048576)).$((bytes % 1048576 * 100 / 1048576)) MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$((bytes / 1024)).$((bytes % 1024 * 10 / 1024)) KB"
    else
        echo "${bytes} B"
    fi
}

spinner() {
    local label="${1:-Building...}"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while true; do
        printf "\r${DIM}  %s %s${RESET}" "${chars:$i:1}" "$label"
        i=$(( (i + 1) % ${#chars} ))
        sleep 0.1
    done
}

start_spinner() {
    spinner "$1" &
    SPINNER_PID=$!
}

stop_spinner() {
    kill $SPINNER_PID 2>/dev/null || true
    wait $SPINNER_PID 2>/dev/null || true
    printf "\r\033[K"
}

build_mac() {
    if BUILD_OUTPUT=$(swiftly run swift build -c release +main-snapshot 2>&1); then
        cp "$BINARY_PATH" "${BINARY_PATH}.stripped"
        strip "${BINARY_PATH}.stripped" 2>/dev/null || true
        local stripped
        stripped=$(wc -c < "${BINARY_PATH}.stripped" | tr -d ' ')
        rm -f "${BINARY_PATH}.stripped"
        echo "PASS:$stripped"
    else
        swiftly run swift package clean +main-snapshot 2>/dev/null || true
        rm -rf .build
        echo "FAIL"
        echo "$BUILD_OUTPUT"
    fi
}

build_linux() {
    local binary=".build/release/$BINARY_NAME"
    if ! command -v docker &>/dev/null; then
        echo "SKIP"
        return
    fi
    if DOCKER_OUTPUT=$(docker run --rm \
        -v "$(pwd)":/src:ro \
        -w /build \
        swiftlang/swift:nightly-jammy \
        bash -c 'set -e
            cp -r /src/. /build/
            apt-get update -qq && apt-get install -y -qq libcurl4-openssl-dev libbsd-dev > /dev/null 2>&1
            swift build -c release 2>&1
            strip '"$binary"' 2>/dev/null || true
            wc -c < '"$binary"' | tr -d " "
        ' 2>&1); then
        local stripped
        stripped=$(echo "$DOCKER_OUTPUT" | tail -1)
        echo "PASS:$stripped"
    else
        echo "FAIL"
        echo "$DOCKER_OUTPUT"
    fi
}

# ── Run both in parallel with spinner ─────────────────────────

build_mac   > "$MAC_LOG"   2>&1 &
build_linux > "$LINUX_LOG" 2>&1 &

start_spinner "Building..."
wait %1 %2 2>/dev/null || true
stop_spinner

# ── Results ───────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0

print_result() {
    local label=$1 log=$2
    local first
    first=$(head -1 "$log")

    if [[ "$first" == PASS:* ]]; then
        local bytes="${first#PASS:}"
        echo -e "${GREEN}✓${RESET} ${BOLD}$label${RESET}  $(human_size "$bytes") ${DIM}($bytes bytes)${RESET}"
        PASS=$((PASS + 1))
    elif [[ "$first" == "SKIP" ]]; then
        echo -e "${DIM}–${RESET} ${BOLD}$label${RESET}  ${DIM}Docker not found (skipped)${RESET}"
        SKIP=$((SKIP + 1))
    else
        echo -e "${RED}✗${RESET} ${BOLD}$label${RESET}"
        tail -n +2 "$log"
        FAIL=$((FAIL + 1))
    fi
}

print_result "macOS" "$MAC_LOG"
print_result "Linux" "$LINUX_LOG"

# ── Smoke Tests (require macOS build + API key) ──────────────

MAC_BUILT=false
[[ "$(head -1 "$MAC_LOG")" == PASS:* ]] && MAC_BUILT=true

if $MAC_BUILT; then
    echo ""

    if [[ -z "${OPENROUTER_API_KEY:-}" ]] && [[ -f .env ]]; then
        set -a; . ./.env; set +a
    fi

    if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
        echo -e "${DIM}–${RESET} ${BOLD}plain response${RESET}  ${DIM}OPENROUTER_API_KEY not set (skipped)${RESET}"
        echo -e "${DIM}–${RESET} ${BOLD}tool call success${RESET}  ${DIM}OPENROUTER_API_KEY not set (skipped)${RESET}"
        echo -e "${DIM}–${RESET} ${BOLD}tool call failure${RESET}  ${DIM}OPENROUTER_API_KEY not set (skipped)${RESET}"
        SKIP=$((SKIP + 3))
    else
        match() {
            local pattern="$1" text="$2"
            if command -v rg >/dev/null 2>&1; then
                printf "%s" "$text" | rg -q --pcre2 "$pattern"
            else
                printf "%s" "$text" | grep -Eq "$pattern"
            fi
        }

        strip_ansi() {
            if command -v perl >/dev/null 2>&1; then
                perl -pe 's/\e\[[0-9;]*m//g'
            else
                sed $'s/\x1b\[[0-9;]*m//g'
            fi
        }

        run_case() {
            local prompt="$1"
            printf "%s" "$prompt" | OPENROUTER_API_KEY="$OPENROUTER_API_KEY" "$BINARY_PATH" 2>&1 | strip_ansi
        }

        fail_test() {
            stop_spinner
            printf "${RED}✗${RESET} ${BOLD}%s${RESET}\n" "$1" >&2
            FAIL=$((FAIL + 1))
        }

        pass_test() {
            stop_spinner
            printf "${GREEN}✓${RESET} ${BOLD}%s${RESET}\n" "$1"
            PASS=$((PASS + 1))
        }

        skip_test() {
            printf "${DIM}–${RESET} ${BOLD}%s${RESET}  ${DIM}%s (skipped)${RESET}\n" "$1" "$2"
            SKIP=$((SKIP + 1))
        }

        # 1) Plain response — agent replies and shows prompt marker
        start_spinner "Testing plain response"
        out="$(run_case $'hi!\n')"
        if [[ "$out" == *"> " ]]; then
            pass_test "plain response"
        else
            fail_test "plain response — prompt marker missing"
        fi

        # 2) Tool success — agent runs uuidgen and returns a UUID
        start_spinner "Testing tool call success"
        out="$(run_case $'Use your sh tool to run exactly: uuidgen\nReturn only command output.\n')"
        if match "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}" "$out" && [[ "$out" == *"> " ]]; then
            pass_test "tool call success"
        else
            fail_test "tool call success — uuidgen output or prompt marker missing"
        fi

        # 3) Tool failure — agent survives a bad command
        start_spinner "Testing tool call failure"
        set +e
        out="$(run_case $'Use your sh tool to run exactly: command_not_found_xyz\nReturn only what happened.\n')"
        exit_code=$?
        set -e

        if [[ $exit_code -ne 0 ]]; then
            fail_test "tool call failure — agent crashed (exit $exit_code)"
        elif match "Fatal error|Swift runtime" "$out"; then
            fail_test "tool call failure — crash detected in output"
        elif [[ "$out" != *"> " ]]; then
            fail_test "tool call failure — prompt marker missing"
        else
            pass_test "tool call failure"
        fi
    fi
else
    echo ""
    echo -e "${DIM}–${RESET} ${BOLD}plain response${RESET}  ${DIM}macOS build failed (skipped)${RESET}"
    echo -e "${DIM}–${RESET} ${BOLD}tool call success${RESET}  ${DIM}macOS build failed (skipped)${RESET}"
    echo -e "${DIM}–${RESET} ${BOLD}tool call failure${RESET}  ${DIM}macOS build failed (skipped)${RESET}"
    SKIP=$((SKIP + 3))
fi

# ── Teardown ─────────────────────────────────────────────────

start_spinner "Tearing down"
rm -rf .build 2>/dev/null || true
stop_spinner

SUMMARY="${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
if [ "$SKIP" -gt 0 ]; then
    SUMMARY="$SUMMARY, ${DIM}$SKIP skipped${RESET}"
fi
echo -e "\n$SUMMARY"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
