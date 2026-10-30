# Set up the device

Use Ubuntu 24.04 amd64, an administrator account, and an Internet connection. Intel GPU/NPU must be enabled in BIOS. For Axelera, this setup requires Secure Boot to be off.

## 1. Copy and paste this into the device's terminal

```bash
sudo apt-get update && sudo apt-get install -y curl ca-certificates tar && \
mkdir -p "$HOME/edge-device-setup" && \
curl -fL https://github.com/ApexFlo-Labs/edge-device-onboarding/archive/refs/heads/main.tar.gz -o "$HOME/edge-device-setup/source.tar.gz" && \
tar -xzf "$HOME/edge-device-setup/source.tar.gz" --strip-components=1 -C "$HOME/edge-device-setup" && \
bash "$HOME/edge-device-setup/setup.sh"
```

Enter your password when asked. Wait for installation to finish. The device will restart. **Git is not needed.**

## 2. After it restarts, copy and paste this

```bash
bash "$HOME/edge-device-setup/finish-setup.sh"
```

Follow the instructions on screen:

- If asked to update Axelera, type `UPDATE`. Keep power connected while it flashes.
- Only after the update finishes successfully, press Enter to shut down. Wait until the PC is fully off, unplug power for **10 seconds**, reconnect it, and turn it on.
- After **every** restart or power cycle, paste the same command from step 2 again. Older Axelera cards may need four power cycles, followed by a normal restart.

**You are done when it prints `SETUP COMPLETE`.** The final terminal report shows PASS/SKIPPED, installed driver/runtime versions, and Axelera firmware/controller versions. Without Axelera, its installation and firmware steps are skipped automatically.

Copy the SSH command printed at the end into another computer's terminal to test access. Network/VPN enrollment is separate.

If a step fails, stop and read the error. Do not remove power during a flash. Logs are in `/var/log/device-onboard/`. [Technical reference](docs/maintenance.md).

The guided flow has simulated safety tests. Pilot a complete fresh-device setup before fleet rollout.
