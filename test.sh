#!/bin/bash
set -uo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

BINARY_NAME="SwiftCodeEmbedded"
SCRATCH="/tmp/swiftcode-build"
BINARY_PATH="$SCRATCH/arm64-apple-macosx/release/$BINARY_NAME"
MAC_LOG=$(mktemp)
LINUX_LOG=$(mktemp)
SMOKE_DIR=$(mktemp -d)
SMOKE_LOCK="$SMOKE_DIR/.lock"
trap 'rm -f "$MAC_LOG" "$LINUX_LOG"; rm -rf "$SMOKE_DIR"' EXIT

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
    if BUILD_OUTPUT=$(swiftly run swift build -c release +main-snapshot --scratch-path "$SCRATCH" --disable-sandbox 2>&1); then
        cp "$BINARY_PATH" "${BINARY_PATH}.stripped"
        strip "${BINARY_PATH}.stripped" 2>/dev/null || true
        local stripped
        stripped=$(wc -c < "${BINARY_PATH}.stripped" | tr -d ' ')
        rm -f "${BINARY_PATH}.stripped"
        echo "PASS:$stripped"
    else
        swiftly run swift package clean +main-snapshot --scratch-path "$SCRATCH" 2>/dev/null || true
        rm -rf "$SCRATCH"
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
        echo -e "${DIM}–${RESET} ${BOLD}subagent${RESET}  ${DIM}OPENROUTER_API_KEY not set (skipped)${RESET}"
        SKIP=$((SKIP + 4))
    else
        match() {
            local pattern="$1" text="$2"
            if command -v rg >/dev/null 2>&1; then
                printf "%s" "$text" | rg -q --pcre2 "$pattern"
            else
                printf "%s" "$text" | grep -Eq "$pattern"
            fi
        }
        export -f match

        strip_ansi() {
            if command -v perl >/dev/null 2>&1; then
                perl -pe 's/\e\[[0-9;]*m//g'
            else
                sed $'s/\x1b\[[0-9;]*m//g'
            fi
        }
        export -f strip_ansi

        run_case() {
            local prompt="$1"
            printf "%s" "$prompt" | OPENROUTER_API_KEY="$OPENROUTER_API_KEY" "$BINARY_PATH" 2>&1 | strip_ansi
        }
        export -f run_case

        # Print a result line above the spinner (mkdir-based spinlock for macOS compat)
        smoke_print() {
            local line="$1" status="$2" status_file="$3"
            while ! mkdir "$SMOKE_LOCK" 2>/dev/null; do sleep 0.05; done
            printf "\r\033[K%b\n" "$line"
            printf "\r${DIM}  ⠋ Running smoke tests...${RESET}"
            echo "$status" > "$status_file"
            rmdir "$SMOKE_LOCK"
        }

        smoke_pass() {
            smoke_print "$(printf "${GREEN}✓${RESET} ${BOLD}%s${RESET}" "$1")" "PASS" "$2"
        }

        smoke_fail() {
            smoke_print "$(printf "${RED}✗${RESET} ${BOLD}%s${RESET}" "$1")" "FAIL" "$2"
        }

        # Each test is a function that prints immediately and writes status to a file

        test_plain_response() {
            local status_file="$SMOKE_DIR/1"
            local out
            out="$(run_case $'hi!\n')"
            if [[ "$out" == *"> " ]]; then
                smoke_pass "plain response" "$status_file"
            else
                smoke_fail "plain response — prompt marker missing" "$status_file"
            fi
        }

        test_tool_success() {
            local status_file="$SMOKE_DIR/2"
            local out
            out="$(run_case $'Use your sh tool to run exactly: uuidgen\nReturn only command output.\n')"
            if match "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}" "$out" && [[ "$out" == *"> " ]]; then
                smoke_pass "tool call success" "$status_file"
            else
                smoke_fail "tool call success — uuidgen output or prompt marker missing" "$status_file"
            fi
        }

        test_tool_failure() {
            local status_file="$SMOKE_DIR/3"
            local out exit_code
            set +e
            out="$(run_case $'Use your sh tool to run exactly: command_not_found_xyz\nReturn only what happened.\n')"
            exit_code=$?
            set -e

            if [[ $exit_code -ne 0 ]]; then
                smoke_fail "tool call failure — agent crashed (exit $exit_code)" "$status_file"
            elif match "Fatal error|Swift runtime" "$out"; then
                smoke_fail "tool call failure — crash detected in output" "$status_file"
            elif [[ "$out" != *"> " ]]; then
                smoke_fail "tool call failure — prompt marker missing" "$status_file"
            else
                smoke_pass "tool call failure" "$status_file"
            fi
        }

        test_subagent() {
            local status_file="$SMOKE_DIR/4"
            local out
            out="$(run_case $'You MUST use the subagent tool exactly twice, in parallel (both in the same tool call). First subagent task: "Run sh with command: echo hello_world_1" — second subagent task: "Run sh with command: echo hello_world_2". Do not skip the subagent tool. After both complete, state their results exactly as-is with no modifications.\n')"
            if match "hello_world_1" "$out" && match "hello_world_2" "$out" && [[ "$out" == *"> " ]]; then
                smoke_pass "subagent" "$status_file"
            else
                smoke_fail "subagent — expected hello_world_1 and hello_world_2 in output" "$status_file"
            fi
        }

        # Run all smoke tests in parallel (results print above the spinner)
        start_spinner "Running smoke tests..."
        test_plain_response &
        SMOKE_PIDS="$!"
        test_tool_success &
        SMOKE_PIDS="$SMOKE_PIDS $!"
        test_tool_failure &
        SMOKE_PIDS="$SMOKE_PIDS $!"
        test_subagent &
        SMOKE_PIDS="$SMOKE_PIDS $!"
        for pid in $SMOKE_PIDS; do wait "$pid" 2>/dev/null || true; done
        stop_spinner

        # Tally results from status files
        for f in "$SMOKE_DIR"/[0-9]*; do
            [[ -f "$f" ]] || continue
            status=$(<"$f")
            if [[ "$status" == "PASS" ]]; then
                PASS=$((PASS + 1))
            else
                FAIL=$((FAIL + 1))
            fi
        done
    fi
else
    echo ""
    echo -e "${DIM}–${RESET} ${BOLD}plain response${RESET}  ${DIM}macOS build failed (skipped)${RESET}"
    echo -e "${DIM}–${RESET} ${BOLD}tool call success${RESET}  ${DIM}macOS build failed (skipped)${RESET}"
    echo -e "${DIM}–${RESET} ${BOLD}tool call failure${RESET}  ${DIM}macOS build failed (skipped)${RESET}"
    echo -e "${DIM}–${RESET} ${BOLD}subagent${RESET}  ${DIM}macOS build failed (skipped)${RESET}"
    SKIP=$((SKIP + 4))
fi

# ── Teardown ─────────────────────────────────────────────────

start_spinner "Tearing down"
rm -rf "$SCRATCH" 2>/dev/null || true
stop_spinner

SUMMARY="${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
if [ "$SKIP" -gt 0 ]; then
    SUMMARY="$SUMMARY, ${DIM}$SKIP skipped${RESET}"
fi
echo -e "\n$SUMMARY"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
