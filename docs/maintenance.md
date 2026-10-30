# Maintainer reference

Onboard Ubuntu 24.04 amd64 devices with Intel Core Ultra integrated GPU/NPU hardware and an **optional Axelera accelerator**. One Bash script installs the software, checks the hardware, runs verified vendor firmware stages, and performs acceptance tests.

The normal operator flow is documented in [the short setup guide](../README.md): run `setup.sh`, then repeat `finish-setup.sh` as prompted. This document covers the underlying engine and manual maintenance commands. OpenSSH is configured here; network and VPN enrollment are managed separately.

## Requirements

- Ubuntu 24.04 amd64, Internet access, and an existing non-root administrator account.
- For Intel Core Ultra devices, enable the integrated GPU and NPU in the BIOS.
- For Axelera firmware work, have someone at the device who can remove and reconnect power. Use stable power; a UPS is recommended for controller flashing.
- The included Axelera installation requires Secure Boot to be disabled. Signed-module enrollment is a separate provisioning path; the script does not change Secure Boot settings.

The script detects hardware through PCI sysfs. **If no Axelera card is detected, it skips its repository, driver, build dependencies, runtime, model download, and firmware operations.** If a card recorded during installation disappears after reboot, verification fails rather than silently skipping it.

## Quick start

Run these commands on the device, as the existing administrator:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/ApexFlo-Labs/edge-device-onboarding.git
cd edge-device-onboarding
bash onboard-device.sh plan
sudo bash onboard-device.sh install --user "$USER" --reboot
```

Alternatively, download and inspect `onboard-device.sh` without cloning the repository. Run it with Bash. The installer updates Ubuntu, installs the HWE kernel and common prerequisites, enables OpenSSH, and installs the drivers and isolated runtimes appropriate to the detected hardware. It requests a reboot only when `--reboot` is provided.

For a 285H device, `plan` should show Intel GPU `1` and NPU `1`. Resolve unexpected missing hardware before installation. Axelera may correctly show `0`.

After reboot, reconnect and run:

```bash
cd edge-device-onboarding
sudo bash onboard-device.sh verify --user "$USER"
```

For a device with no Axelera card, proceed directly to the final checks below. With Axelera, inspect its reported flashed firmware and controller versions and follow the appropriate firmware path before final signoff.

## Tested software baseline

| Component | Baseline |
| --- | --- |
| OS | Ubuntu 24.04 amd64 with the HWE kernel |
| Intel compute/media packages | Intel-recommended graphics PPA |
| Intel NPU firmware, compiler, and Level Zero | 1.38.0 |
| OpenVINO | 2026.3.1 |
| Axelera runtime | 1.9.0 |
| Metis DKMS | 1.7.16 |
| Axelera flashed firmware | 1.9.0 |
| Axelera board controller | 7.5 |

The NPU release, runtime versions, Metis driver, and legacy firmware artifacts are pinned. Graphics and Ubuntu packages follow their configured repositories; installed versions are recorded. Review the baseline when vendor packages change. Do not force a downgrade if the device is already newer.

## Firmware rules

Software installation **never flashes hardware**. Firmware is a separate interactive command. `--power-cycle-ready` means an operator is present, understands the process, and can carry out each requested power cycle.

1. Stop all accelerator inference jobs before firmware work.
2. Keep power connected while upload, erase, programming, or activation is in progress. Do not reboot, suspend, or run system updates during a flash.
3. Wait until the vendor updater reports the stage complete and the command has returned successfully. The wrapper normally returns exit `20` to indicate the required manual action.
4. Then shut the OS down:

   ```bash
   sudo systemctl poweroff
   ```

5. Wait until the PC is fully off. Disconnect its power cable for **at least 10 seconds**, reconnect power, and boot it.
6. Reconnect, return to this repository, and run the next indicated firmware command. A warm reboot does **not** replace a requested full power cycle.

If a firmware command fails, read its log and the vendor instructions. Do not interpret failure as permission to power-cycle mid-write. Do not blindly retry a partial controller flash; the controller has no recovery region. The script invokes the vendor procedures without editing their safety checks or answering prompts automatically.

Only one detected Axelera card is supported by the firmware wrapper. Use the vendor's per-device procedure for multi-card systems. Legacy public bundles are limited to non-secure cards; the wrapper refuses other secure states.

## Legacy Axelera path

Use this path when flashed firmware is below `1.4.0` or the controller is below `7.0`, such as firmware `1.3.2` / controller `1.4`:

```bash
sudo bash onboard-device.sh firmware --legacy --user "$USER" --power-cycle-ready
```

The command downloads checksum-pinned vendor tools into an isolated cache; it does not replace the installed current runtime. It determines the next stage from the actual flashed firmware and controller versions.

| Starting state | What the command does | What to do afterward |
| --- | --- | --- |
| Flashed firmware below 1.4.0 | Runs the vendor's unmodified bootloader-enablement procedure, including the intermediate 1.4.0 firmware | Follow the full power-cycle procedure, then run the same `--legacy` command again |
| Firmware 1.4.0, controller below 7.0 | Runs the unmodified intermediate controller updater to 7.0 | Follow the full power-cycle procedure, then run the same `--legacy` command again |
| Firmware at least 1.4.0, controller at least 7.0 | Reports the legacy stages complete | Continue below **without** `--legacy` |

Unsupported mixed versions are refused instead of being downgraded. Legacy enablement updates the bootloader and has a higher recovery risk than a normal dual-slot firmware update. Keep an operator present and follow the [vendor enablement guide](https://github.com/axelera-ai-hub/voyager-sdk/blob/release/v1.4/docs/tutorials/enable_updates.md) and [intermediate update guide](https://github.com/axelera-ai-hub/voyager-sdk/blob/release/v1.4/docs/tutorials/firmware_flash_update.md).

## Current Axelera firmware path

Once the legacy prerequisites are satisfied:

```bash
sudo bash onboard-device.sh firmware --user "$USER" --power-cycle-ready
```

| Starting state | Vendor stage | What to do afterward |
| --- | --- | --- |
| Supported older firmware, controller at least 7.0 | Updates flashed firmware to 1.9.0 | Full power cycle, then repeat the command |
| Firmware 1.9.0, older supported controller | Updates controller to 7.5 | Full power cycle, then repeat the command |
| Firmware 1.9.0 and controller 7.5 | Reports the baseline current | Proceed to the native startup test |

Always follow the actual updater's output if it requests additional steps. The wrapper refuses automatic downgrades. See the [current firmware procedure](https://docs.axelera.ai/sdk/user-guides/firmware-update/) and [compatibility matrix](https://docs.axelera.ai/sdk/release-compatibility-matrix/).

## Test startup without a recovery workaround

The default installation does not add a recovery service. If the managed service exists, this command disables it and records the current boot ID and expected card count:

```bash
sudo bash onboard-device.sh native-boot --user "$USER" --reboot
```

After the reboot:

```bash
sudo bash onboard-device.sh verify --user "$USER"
```

Verification refuses to use the same boot session as evidence of native startup and fails if a previously detected card disappears. Review any separately installed custom accelerator initialization services as well; this script manages only `device-onboard-axelera.service`.

For a device with a diagnosed startup problem that cannot yet be resolved, the recovery workaround is explicitly opt-in:

```bash
sudo bash onboard-device.sh install --user "$USER" --with-axelera-recovery --reboot
```

It derives the PCIe parent from detected hardware, refuses a port shared with another vendor, and attempts initialization at most four times with 15 seconds between failures. It does not monitor or restart inference applications. Inference services using it should start after `device-onboard-axelera.service`.

## Final acceptance checks

`verify` runs accelerator checks as the target account, without root device privileges. Confirm all of the following before handoff:

- The intended kernel has booted and no further reboot is pending.
- OpenSSH is enabled, active, and listening on port 22.
- Intel GPU and NPU enumeration and numerical inference pass for the detected hardware.
- Intel GPU OpenCL and VA-API checks pass.
- If fitted, every expected Axelera card is present; the flashed firmware/controller match the baseline; a vendor model runs with all checked output frames validated; DKMS is installed for the running kernel.
- If removing recovery, the device passes after both a full power cycle and a subsequent normal reboot with recovery disabled.
- The actual application runs correctly under a representative sustained workload. The included three-second model test is a smoke test, not a stability or application-accuracy benchmark.

Finally, test SSH **from another device** over the network you configured:

```bash
ssh your-user@device-ip
```

The local check cannot prove external routing, firewall/VPN policy, or successful authentication. Do not replace existing SSH configuration or firewall policy merely to make the local test pass; diagnose external connectivity separately.

## Logs and exit codes

- Logs: `/var/log/device-onboard/`.
- Package and runtime inventories, expected card count, and reboot state: `/var/lib/device-onboard/`.
- Download cache and isolated legacy utilities: `/var/cache/device-onboard/`.
- Installed runtime environments: `/opt/device-onboard/intel` and `/opt/device-onboard/axelera`.
- Exit `0`: the requested operation completed; `verify` reports local acceptance checks passed.
- Exit `20`: a reboot, requested power cycle, or firmware baseline action/review is still required.
- Other nonzero exits: stop and inspect the error and log.

Use `--intel-env` and `--axelera-env` to verify an existing installation in other directories. The script does not create users or contain account passwords, enrollment keys, or device-specific network addresses.

## Validation and maintenance

Run non-installing checks on Ubuntu:

```bash
bash -n onboard-device.sh
shellcheck onboard-device.sh
bash tests/test-onboard.sh ./onboard-device.sh
bash onboard-device.sh plan
```

Tests cover argument rejection, artifact verification, corrupted-download rejection, firmware routing and downgrade gates, absent optional Axelera hardware, missing expected cards, and verification before reboot. Hardware validation uses Intel numerical inference and a vendor-compiled Axelera model with output verification. A complete fresh-device installation still needs a pilot on the intended image before broad deployment.

### Hardware validation on 30 October 2026

On an Intel Core Ultra 9 285H device with a non-secure Metis 110m card, the unmodified vendor procedures completed the legacy enablement, intermediate controller, current firmware, and current controller stages. The card moved from firmware 1.3.2 / controller 1.4 through 1.4.0 / 7.0 to **1.9.0 / 7.5**, with four full power cycles.

The published script's `verify` mode passed after the final cold boot and a subsequent normal reboot, using the device's existing runtime environments. Both boots enumerated the card with recovery disabled and without a manual PCIe rescan or `axdevice --refresh`. Intel GPU/NPU numerical inference, GPU OpenCL/media access, the active-kernel DKMS check, and external SSH login passed. The Axelera smoke tests validated all 1,457 frames after the cold boot and all 1,461 frames after the normal reboot. A further 30-second run validated all 14,976 frames. The obsolete custom recovery unit was then removed, with its backup retained outside the active systemd directory.

These results validate this device and the documented vendor sequence. The new install mode and integrated firmware wrapper still need a complete fresh-device pilot; the firmware stages on this device were invoked directly with the same vendor tools and environment used by the wrapper.

Vendor firmware and binary packages are downloaded from their official sources and are not redistributed in this repository.

## Guided setup state

`setup.sh` runs installation and requests a reboot. `finish-setup.sh` automatically selects the existing legacy/current vendor sequence, requires operator confirmation before each flash, and offers shutdown only after successful stage completion. A saved boot ID prevents a second stage in the same boot; after a new boot the operator must confirm actual power removal. A warm reboot alone cannot prove this.

The final Axelera startup test disables the managed recovery unit and requires another boot before verification. Completion is recorded only after verification succeeds. Re-running the finish script after completion reruns checks without repeating installation or the startup reboot. Run these additional non-installing checks from the repository root:

```bash
bash -n setup.sh finish-setup.sh onboard-device.sh
shellcheck setup.sh finish-setup.sh onboard-device.sh
bash tests/test-finish.sh ./onboard-device.sh
```

The guided finish script accepts the engine's `--user`, `--intel-env`, and `--axelera-env` overrides for existing installations. Log in as the intended non-root administrator for the normal two-script flow; direct root sessions must supply `--user`.
