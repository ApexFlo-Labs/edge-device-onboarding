#!/usr/bin/env bash
# Ubuntu 24.04 amd64 / Intel Core Ultra onboarding baseline, 2026-10-30.
# Operator instructions are in README.md; vendor details are in docs/maintenance.md.
set -Eeuo pipefail

NPU_VERSION=1.38.0
NPU_ARCHIVE=linux-npu-driver-v1.38.0.20260910-34487311128-ubuntu2404.tar.gz
NPU_SHA256=1efcd4b60c22abee751d8f2705962cbcc2a569de45c7e0e670cf08afbfcdc1d2
NPU_SIGNER=EA267657A608300C296B8F8AD52C9665A4077678
AXELERA_VERSION=1.9.0
METIS_VERSION=1.7.16
CONTROLLER_VERSION=7.5
OPENVINO_VERSION=2026.3.1
STATE=/var/lib/device-onboard
CACHE=/var/cache/device-onboard
RECOVERY='device-onboard-axelera.service'
INTEL_ENV=/opt/device-onboard/intel
AXELERA_ENV=/opt/device-onboard/axelera
MODE=install
TARGET_USER=${SUDO_USER:-}
WITH_RECOVERY=0
LEGACY=0
POWER_READY=0
REBOOT=0
HAS_GPU=0
GPU_BDF=
HAS_NPU=0
AXELERA_BDFS=()

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n== %s ==\n' "$*"; }
usage() {
    cat <<'HELP'
Usage:
  sudo bash onboard-device.sh install --user edgeadmin [options]
  sudo bash onboard-device.sh verify --user edgeadmin [options]
  sudo bash onboard-device.sh finish --user edgeadmin [options]
  sudo bash onboard-device.sh firmware --user edgeadmin --power-cycle-ready
  sudo bash onboard-device.sh native-boot --user edgeadmin [--reboot]
  bash onboard-device.sh plan

Options:
  --user USER                 Existing non-root account; defaults to SUDO_USER.
  --with-axelera-recovery      Explicitly install the optional PCIe boot workaround.
  --power-cycle-ready         Someone can physically power-cycle the device.
  --legacy                    Use the staged 1.4 path for older Axelera cards.
  --reboot                    Reboot after install or native-boot preparation.
  --intel-env PATH            Runtime path override (mainly for existing devices).
  --axelera-env PATH           Runtime path override (mainly for existing devices).
  --help                     Show this help.

Install never flashes hardware. Firmware uses the unmodified vendor updater.
Legacy controllers below 7.0 require the vendor's enablement / staged 1.4 path.
Exit 20 means a reboot, power cycle, or legacy firmware preparation is pending.
Exit 0 from verify means local checks passed; also test SSH from another device.
HELP
}

parse_args() {
    if (($#)) && [[ $1 != --* ]]; then MODE=$1; shift; fi
    case $MODE in install|verify|finish|firmware|native-boot|plan) ;; *) die "Unknown mode: $MODE" ;; esac
    while (($#)); do
        case $1 in
            --user|--intel-env|--axelera-env)
                if (($# < 2)); then die "Missing value for $1"; fi
                [[ -n $2 && $2 != --* ]] || die "Missing value for $1"
                case $1 in
                    --user) TARGET_USER=$2 ;;
                    --intel-env) INTEL_ENV=$2 ;;
                    --axelera-env) AXELERA_ENV=$2 ;;
                esac
                shift 2 ;;
            --with-axelera-recovery) WITH_RECOVERY=1; shift ;;
            --power-cycle-ready) POWER_READY=1; shift ;;
            --legacy) LEGACY=1; shift ;;
            --reboot) REBOOT=1; shift ;;
            --help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    for runtime_path in "$INTEL_ENV" "$AXELERA_ENV"; do
        [[ $runtime_path =~ ^/[A-Za-z0-9_./-]+$ && $runtime_path != *..* ]] || die 'Use an absolute runtime path without spaces or parent traversal'
    done
    (( ! REBOOT )) || [[ $MODE == install || $MODE == native-boot ]] || die '--reboot is only valid for install or native-boot'
    (( ! WITH_RECOVERY )) || [[ $MODE == install ]] || die '--with-axelera-recovery is only valid for install'
    (( ! POWER_READY )) || [[ $MODE == firmware ]] || die '--power-cycle-ready is only valid for firmware'
    (( ! LEGACY )) || [[ $MODE == firmware ]] || die '--legacy is only valid for firmware'
}

detect_hardware() {
    HAS_GPU=0; HAS_NPU=0; GPU_BDF=; AXELERA_BDFS=()
    local device vendor class
    for device in /sys/bus/pci/devices/*; do
        [[ -r $device/vendor && -r $device/class ]] || continue
        vendor=$(<"$device/vendor"); class=$(<"$device/class")
        if [[ $vendor == 0x8086 && $class == 0x03* ]]; then HAS_GPU=1; GPU_BDF=${device##*/}; fi
        if [[ $vendor == 0x8086 && $class == 0x120000 ]]; then HAS_NPU=1; fi
        if [[ $vendor == 0x1f9d ]]; then AXELERA_BDFS+=("${device##*/}"); fi
    done
}

check_platform() {
    [[ -r /etc/os-release ]] || die 'This script requires Ubuntu Linux'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ $ID == ubuntu && $VERSION_ID == 24.04 && $(uname -m) == x86_64 ]] || die 'Supported platform: Ubuntu 24.04 amd64'
}

download() { curl --fail --location --silent --show-error --retry 3 "$1" -o "$2"; }

verify_archive() {
    printf '%s  %s\n' "$2" "$1" | sha256sum --check --status
}

install_intel() {
    (( HAS_GPU || HAS_NPU )) || return 0
    add-apt-repository -y ppa:kobuk-team/intel-graphics
    apt-get update
    apt-get install -y libze1
    if (( HAS_GPU )); then
        apt-get install -y clinfo libze-intel-gpu1 intel-metrics-discovery intel-opencl-icd intel-gsc \
            intel-media-va-driver-non-free libmfx-gen1.2 libvpl2 libvpl-tools libva-glx2 va-driver-all vainfo
    fi
    if (( HAS_NPU )); then
        local directory="$CACHE/npu-$NPU_VERSION" package
        install -d -m 0755 "$directory"
        download "https://github.com/intel/linux-npu-driver/releases/download/v$NPU_VERSION/$NPU_ARCHIVE" "$directory/npu.tar.gz"
        verify_archive "$directory/npu.tar.gz" "$NPU_SHA256" || die 'Intel NPU archive checksum mismatch'
        tar -xzf "$directory/npu.tar.gz" -C "$directory"
        install -d -m 0700 "$directory/signing"
        download "https://keys.openpgp.org/vks/v1/by-fingerprint/$NPU_SIGNER" "$directory/signing-key.asc"
        gpg --homedir "$directory/signing" --batch --import "$directory/signing-key.asc"
        gpg --homedir "$directory/signing" --batch --with-colons --fingerprint "$NPU_SIGNER" | grep -F "fpr:::::::::$NPU_SIGNER:" >/dev/null
        for package in intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu; do
            local matches=("$directory/${package}_"*.deb)
            [[ ${#matches[@]} == 1 && -f ${matches[0]} ]] || die "Expected one $package package"
            gpg --homedir "$directory/signing" --batch --verify "${matches[0]}.asc" "${matches[0]}"
        done
        apt-get install -y "$directory/"*.deb
    fi
    usermod -aG render,video "$TARGET_USER"
    (umask 022; python3 -m venv "$INTEL_ENV"
        "$INTEL_ENV/bin/pip" install --disable-pip-version-check "openvino==$OPENVINO_VERSION")
    "$INTEL_ENV/bin/pip" freeze > "$STATE/intel-runtime-versions.txt"
}

install_axelera() {
    ((${#AXELERA_BDFS[@]})) || return 0
    apt-get install -y mokutil
    if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
        die 'Secure Boot is enabled. Arrange DKMS signing-key enrollment before using this baseline'
    fi
    apt-get install -y build-essential dkms "linux-headers-$(uname -r)" lsof libgl1 libglib2.0-0t64
    install -d -m 0755 /etc/apt/keyrings
    download https://software.axelera.ai/artifactory/api/security/keypair/axelera/public "$CACHE/axelera-signing.asc"
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/axelera.gpg "$CACHE/axelera-signing.asc"
    chmod 0644 /etc/apt/keyrings/axelera.gpg
    printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/axelera.gpg] https://software.axelera.ai/artifactory/axelera-apt-source ubuntu24 main' > /etc/apt/sources.list.d/axelera.list
    apt-get update
    apt-get install -y "metis-dkms=$METIS_VERSION"
    usermod -aG axelera "$TARGET_USER"
    modprobe metis
    (umask 022; python3 -m venv "$AXELERA_ENV"
        "$AXELERA_ENV/bin/pip" install --disable-pip-version-check \
            --extra-index-url https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple "axelera-rt==$AXELERA_VERSION")
    "$AXELERA_ENV/bin/pip" freeze > "$STATE/axelera-runtime-versions.txt"
    if (( WITH_RECOVERY )); then install_recovery; fi
}

install_recovery() {
    ((${#AXELERA_BDFS[@]} == 1)) || die 'Automatic recovery is limited to one Axelera card'
    local endpoint bridge child
    endpoint=$(readlink -f "/sys/bus/pci/devices/${AXELERA_BDFS[0]}")
    bridge=${endpoint%/*}; bridge=${bridge##*/}
    [[ $bridge =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ && -e /sys/bus/pci/devices/$bridge/rescan ]] || die 'Cannot identify the dedicated PCIe parent port'
    for child in "$(dirname "$endpoint")"/*/vendor; do
        [[ ! -f $child || $(<"$child") == 0x1f9d ]] || die 'Refusing recovery on a PCIe port shared with another vendor'
    done
    local existing
    existing=$(systemctl list-unit-files --no-legend '*axelera*' | awk '$2=="enabled" {print $1}')
    [[ -z $existing || $existing == "$RECOVERY" ]] || die "An existing Axelera startup unit must be reviewed first: $existing"
    cat > "/etc/systemd/system/$RECOVERY" <<UNIT
[Unit]
Description=Initialize Axelera accelerator
Wants=network-online.target
After=network-online.target
ConditionPathExists=/sys/bus/pci/devices/$bridge/rescan
StartLimitIntervalSec=180
StartLimitBurst=4
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo 1 > /sys/bus/pci/devices/$bridge/rescan'
ExecStart=/usr/bin/udevadm settle
ExecStart=/usr/bin/env PATH=$AXELERA_ENV/bin:/usr/sbin:/usr/bin:/sbin:/bin $AXELERA_ENV/bin/axdevice --refresh
TimeoutStartSec=90
Restart=on-failure
RestartSec=15
[Install]
WantedBy=multi-user.target
UNIT
    systemd-analyze verify "/etc/systemd/system/$RECOVERY"
    systemctl daemon-reload
    # Boot-only: do not reset a card that could have an active inference workload.
    systemctl enable "$RECOVERY"
}

verify_intel() {
    (( HAS_GPU || HAS_NPU )) || return 0
    [[ -x $INTEL_ENV/bin/python ]] || die 'Intel runtime environment is missing; run install first'
    runuser -u "$TARGET_USER" -- "$INTEL_ENV/bin/python" - "$HAS_GPU" "$HAS_NPU" <<'PY'
import sys
import numpy as np
import openvino as ov
from openvino import opset13 as ops
core = ov.Core()
expected_devices = [name for name, present in zip(('GPU', 'NPU'), sys.argv[1:]) if present == '1']
print('OpenVINO devices:', core.available_devices)
rng = np.random.default_rng(42)
data = rng.random((1, 32), dtype=np.float32)
weights = rng.random((32, 16), dtype=np.float32)
parameter = ops.parameter([1, 32], np.float32)
model = ov.Model([ops.relu(ops.matmul(parameter, ops.constant(weights), False, False))], [parameter])
for device in expected_devices:
    assert device in core.available_devices, f'{device} is missing'
    result = next(iter(core.compile_model(model, device)([data]).values()))
    np.testing.assert_allclose(result, data @ weights, rtol=0.01, atol=0.05)
    print(device, core.get_property(device, 'FULL_DEVICE_NAME'), 'inference PASS')
PY
    if (( HAS_GPU )); then
        runuser -u "$TARGET_USER" -- clinfo -l
        local render
        render="/dev/dri/by-path/pci-$GPU_BDF-render"
        [[ -e $render ]] || die 'Intel GPU render node was not found'
        runuser -u "$TARGET_USER" -- vainfo --display drm --device "$render"
    fi
}

verify_device() {
    local firmware_pending=0
    if [[ -f $STATE/native-boot-id && $(<"$STATE/native-boot-id") == "$(</proc/sys/kernel/random/boot_id)" ]]; then
        note 'Reboot first, then rerun verify to test startup without recovery'; return 20
    fi
    if [[ -r $STATE/expected-axelera ]] && ((${#AXELERA_BDFS[@]} != $(<"$STATE/expected-axelera"))); then
        die 'Axelera card count changed or a card is missing after boot; PCI enumeration must be resolved'
    fi
    systemctl is-enabled ssh
    systemctl is-active ssh
    ss -lnt | grep -E ':22[[:space:]]' >/dev/null || die 'No SSH listener on port 22'
    if systemctl is-enabled --quiet "$RECOVERY" 2>/dev/null; then
        systemctl is-active --quiet "$RECOVERY" || die 'Axelera recovery unit has not completed successfully'
        note "Startup recovery is enabled ($RECOVERY); this does not prove native startup"
    fi
    verify_intel
    if ((${#AXELERA_BDFS[@]})); then
        [[ -x $AXELERA_ENV/bin/axdevice ]] || die 'Axelera runtime environment is missing'
        local status flashed controller action model_directory reported validation_output
        status=$(runuser -u "$TARGET_USER" -- env PATH="$AXELERA_ENV/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$AXELERA_ENV/bin/axdevice" -v)
        printf '%s\n' "$status"
        reported=$(grep -c '^Device [0-9][0-9]*:' <<< "$status" || true)
        (( reported == ${#AXELERA_BDFS[@]} )) || die 'Axelera runtime did not enumerate every expected PCI device'
        # Check every enumerated card, not just the first one.
        local line
        while IFS= read -r line; do
            [[ $line == Device\ * ]] || continue
            flashed=$(sed -n 's/.*flver=\([0-9][0-9.]*\).*/\1/p' <<< "$line")
            controller=$(sed -n 's/.*bcver=\([0-9][0-9.]*\).*/\1/p' <<< "$line")
            action=$(firmware_action "$flashed" "$controller")
            if [[ $action != current ]]; then
                note "Axelera firmware differs from the tested baseline: firmware $flashed, controller $controller"
                firmware_pending=1
            fi
        done <<< "$status"
        model_directory=$(runuser -u "$TARGET_USER" -- mktemp -d /tmp/axelera-verify.XXXXXX)
        if ! runuser -u "$TARGET_USER" -- env PATH="$AXELERA_ENV/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            "$AXELERA_ENV/bin/axdownloadmodel" yolov5s-v7-coco --axm --dest "$model_directory"; then
            rm -rf -- "$model_directory"; die 'Could not download the Axelera verification model'
        fi
        local result=0
        validation_output=$(runuser -u "$TARGET_USER" -- env PATH="$AXELERA_ENV/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            timeout 90 "$AXELERA_ENV/bin/axrunmodel" "$model_directory/yolov5s-v7-coco.axm" --seconds 3 --verify every --no-aipu-tracer 2>&1) || result=$?
        printf '%s\n' "$validation_output"
        rm -rf -- "$model_directory"
        (( result == 0 )) || die 'Axelera inference failed'
        grep -Eq 'validation: ok validated all [1-9][0-9]* checked frames' <<< "$validation_output" || die 'Axelera did not confirm output validation'
        local dkms_status
        dkms_status=$(dkms status -m metis -v "$METIS_VERSION" -k "$(uname -r)")
        printf '%s\n' "$dkms_status"
        grep -Fq "metis/$METIS_VERSION, $(uname -r), $(uname -m): installed" <<< "$dkms_status" || die 'Metis DKMS is not installed for the running kernel'
    fi
    if [[ -e /var/run/reboot-required ]]; then note 'Reboot required before signoff'; return 20; fi
    if (( firmware_pending )); then note 'Hardware checks ran; firmware baseline review/update is required before signoff'; return 20; fi
    rm -f "$STATE/native-boot-id"
    note 'LOCAL VERIFICATION PASSED'
    printf 'Now test SSH from another device: ssh %s@<device-ip>\n' "$TARGET_USER"
    printf 'Local IP addresses: '; hostname -I
}

firmware_action() {
    local flashed=$1 controller=$2
    [[ $flashed =~ ^[0-9]+(\.[0-9]+)*$ && $controller =~ ^[0-9]+(\.[0-9]+)*$ ]] || die 'Invalid firmware version'
    if ! dpkg --compare-versions "$controller" ge 7.0 || ! dpkg --compare-versions "$flashed" ge 1.4.0; then printf 'legacy\n'
    elif dpkg --compare-versions "$flashed" gt "$AXELERA_VERSION" || dpkg --compare-versions "$controller" gt "$CONTROLLER_VERSION"; then printf 'newer\n'
    elif [[ $flashed == "$AXELERA_VERSION" && $controller == "$CONTROLLER_VERSION" ]]; then printf 'current\n'
    else printf 'update\n'; fi
}

legacy_action() {
    local flashed=$1 controller=$2
    [[ $flashed =~ ^[0-9]+(\.[0-9]+)*$ && $controller =~ ^[0-9]+(\.[0-9]+)*$ ]] || die 'Invalid firmware version'
    if dpkg --compare-versions "$flashed" lt 1.4.0; then printf 'enable\n'
    elif [[ $flashed == 1.4.0 ]] && dpkg --compare-versions "$controller" lt 7.0; then printf 'controller\n'
    elif dpkg --compare-versions "$flashed" ge 1.4.0 && dpkg --compare-versions "$controller" ge 7.0; then printf 'complete\n'
    else die 'This legacy firmware combination needs vendor guidance; no downgrade will be attempted'; fi
}

fetch_verified() {
    local url=$1 destination=$2 digest=$3
    if [[ ! -f $destination ]] || ! verify_archive "$destination" "$digest"; then download "$url" "$destination"; fi
    verify_archive "$destination" "$digest" || die "Artifact checksum mismatch: $destination"
}

operator_confirm() {
    local reply
    [[ -t 0 ]] || die 'Run finish-setup.sh interactively in a terminal'
    read -r -p "$1" reply
    [[ $reply == "$2" ]] || die 'Cancelled; no further action taken'
}

request_power_cycle() {
    note 'Firmware stage complete — a full power cycle is required'
    printf '%s\n' 'Once the PC is fully off, unplug its power for at least 10 seconds.' \
        'Reconnect power, boot, and run: bash finish-setup.sh'
    operator_confirm 'Press Enter to shut down now: ' ''
    sync
    systemctl poweroff
    return 20
}

firmware_stage_complete() {
    if [[ $MODE == finish ]]; then
        cat /proc/sys/kernel/random/boot_id > "$STATE/firmware-power-cycle-boot-id"
        rm -f "$STATE/native-boot-id" "$STATE/finish-complete"
        request_power_cycle
    else
        note 'Vendor stage returned successfully. Follow its power-cycle instruction, then rerun firmware'
    fi
    return 20
}

axelera_versions() {
    [[ -x $AXELERA_ENV/bin/axdevice ]] || die 'Install the Axelera runtime first'
    local status
    status=$(env PATH="$AXELERA_ENV/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$AXELERA_ENV/bin/axdevice")
    printf '%s\n' "$status"
    FLASHED_VERSION=$(sed -n 's/.*flver=\([0-9][0-9.]*\).*/\1/p' <<< "$status")
    BOARD_CONTROLLER=$(sed -n 's/.*bcver=\([0-9][0-9.]*\).*/\1/p' <<< "$status")
}

prepare_native_boot() {
    ((${#AXELERA_BDFS[@]})) || die 'Axelera must be present before preparing a native startup test'
    if systemctl cat "$RECOVERY" >/dev/null 2>&1; then systemctl disable "$RECOVERY"; fi
    printf '%s\n' "${#AXELERA_BDFS[@]}" > "$STATE/expected-axelera"
    cat /proc/sys/kernel/random/boot_id > "$STATE/native-boot-id"
}

finish_setup() {
    local boot_id action
    boot_id=$(</proc/sys/kernel/random/boot_id)
    if [[ -e $STATE/firmware-power-cycle-boot-id ]]; then
        if [[ $(<"$STATE/firmware-power-cycle-boot-id") == "$boot_id" ]]; then request_power_cycle; fi
        operator_confirm 'Did you disconnect power for at least 10 seconds after the last flash? Type YES: ' YES
        rm "$STATE/firmware-power-cycle-boot-id"
    fi
    if [[ -e $STATE/install-boot-id && $(<"$STATE/install-boot-id") == "$boot_id" ]]; then
        operator_confirm 'Installation needs a reboot. Press Enter to reboot, then rerun finish-setup.sh: ' ''
        systemctl reboot
        return 20
    fi
    if ((${#AXELERA_BDFS[@]})); then
        ((${#AXELERA_BDFS[@]} == 1)) || die 'Automatic firmware setup supports one Axelera card; see docs/maintenance.md'
        axelera_versions
        action=$(firmware_action "$FLASHED_VERSION" "$BOARD_CONTROLLER")
        [[ $action != newer ]] || die 'Firmware is newer than this baseline; automatic downgrades are not supported'
        if [[ $action != current ]]; then
            printf '%s\n' 'The next Axelera firmware stage is ready. Stop inference jobs and keep power connected during flashing.' \
                'Someone must be here to unplug power after the updater finishes. Answer any vendor prompts carefully.'
            operator_confirm 'Type UPDATE to start this stage: ' UPDATE
            POWER_READY=1
            if [[ $action == legacy ]]; then LEGACY=1; else LEGACY=0; fi
            firmware_update
            note 'Rerun bash finish-setup.sh to continue'
            return 20
        fi
        if [[ ! -e $STATE/finish-complete ]]; then
            if [[ ! -e $STATE/native-boot-id ]]; then prepare_native_boot; fi
            if [[ $(<"$STATE/native-boot-id") == "$boot_id" ]]; then
                operator_confirm 'Firmware is current. Press Enter for the final startup reboot, then rerun finish-setup.sh: ' ''
                systemctl reboot
                return 20
            fi
        fi
    fi
    verify_device
    touch "$STATE/finish-complete"
    note 'SETUP COMPLETE — local driver, inference, and SSH checks passed'
}

legacy_firmware_update() {
    local directory="$CACHE/legacy-1.4.0" runtime device status flashed controller action secure
    install -d -m 0700 "$directory"
    # Package digests are from the vendor's signed stable index; artifacts stay outside the repository.
    fetch_verified https://software.axelera.ai/artifactory/axelera-apt-source/axelera-runtime/axelera-runtime_1.4.0-1_amd64.deb \
        "$directory/runtime.deb" dd6fabe8407556200b0a3121a5b5e95fb0421d10c720d61af2862dd8a815dbd3
    fetch_verified https://software.axelera.ai/artifactory/axelera-apt-source/axelera-device/axelera-device_1.4.0-1_amd64.deb \
        "$directory/device.deb" a62838f436c3be036610c3988531e2d01bb4fb46e40dc118446753c71a378332
    fetch_verified https://axelera-public.s3.eu-central-1.amazonaws.com/aipu_firmware_enabler/voyager-sdk-v1.4.0/enable_bootloader_update.sh \
        "$directory/enable_bootloader_update.sh" 0bb7fa83cfe5dd62fe6efb176343493fb34210becc59a95f6246daaa59f55e08
    install -d -m 0700 "$directory/root" "$directory/run"
    dpkg-deb -x "$directory/runtime.deb" "$directory/root"
    dpkg-deb -x "$directory/device.deb" "$directory/root"
    runtime="$directory/root/opt/axelera/runtime-1.4.0-1"
    device="$directory/root/opt/axelera/device-1.4.0-1/omega"
    if LD_LIBRARY_PATH="$runtime/lib" ldd "$runtime/bin/triton_multi_ctx" | grep -q 'not found'; then
        die 'A legacy runtime library is missing; resolve dependencies before flashing'
    fi
    status=$(LD_LIBRARY_PATH="$runtime/lib" "$runtime/bin/triton_multi_ctx" --flashver)
    printf '%s\n' "$status"
    flashed=$(sed -n 's/.*version: \([0-9][0-9.]*\).*/\1/p' <<< "$status")
    status=$(LD_LIBRARY_PATH="$runtime/lib" "$runtime/bin/triton_multi_ctx" --bc-version)
    printf '%s\n' "$status"
    controller=$(sed -n 's/^app version:[[:space:]]*v\([0-9][0-9.]*\).*/\1/p' <<< "$status")
    action=$(legacy_action "$flashed" "$controller")
    if [[ $action == complete ]]; then
        note 'Legacy stage is complete. Run firmware again without --legacy for the current baseline'; return 0
    fi
    secure=$(LD_LIBRARY_PATH="$runtime/lib" "$runtime/bin/triton_multi_ctx" --get-secure-boot)
    grep -q '^Chip Secure Status: unsecure' <<< "$secure" || die 'This public legacy bundle supports non-secure cards only; contact the vendor for a matching secure bundle'
    if systemctl cat "$RECOVERY" >/dev/null 2>&1; then systemctl disable --now "$RECOVERY"; fi
    if [[ $action == enable ]]; then
        note 'Running unmodified vendor bootloader enablement and intermediate firmware stage'
        (cd "$directory/run"; env PATH="$runtime/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            LD_LIBRARY_PATH="$runtime/lib" AXELERA_DEVICE_DIR="$device" bash "$directory/enable_bootloader_update.sh")
    else
        note 'Running unmodified vendor intermediate board-controller stage'
        env PATH="$runtime/bin:/usr/sbin:/usr/bin:/sbin:/bin" LD_LIBRARY_PATH="$runtime/lib" \
            AXELERA_DEVICE_DIR="$device" AIPU_RUNTIME_STAGE0_OMEGA="$device/bin/start_axelera_runtime_stage0.bin" \
            bash "$device/firmware/interactive_flash_update.sh"
    fi
    firmware_stage_complete
}

firmware_update() {
    ((${#AXELERA_BDFS[@]})) || { note 'No Axelera hardware detected; firmware step skipped'; return 0; }
    (( POWER_READY )) || die 'Firmware requires --power-cycle-ready and physical access to power; nothing was flashed'
    [[ -t 0 && -r /dev/tty ]] || die 'Run firmware interactively in a terminal'
    ((${#AXELERA_BDFS[@]} == 1)) || die 'Firmware mode supports one card; use vendor tooling for multi-card systems'
    command -v lsof >/dev/null || die 'Install lsof before firmware work'
    lsof -t /dev/metis* >/dev/null 2>&1 && die 'Stop active Axelera workloads before flashing'
    if (( LEGACY )); then legacy_firmware_update; return; fi
    axelera_versions
    local action
    action=$(firmware_action "$FLASHED_VERSION" "$BOARD_CONTROLLER")
    if [[ $action == legacy ]]; then
        note 'LEGACY FIRMWARE PREPARATION REQUIRED — NOTHING FLASHED'
        printf '%s\n' \
            'Firmware is below 1.4.0 or controller is below 7.0. Complete vendor enablement and the staged Voyager 1.4 procedure first.' \
            'With stable power and someone present, rerun this firmware command with --legacy --power-cycle-ready.' \
            'https://github.com/axelera-ai-hub/voyager-sdk/blob/release/v1.4/docs/tutorials/enable_updates.md' \
            'https://github.com/axelera-ai-hub/voyager-sdk/blob/release/v1.4/docs/tutorials/firmware_flash_update.md'
        return 20
    fi
    if [[ $action == newer ]]; then
        die 'Firmware is newer than this baseline; automatic downgrades are not supported'
    fi
    if [[ $action == current ]]; then
        note 'Firmware already matches this baseline. Use native-boot, reboot, then verify'; return 0
    fi
    if systemctl cat "$RECOVERY" >/dev/null 2>&1; then systemctl disable --now "$RECOVERY"; fi
    # Keep the official sequence and safety checks intact. No --force or piped yes.
    env PATH="$AXELERA_ENV/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$AXELERA_ENV/bin/axdevice" interactive_flash_update
    firmware_stage_complete
}

main() {
    parse_args "$@"
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    check_platform
    detect_hardware
    if [[ $MODE == plan ]]; then
        printf 'Ubuntu 24.04 amd64\nIntel GPU: %s\nIntel NPU: %s\nAxelera cards: %s\n' "$HAS_GPU" "$HAS_NPU" "${#AXELERA_BDFS[@]}"
        printf 'No packages, services, reboots, or firmware were changed.\n'; return
    fi
    (( EUID == 0 )) || die 'Run this mode with sudo'
    if ! [[ $TARGET_USER =~ ^[a-z_][a-z0-9_-]*\$?$ && $TARGET_USER != root ]] || ! id -- "$TARGET_USER" >/dev/null 2>&1; then
        die 'Specify an existing non-root account with --user'
    fi
    umask 077
    install -d -m 0700 "$STATE" "$CACHE" /var/log/device-onboard
    exec 9>/run/device-onboard.lock
    flock -n 9 || die 'Another onboarding operation is running'
    exec > >(tee -a "/var/log/device-onboard/$(date +%Y%m%d-%H%M%S)-$MODE.log") 2>&1
    trap 'error_status=$?; if (( error_status != 20 )); then printf "ERROR: operation failed at line %s; review the log.\n" "$LINENO" >&2; fi' ERR
    if [[ -r $STATE/expected-axelera ]] && ((${#AXELERA_BDFS[@]} < $(<"$STATE/expected-axelera"))); then
        die 'A previously detected Axelera card is missing; resolve PCI enumeration before proceeding'
    fi
    if [[ $MODE == firmware ]] && ((${#AXELERA_BDFS[@]})) && [[ ! -e $STATE/expected-axelera ]]; then
        printf '%s\n' "${#AXELERA_BDFS[@]}" > "$STATE/expected-axelera"
    fi
    case $MODE in
        install)
            export DEBIAN_FRONTEND=noninteractive
            note 'Base packages and remote access'
            apt-get update
            apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y
            apt-get install -y linux-generic-hwe-24.04 linux-firmware \
                ca-certificates curl wget gnupg software-properties-common pciutils usbutils \
                python3-venv openssh-server sudo
            systemctl enable --now ssh
            printf '%s\n' "${#AXELERA_BDFS[@]}" > "$STATE/expected-axelera"
            note 'Intel drivers and inference runtime'; install_intel
            note 'Optional Axelera driver and runtime'; install_axelera
            if (( HAS_NPU )); then update-initramfs -u -k all; fi
            dpkg-query -W > "$STATE/package-versions.txt"
            cat /proc/sys/kernel/random/boot_id > "$STATE/install-boot-id"
            rm -f "$STATE/finish-complete" "$STATE/native-boot-id"
            note 'INSTALLATION FINISHED — REBOOT AND VERIFY BEFORE SIGNOFF'
            printf 'After reboot, run: bash finish-setup.sh\n'
            if (( REBOOT )); then systemctl reboot; else return 20; fi ;;
        verify) verify_device ;;
        finish) finish_setup ;;
        firmware) firmware_update ;;
        native-boot)
            prepare_native_boot
            note 'Recovery disabled. Reboot, then run verify to test native startup'
            if (( REBOOT )); then systemctl reboot; else return 20; fi ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
