# Set up an edge device

For Ubuntu 24.04 amd64 devices with Intel Core Ultra GPU/NPU and an **optional Axelera card**. Use an existing administrator account and an Internet connection. Enable the Intel GPU/NPU in BIOS; the included Axelera installation requires Secure Boot to be disabled.

## 1. Download and install

[Download the ZIP](https://github.com/ApexFlo-Labs/edge-device-onboarding/archive/refs/heads/main.zip), extract it, and open a terminal in the extracted folder. Keep the whole folder together. **Git is not required.** The installer installs curl and the other prerequisites itself.

```bash
bash setup.sh
```

Enter your sudo password. This installs updates, Intel GPU/NPU drivers, OpenSSH, and Axelera software **only if an Axelera card is detected**, then reboots.

## 2. Finish setup

After reboot, open a terminal in the same folder:

```bash
bash finish-setup.sh
```

Follow the prompts. The script picks the correct firmware stage automatically; you do not choose legacy/current modes or flags.

- **No Axelera card:** skips all Axelera work and runs the final checks.
- **Axelera needs firmware:** type `UPDATE` when ready. Keep power connected while flashing. Only after the updater succeeds, press Enter to shut down. Wait until the PC is fully off, unplug power for **at least 10 seconds**, reconnect, and boot. Run `bash finish-setup.sh` again. Older cards can need four such power cycles.
- **Firmware is current:** the script offers a normal reboot to check startup without recovery. After reboot, run `bash finish-setup.sh` again.

Repeat only `finish-setup.sh` until it prints **SETUP COMPLETE**. It remembers progress; do not rerun installation between firmware stages. If an update fails, stop and inspect the log; do not interrupt a flash or treat failure as permission to remove power.

## Done

The final script checks SSH, Intel GPU/NPU inference, GPU compute/media access, and—when fitted—Axelera firmware, driver, and validated inference. Then test login **from another computer**:

```bash
ssh your-user@device-ip
```

Network/VPN enrollment is handled separately. Logs are in `/var/log/device-onboard/`. Exit `20` means follow the printed reboot/power-cycle step; other nonzero exits mean an error. This flow supports one Axelera card per device.

Hardware checks and the four-stage vendor update passed on a 285H + Metis 110m device. The new guided flow has automated safety/phase tests; a complete fresh-device pilot is still required before fleet rollout. [Maintainer reference, pinned versions, and troubleshooting](docs/maintenance.md).
