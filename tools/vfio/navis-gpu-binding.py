#!/usr/bin/env python3
"""NVIDIA/VFIO binding and recovery primitives for the Windows controller."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import time

PCI = Path('/sys/bus/pci/devices')
DEVICES = {'0000:01:00.0': ('0x25a5', 'nvidia'),
           '0000:01:00.1': ('0x2291', 'snd_hda_intel')}
MODULES = ['nvidia', 'nvidia_modeset', 'nvidia_uvm', 'nvidia_drm']
STATE = Path('/run/navis-windows-gpu')


def run(*args, check=True, timeout=35):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.run(args, check=check, timeout=timeout)


def driver(address):
    link = PCI / address / 'driver'
    return link.resolve().name if link.exists() else None


def write(path, value):
    print(f'write {path}: {value!r}', flush=True)
    Path(path).write_text(value + '\n')


def preflight():
    if os.uname().nodename != 'navis':
        raise RuntimeError('GPU handoff is restricted to navis.')
    if not Path('/dev/kvm').exists():
        raise RuntimeError('/dev/kvm is missing.')
    for address, (device_id, expected_driver) in DEVICES.items():
        dev = PCI / address
        if (dev / 'vendor').read_text().strip() != '0x10de' or \
                (dev / 'device').read_text().strip() != device_id:
            raise RuntimeError(f'Unexpected hardware at {address}')
        group = dev / 'iommu_group/devices'
        if not group.exists() or {p.name for p in group.iterdir()} != set(DEVICES):
            raise RuntimeError(f'{address}: IOMMU group is missing or has other devices.')
        if driver(address) != expected_driver:
            raise RuntimeError(f'{address}: expected {expected_driver}, got {driver(address)}')
        if (dev / 'driver_override').read_text().strip() not in ('', '(null)'):
            raise RuntimeError(f'{address}: a driver override already exists.')
        print(f'{address}: {expected_driver}; isolated NVIDIA GPU/audio group', flush=True)
    if (PCI / '0000:00:02.0/driver').resolve().name != 'i915':
        raise RuntimeError('Expected the Intel GPU to remain on i915.')
    for command in ('systemctl', 'systemd-run', 'modprobe', 'nvidia-smi'):
        if not shutil.which(command):
            raise RuntimeError(f'Missing command: {command}')
    run('modinfo', 'vfio_pci', check=True)
    run('nvidia-smi')
    print('Preflight passed. No drivers or services changed.', flush=True)


def save_state():
    consoles = [str(p / 'bind') for p in Path('/sys/class/vtconsole').glob('vtcon*')
                if 'frame buffer' in (p / 'name').read_text()
                and (p / 'bind').read_text().strip() == '1']
    data = {
        'modules': [m for m in MODULES if Path('/sys/module', m).exists()],
        'consoles': consoles,
        'display_active': subprocess.run(
            ['systemctl', 'is-active', '--quiet', 'display-manager']).returncode == 0,
    }
    temp = STATE / 'state.tmp'
    temp.write_text(json.dumps(data))
    temp.replace(STATE / 'state.json')


def exercise(*, preserve_desktop=False):
    # The snapshot exists before any change; ExecStopPost also runs on failure.
    preflight()
    save_state()
    if not preserve_desktop:
        run('systemctl', 'stop', 'display-manager')
        run('systemctl', '--user', '--machine=marshall@.host', 'stop',
            'hyprland-session.target', 'graphical-session.target')
        time.sleep(2)
    data = json.loads((STATE / 'state.json').read_text())
    for console in data['consoles']:
        write(console, '0')
    # Do not force unload or kill remaining GPU clients. A busy module aborts
    # the test and sends control to recovery instead.
    for module in reversed(data['modules']):
        run('modprobe', '-r', module, timeout=15)
    run('modprobe', 'vfio_pci')
    for address in DEVICES:
        dev = PCI / address
        write(dev / 'driver_override', 'vfio-pci')
        if driver(address):
            write(dev / 'driver/unbind', address)
        write('/sys/bus/pci/drivers_probe', address)
        if driver(address) != 'vfio-pci':
            raise RuntimeError(f'{address} failed to bind to VFIO')
    print('VFIO_BIND_PASS: both GPU and audio are bound to vfio-pci.', flush=True)
    (STATE / 'bound').touch()


def recover(*, preserve_desktop=False):
    snapshot = STATE / 'state.json'
    if not snapshot.exists():
        print('No hardware changes were started; no recovery needed.', flush=True)
        return
    data = json.loads(snapshot.read_text())
    errors = []

    def attempt(label, action):
        try:
            action()
        except Exception as exc:
            errors.append(f'{label}: {exc}')
            print('RECOVERY ERROR:', errors[-1], flush=True)

    for address, (_, expected) in DEVICES.items():
        dev = PCI / address

        def restore_device(dev=dev, address=address, expected=expected):
            current = driver(address)
            if current not in (None, expected, 'vfio-pci'):
                raise RuntimeError(f'Refusing to detach unexpected driver {current}')
            # Block automatic reprobe until the original driver is selected.
            write(dev / 'driver_override', expected)
            if current == 'vfio-pci':
                write(dev / 'driver/unbind', address)
            run('modprobe', expected)
            if driver(address) is None:
                write('/sys/bus/pci/drivers_probe', address)
            if driver(address) != expected:
                raise RuntimeError(f'Expected {expected}, got {driver(address)}')

        attempt(address, restore_device)
        attempt(f'{address} clear override', lambda dev=dev: write(dev / 'driver_override', ''))
    for module in data['modules']:
        attempt(module, lambda module=module: run('modprobe', module))
    for console in data['consoles']:
        attempt(console, lambda console=console: write(console, '1'))
    attempt('NVIDIA health', lambda: run('nvidia-smi', timeout=20))
    if data['display_active'] and not preserve_desktop:
        attempt('restart desktop', lambda: run('systemctl', 'start', 'display-manager'))
    if errors:
        raise RuntimeError('Recovery had errors; inspect the log. A reboot may be needed.')
    if (STATE / 'bound').exists():
        print('ROUNDTRIP_PASS: NVIDIA -> VFIO -> NVIDIA; ' + ('compositor recovery pending.' if preserve_desktop else 'desktop service restarted.'), flush=True)
        print('Driver restoration alone does not verify display output or session preservation.', flush=True)
    else:
        print('RESTORED_AFTER_ABORT: Linux restored, but VFIO binding did not complete.', flush=True)
