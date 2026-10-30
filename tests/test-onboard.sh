#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT=$(readlink -f "$1")
source "$SCRIPT"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
parse() { (source "$SCRIPT"; parse_args "$@"); }

parse install --user edgeadmin
parse verify --user edgeadmin --intel-env /opt/device-onboard/intel
parse finish --user edgeadmin
for arguments in 'install --user' 'install --hostname unexpected' 'verify --reboot' 'verify --with-axelera-recovery' 'verify --legacy' 'finish --legacy' 'finish --reboot' 'finish --power-cycle-ready' 'bad-mode'; do
    # Intentional word splitting for these fixed test vectors.
    # shellcheck disable=SC2086
    if parse $arguments >/dev/null 2>&1; then fail "Invalid arguments accepted: $arguments"; fi
done
if parse verify --intel-env '/tmp/../../etc' >/dev/null 2>&1; then fail 'Runtime traversal accepted'; fi

printf 'known artifact\n' > "$TEST_DIR/artifact"
digest=$(sha256sum "$TEST_DIR/artifact" | awk '{print $1}')
verify_archive "$TEST_DIR/artifact" "$digest" || fail 'Valid checksum rejected'
printf 'tampered\n' >> "$TEST_DIR/artifact"
if verify_archive "$TEST_DIR/artifact" "$digest"; then fail 'Tampered archive accepted'; fi

# Prove a bad NPU download cannot reach package installation or extraction.
mkdir -p "$TEST_DIR/cache"
if (
    HAS_GPU=0; HAS_NPU=1; CACHE="$TEST_DIR/cache"
    add-apt-repository() { :; }
    apt-get() { printf '%s\n' "$*" >> "$TEST_DIR/apt-calls"; }
    download() { printf 'corrupt archive\n' > "$2"; }
    tar() { touch "$TEST_DIR/extracted"; }
    install_intel
) > "$TEST_DIR/invalid-npu.log" 2>&1; then fail 'Bad NPU artifact did not fail'; fi
grep -q 'archive checksum mismatch' "$TEST_DIR/invalid-npu.log" || fail 'NPU failure was not the checksum guard'
[[ ! -e $TEST_DIR/extracted ]] || fail 'Unverified archive was extracted'
if grep -q '\.deb' "$TEST_DIR/apt-calls"; then fail 'Unverified NPU package installation attempted'; fi

[[ $(firmware_action 1.3.2 1.4) == legacy ]] || fail 'Legacy firmware path'
[[ $(firmware_action 1.3.2 7.0) == legacy ]] || fail 'Legacy flashed firmware path'
[[ $(firmware_action 1.9.0 7.5) == current ]] || fail 'Current firmware path'
[[ $(firmware_action 1.4.0 7.0) == update ]] || fail 'Supported upgrade path'
[[ $(firmware_action 1.10.0 7.5) == newer ]] || fail 'Downgrade guard'
[[ $(legacy_action 1.3.2 1.4) == enable ]] || fail 'Legacy enablement routing'
[[ $(legacy_action 1.4.0 1.4) == controller ]] || fail 'Legacy controller routing'
[[ $(legacy_action 1.4.0 7.0) == complete ]] || fail 'Legacy completion routing'
if (legacy_action 1.8.0 1.4) >/dev/null 2>&1; then fail 'Unsupported mixed legacy versions accepted'; fi
if (firmware_action bad 7.5) >/dev/null 2>&1; then fail 'Invalid firmware accepted'; fi
if (AXELERA_BDFS=(0000:02:00.0); POWER_READY=0; firmware_update) > "$TEST_DIR/power.log" 2>&1; then fail 'Power-cycle guard failed'; fi
grep -q 'nothing was flashed' "$TEST_DIR/power.log" || fail 'Power-cycle refusal message'

# A cardless device must not install or flash any Axelera component.
(
    AXELERA_BDFS=()
    apt-get() { touch "$TEST_DIR/axelera-package-attempt"; return 1; }
    install_axelera
    firmware_update
)
[[ ! -e $TEST_DIR/axelera-package-attempt ]] || fail 'Axelera packages attempted without hardware'

STATE="$TEST_DIR/state"
mkdir -p "$STATE"
printf '1\n' > "$STATE/expected-axelera"
if (AXELERA_BDFS=(); verify_device) > "$TEST_DIR/missing-card.log" 2>&1; then fail 'Missing card silently skipped'; fi
grep -q 'card is missing' "$TEST_DIR/missing-card.log" || fail 'Missing-card detection'

# Successful PCI enumeration alone cannot substitute for runtime enumeration.
mkdir -p "$TEST_DIR/runtime/bin"
touch "$TEST_DIR/runtime/bin/axdevice"
chmod +x "$TEST_DIR/runtime/bin/axdevice"
if (
    HAS_GPU=0; HAS_NPU=0; AXELERA_BDFS=(0000:02:00.0); AXELERA_ENV="$TEST_DIR/runtime"
    systemctl() { [[ $* != *"$RECOVERY"* ]]; }
    ss() { printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n'; }
    runuser() { printf 'No devices found\n'; }
    verify_device
) > "$TEST_DIR/runtime-missing.log" 2>&1; then fail 'Missing runtime device silently accepted'; fi
grep -q 'did not enumerate every expected' "$TEST_DIR/runtime-missing.log" || fail 'Missing runtime-device detection'

cat /proc/sys/kernel/random/boot_id > "$STATE/native-boot-id"
result=0
(verify_device) > "$TEST_DIR/boot.log" 2>&1 || result=$?
[[ $result == 20 ]] || fail 'Native startup verification accepted without a reboot'
printf 'PASS: arguments, artifact verification, firmware gates, optional Axelera, missing-card detection, and reboot guard\n'
