#!/usr/bin/env python3
"""Exercise fast exits and APT permissions without changing the host system."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

engine = Path(sys.argv[1]).resolve()
bash = shutil.which('bash')
tee = shutil.which('tee')
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    tools = root / 'bin'
    tools.mkdir()
    delayed_tee = tools / 'tee'
    delayed_tee.write_text(f'#!/bin/sh\nsleep 0.2\nexec "{tee}" "$@"\n')
    delayed_tee.chmod(0o755)
    env = dict(os.environ, PATH=f'{tools}{os.pathsep}{os.environ["PATH"]}')
    worker = root / 'worker.sh'
    worker.write_text('''#!/usr/bin/env bash
set -Eeuo pipefail
source "$1"
STATE=$2
scenario=$3
MODE=finish
device_boot_id() { printf 'fixture-boot\\n'; }
sleep() { printf 'tick\\n' >> "$STATE/countdown"; }
sync() { :; }
systemctl() {
    [[ $1 == poweroff ]] || exit 99
    touch "$STATE/powered-off"
}
start_logging "$STATE/output.log"
case $scenario in
    missing|still-missing)
        printf '1\\n' > "$STATE/expected-axelera"
        AXELERA_BDFS=()
        if [[ $scenario == still-missing ]]; then printf 'earlier-boot\\n' > "$STATE/missing-axelera-boot-id"; fi
        require_expected_axelera
        printf 'UNEXPECTED_CONTINUE\\n' ;;
    failed-command) false ;;
    manual-action) printf 'POWER_CYCLE_REQUIRED\\n'; exit 20 ;;
esac
''')
    for scenario, expected in [('missing', 20), ('still-missing', 1), ('failed-command', 1), ('manual-action', 20)]:
        directory = root / scenario
        directory.mkdir()
        console = directory / 'console.txt'
        with console.open('w') as output:
            process = subprocess.Popen(
                [bash, str(worker), str(engine), str(directory), scenario],
                stdout=output, stderr=subprocess.STDOUT, env=env,
            )
            assert process.wait(timeout=10) == expected, scenario
        # Inspect immediately at parent exit: an unjoined, delayed tee would
        # still be asleep, reproducing the lost-output race in sudo's terminal.
        log = (directory / 'output.log').read_text()
        shown = console.read_text()
        if scenario == 'missing':
            for message in ['missing after reboot', '10 seconds', 'Shutting down in 30 seconds']:
                assert message in shown and message in log, (scenario, message, shown, log)
            assert 'UNEXPECTED_CONTINUE' not in shown
            assert 'SETUP COMPLETE' not in shown
            assert 'FAILED' not in shown
            assert (directory / 'powered-off').exists()
            assert len((directory / 'countdown').read_text().splitlines()) == 30
        elif scenario == 'still-missing':
            assert 'check the card/BIOS' in shown and 'check the card/BIOS' in log
            assert not (directory / 'powered-off').exists(), 'Must not create an endless shutdown loop'
        elif scenario == 'failed-command':
            assert 'Command: false' in shown and 'Command: false' in log
        else:
            assert 'POWER_CYCLE_REQUIRED' in shown and 'POWER_CYCLE_REQUIRED' in log
            assert 'FAILED' not in shown

    source = root / 'apt' / 'sources.list.d' / 'axelera.list'
    source.parent.mkdir(parents=True, mode=0o700)
    source.write_text('fixture\n')
    source.chmod(0o600)
    subprocess.run(
        [bash, '-c', 'source "$1"; umask 077; make_apt_file_readable "$2"', '_', str(engine), str(source)],
        check=True,
    )
    assert stat.S_IMODE(source.stat().st_mode) == 0o644
    assert stat.S_IMODE(source.parent.stat().st_mode) == 0o755
    absent = root / 'absent' / 'axelera.list'
    subprocess.run(
        [bash, '-c', 'source "$1"; make_apt_file_readable "$2"', '_', str(engine), str(absent)],
        check=True,
    )
    assert not absent.parent.exists(), 'Cardless fresh devices must not gain an Axelera source'
print('PASS: visible failures, 30-second power-cycle countdown, bounded retries, drained logs, and readable APT files')
