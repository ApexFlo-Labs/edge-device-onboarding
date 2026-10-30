#!/usr/bin/env bash
# Test terminal output with fixture versions; no hardware or package changes.
set -Eeuo pipefail
source "$1"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TARGET_USER=fixture
HAS_GPU=1; HAS_NPU=1
GPU_BDF=0000:00:02.0; NPU_BDF=0000:00:0b.0
AXELERA_BDFS=(0000:02:00.0)
INTEL_ENV="$TEST_DIR/runtime"; AXELERA_ENV="$INTEL_ENV"
mkdir -p "$INTEL_ENV/bin"
printf '#!/bin/sh\nprintf "9.8.6\\n"\n' > "$INTEL_ENV/bin/python"
chmod +x "$INTEL_ENV/bin/python"
uname() { printf 'test-kernel\n'; }
readlink() { printf '/kernel/drivers/test-driver\n'; }
dpkg-query() { printf '%s\n' "$*" >> "$TEST_DIR/packages"; printf 'installed\t9.8.7'; }
runuser() { printf 'runtime\n' >> "$TEST_DIR/runtimes"; shift 3; "$@"; }

print_summary 'Device 0: fixture flver=2.3.4 bcver=8.6' > "$TEST_DIR/full"
grep -Eq '^Intel GPU driver +PASS +test-driver \(kernel test-kernel\)$' "$TEST_DIR/full" || fail 'Loaded driver absent'
grep -Eq '^Intel NPU firmware pkg +PASS +9\.8\.7$' "$TEST_DIR/full" || fail 'Installed firmware-package version absent'
grep -Eq '^OpenVINO +PASS +9\.8\.6$' "$TEST_DIR/full" || fail 'Runtime version was hardcoded'
grep -q 'Firmware 2.3.4; controller 8.6' "$TEST_DIR/full" || fail 'Actual device versions absent'
grep -Eq '^OpenSSH server +PASS +9\.8\.7$' "$TEST_DIR/full" || fail 'SSH version absent'
lines=$(wc -l < "$TEST_DIR/full")
(( lines <= 22 )) || fail 'Terminal summary is too long'

HAS_GPU=0; HAS_NPU=0; AXELERA_BDFS=()
: > "$TEST_DIR/packages"
: > "$TEST_DIR/runtimes"
print_summary '' > "$TEST_DIR/skipped"
grep -Eq '^Axelera +SKIPPED ' "$TEST_DIR/skipped" || fail 'Absent card was not skipped'
[[ ! -s $TEST_DIR/runtimes ]] || fail 'Absent hardware triggered a runtime query'
if grep -q metis "$TEST_DIR/packages"; then fail 'Absent Axelera triggered a driver query'; fi

if (dpkg-query() { return 1; }; summary_package 'Missing driver' missing) > /dev/null 2>&1; then
    fail 'Missing package produced a PASS row'
fi
printf 'PASS: short terminal summary, observed versions, optional hardware, and missing-version rejection\n'
