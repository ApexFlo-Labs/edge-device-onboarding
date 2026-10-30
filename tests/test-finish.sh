#!/usr/bin/env bash
# Every worker runs in a fresh Bash process so errexit remains active inside stages.
set -Eeuo pipefail

if [[ ${1:-} == --case ]]; then
    source "$2"
    STATE=$3
    scenario=$4
    MODE=finish
    AXELERA_BDFS=(0000:02:00.0)
    test_boot_id=$(</proc/sys/kernel/random/boot_id)
    FLASHED_VERSION=1.9.0
    BOARD_CONTROLLER=7.5
    operator_confirm() {
        printf 'prompt: %s\n' "$1" >> "$STATE/events"
        [[ $scenario != declined && $scenario != cycle-unconfirmed ]]
    }
    systemctl() { printf 'systemctl %s\n' "$*" >> "$STATE/events"; [[ $1 != cat ]]; }
    sync() { :; }
    axelera_versions() { printf 'query\n' >> "$STATE/events"; }
    verify_device() {
        printf 'verify\n' >> "$STATE/events"
        [[ $scenario != verify-fails ]]
    }
    vendor_flash() { [[ $scenario != flash-fails ]]; }
    firmware_update() {
        printf 'flash legacy=%s ready=%s\n' "$LEGACY" "$POWER_READY" >> "$STATE/events"
        vendor_flash
        firmware_stage_complete
    }
    case $scenario in
        no-card|verify-fails) AXELERA_BDFS=() ;;
        legacy|declined|flash-fails) FLASHED_VERSION=1.3.2; BOARD_CONTROLLER=1.4 ;;
        intermediate) FLASHED_VERSION=1.4.0; BOARD_CONTROLLER=1.4 ;;
        modern) FLASHED_VERSION=1.4.0; BOARD_CONTROLLER=7.0 ;;
        controller) BOARD_CONTROLLER=7.0 ;;
        startup) ;;
        after-startup) printf 'previous-boot\n' > "$STATE/native-boot-id" ;;
        completed) touch "$STATE/finish-complete" ;;
        cycle-same) printf '%s\n' "$test_boot_id" > "$STATE/firmware-power-cycle-boot-id" ;;
        cycle-new|cycle-unconfirmed) printf 'previous-boot\n' > "$STATE/firmware-power-cycle-boot-id" ;;
        install-same) printf '%s\n' "$test_boot_id" > "$STATE/install-boot-id" ;;
        multi) AXELERA_BDFS+=(0000:03:00.0) ;;
        newer) FLASHED_VERSION=1.10.0 ;;
        invalid) FLASHED_VERSION=unknown ;;
        *) exit 99 ;;
    esac
    finish_setup
    exit
fi

SCRIPT=$(readlink -f "$1")
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_case() {
    local scenario=$1 expected=$2 result=0
    mkdir "$TEST_DIR/$scenario"
    : > "$TEST_DIR/$scenario/events"
    bash "$0" --case "$SCRIPT" "$TEST_DIR/$scenario" "$scenario" > "$TEST_DIR/$scenario/output" 2>&1 || result=$?
    [[ $result == "$expected" ]] || { cat "$TEST_DIR/$scenario/output"; fail "$scenario: expected $expected, got $result"; }
}
has() { grep -Fq -- "$2" "$TEST_DIR/$1/events" || fail "$1: missing $2"; }
lacks() { if grep -Fq -- "$2" "$TEST_DIR/$1/events"; then fail "$1: unexpected $2"; fi; }

for scenario in no-card after-startup completed; do
    run_case "$scenario" 0
    has "$scenario" verify
    lacks "$scenario" 'systemctl reboot'
    lacks "$scenario" "flash legacy="
    [[ -f $TEST_DIR/$scenario/finish-complete ]] || fail "$scenario: missing completion"
done
for scenario in legacy intermediate modern controller; do
    run_case "$scenario" 20
    has "$scenario" 'ready=1'
    has "$scenario" 'systemctl poweroff'
    lacks "$scenario" verify
    [[ -f $TEST_DIR/$scenario/firmware-power-cycle-boot-id ]] || fail "$scenario: missing power-cycle marker"
done
has legacy 'legacy=1'
has intermediate 'legacy=1'
has modern 'legacy=0'
has controller 'legacy=0'

for scenario in startup cycle-new install-same; do
    run_case "$scenario" 20
    has "$scenario" 'systemctl reboot'
    lacks "$scenario" "flash legacy="
    lacks "$scenario" verify
done
[[ -f $TEST_DIR/startup/native-boot-id ]] || fail 'Startup reboot was not recorded'
[[ ! -f $TEST_DIR/cycle-new/firmware-power-cycle-boot-id ]] || fail 'Confirmed cycle did not clear its marker'

run_case cycle-same 20
has cycle-same 'systemctl poweroff'
lacks cycle-same query
lacks cycle-same "flash legacy="

for scenario in declined cycle-unconfirmed flash-fails verify-fails multi newer invalid; do
    run_case "$scenario" 1
    lacks "$scenario" 'systemctl poweroff'
    lacks "$scenario" 'systemctl reboot'
    [[ ! -f $TEST_DIR/$scenario/finish-complete ]] || fail "$scenario: false completion"
done
lacks declined "flash legacy="
lacks cycle-unconfirmed query
[[ -f $TEST_DIR/cycle-unconfirmed/firmware-power-cycle-boot-id ]] || fail 'Unconfirmed cycle lost its marker'
[[ ! -f $TEST_DIR/flash-fails/firmware-power-cycle-boot-id ]] || fail 'Failed flash was marked complete'
lacks newer "flash legacy="

# Test the two operator entry points without sudo or actual installation.
mkdir "$TEST_DIR/wrappers" "$TEST_DIR/bin"
cp "$(dirname "$SCRIPT")/setup.sh" "$(dirname "$SCRIPT")/finish-setup.sh" "$TEST_DIR/wrappers/"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$TEST_DIR/bin/sudo"
chmod +x "$TEST_DIR/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$TEST_DIR/wrappers/onboard-device.sh"
PATH="$TEST_DIR/bin:$PATH" bash "$TEST_DIR/wrappers/setup.sh" --user edgeadmin > "$TEST_DIR/setup-args"
printf '%s\n' install --reboot --user edgeadmin | diff - "$TEST_DIR/setup-args"
PATH="$TEST_DIR/bin:$PATH" bash "$TEST_DIR/wrappers/finish-setup.sh" --user edgeadmin > "$TEST_DIR/finish-args"
printf '%s\n' finish --user edgeadmin | diff - "$TEST_DIR/finish-args"
printf 'PASS: guided setup routing, power-cycle/reboot guards, failed-flash safety, completion, and wrapper dispatch\n'
