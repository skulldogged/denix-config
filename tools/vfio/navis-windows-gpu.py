#!/usr/bin/env python3
"""Shared host/guest checks and T3 handoff for the native Windows VM."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import urllib.request
import time
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
STATE = Path('/run/navis-windows-gpu')
UNIT = 'navis-windows-gpu.service'
UUID = 'e86ea874-5a2c-40f3-8393-9a812e77e3a2'
VM = 'win11-native'
WINDOWS_DISK = Path('/dev/disk/by-id/nvme-HFM512GD3JX013N_FYA7N020713207841')
WINDOWS_PARTUUID = '42ccd3b2-cc58-41ef-a4e9-a7ed0fe87e88'
T3_UNIT = 'navis-t3-server.service'
T3_URL = 'http://192.168.122.1:3774'
USB = [('3434', '0b10'), ('3434', 'd030'), ('046d', 'c547')]
USB_AUDIO = [('1038', '12e0'), ('3142', 'a008')]
HOST_GPU_PROBES = ('navis-hardware-telemetry.service',
                   'nvidia-container-toolkit-cdi-generator.service')
spec = importlib.util.spec_from_file_location('binding', HERE / 'navis-gpu-binding.py')
binding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binding)
binding.STATE = STATE


def status(message):
    line = time.strftime('%H:%M:%S') + ' ' + message
    print(line, flush=True)
    try:
        fd = os.open('/dev/tty3', os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            os.write(fd, ('\r\n[Windows GPU] ' + line + '\r\n').encode())
        finally:
            os.close(fd)
    except OSError:
        pass  # Logging must never block hardware recovery.


def restore_intel_console():
    if any(binding.driver(address) != 'vfio-pci' for address in binding.DEVICES):
        raise RuntimeError('Cannot restore Intel console before NVIDIA is detached.')
    framebuffers = {p.read_text().strip() for p in Path('/sys/class/graphics').glob('fb*/name')}
    if framebuffers != {'i915drmfb'}:
        raise RuntimeError('Expected only Intel framebuffer after NVIDIA release: ' + str(framebuffers))
    snapshot = json.loads((STATE / 'state.json').read_text())
    for console in snapshot['consoles']:
        binding.write(console, '1')
    status('Intel laptop console restored. Built-in keyboard: Ctrl+Alt+F3 for progress.')


def command(*args, check=True, timeout=30):
    return subprocess.run(args, check=check, timeout=timeout, capture_output=True,
                          text=True, env={**os.environ, 'LC_ALL': 'C'})


def virsh(*args, **kwargs):
    return command('virsh', '-c', 'qemu:///system', *args, **kwargs)


def agent(request):
    return json.loads(virsh('qemu-agent-command', UUID, json.dumps(request),
                           '--timeout', '8', timeout=12).stdout)['return']


def guest_state():
    return virsh('domstate', UUID).stdout.strip()


def active(unit):
    return command('systemctl', 'show', unit, '-p', 'ActiveState', '--value').stdout.strip() \
        in ('active', 'activating', 'deactivating', 'reloading')


def validate_windows_disk(rows):
    disks = [row for row in rows if row['serial'] == 'FYA7N020713207841']
    if len(disks) != 1 or disks[0]['size'] != 512110190592:
        raise RuntimeError('Existing Windows SSD identity/size changed.')
    if not any(row['partuuid'] == WINDOWS_PARTUUID for row in rows):
        raise RuntimeError('Existing Windows partition identity changed.')
    if any(any(row.get('mountpoints') or []) for row in rows):
        raise RuntimeError('Existing Windows SSD is mounted on Linux; unmount it first.')


def check_existing_disk(source):
    if Path('/run/navis-windows-storage-migration').exists():
        raise RuntimeError('Windows storage migration is in progress.')
    if command('blockdev', '--getro', str(WINDOWS_DISK)).stdout.strip() == '1':
        raise RuntimeError('The Windows SSD is protected read-only for isolated testing. '
                           'The direct-disk launcher is unavailable until testing is finished.')
    root = ET.fromstring(source)
    blocks = root.findall("devices/disk[@type='block']/source")
    if len(blocks) != 1 or blocks[0].get('dev') != str(WINDOWS_DISK):
        raise RuntimeError('Existing Windows VM does not reference the expected SSD.')
    rows = json.loads(command('lsblk', '--json', '--list', '--bytes', '--output',
        'PATH,SIZE,SERIAL,PARTUUID,MOUNTPOINTS', str(WINDOWS_DISK)).stdout)['blockdevices']
    validate_windows_disk(rows)
    paths = {str(Path(row['path']).resolve()) for row in rows}
    paths.update(str(Path(s.get('file')).resolve())
                 for s in root.findall('devices/disk/source') if s.get('file'))
    for domain in virsh('list', '--uuid').stdout.split():
        if domain == UUID:
            continue
        other = ET.fromstring(virsh('dumpxml', domain).stdout)
        for disk in other.findall('devices/disk/source'):
            path = disk.get('dev') or disk.get('file')
            if path and str(Path(path).resolve()) in paths:
                raise RuntimeError('Existing Windows storage is still attached to another running VM.')


def usb_devices():
    devices = []
    for vendor, product in USB + USB_AUDIO:
        device = ET.Element('hostdev', mode='subsystem', type='usb')
        source = ET.SubElement(device, 'source',
                               startupPolicy='optional' if (vendor, product) in USB_AUDIO else 'mandatory')
        ET.SubElement(source, 'vendor', id='0x' + vendor)
        ET.SubElement(source, 'product', id='0x' + product)
        devices.append(device)
    return devices


def preflight():
    binding.preflight()
    cli = Path('/home/marshall/.nix-profile/bin/t3').resolve()
    version = command('runuser', '-u', 'marshall', '--', str(cli), '--version').stdout.strip()
    # The checkout can contain a newer release that has not been activated yet.
    # Compare the installed launchers and live backend, not that future pin.
    desktop = Path('/home/marshall/.nix-profile/bin/t3code').resolve()
    if desktop.parent != cli.parent and str(cli.parent / 't3code') not in desktop.read_text():
        raise RuntimeError('Installed T3 CLI and desktop launchers are different builds.')
    runtime = Path('/home/marshall/.t3/userdata/server-runtime.json')
    if runtime.exists():
        pid = json.loads(runtime.read_text()).get('pid')
        exe = Path(f'/proc/{pid}/exe')
        if exe.exists() and cli.parent.parent not in exe.resolve().parents:
            raise RuntimeError('The running T3 backend and installed CLI are different builds.')
    print('T3 installed desktop/server build: ' + version, flush=True)
    current = guest_state()
    if current not in ('running', 'shut off'):
        raise RuntimeError('VM must be running normally or shut off: ' + current)
    if current == 'running':
        agent({'execute': 'guest-ping'})
    for vendor, product in USB:
        matches = [p for p in Path('/sys/bus/usb/devices').glob('*')
                   if (p / 'idVendor').exists()
                   and (p / 'idVendor').read_text().strip() == vendor
                   and (p / 'idProduct').read_text().strip() == product]
        if len(matches) != 1:
            raise RuntimeError(f'Expected exactly one USB device {vendor}:{product}, found {len(matches)}')
    source = virsh('dumpxml', UUID, '--inactive').stdout
    check_existing_disk(source)
    ensure_share()
    root = ET.fromstring(source)
    if root.findtext('uuid') != UUID or root.findtext('name') != VM:
        raise RuntimeError('Unexpected VM identity.')
    if root.findall('devices/hostdev'):
        raise RuntimeError('Persistent hostdev assignment requires review.')


def verify_nvidia_driver():
    script = r'''$ErrorActionPreference = 'Stop'
$logDirectory = "$env:ProgramData\NavisGpu"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Start-Transcript -Path (Join-Path $logDirectory ('driver-test-' + (Get-Date -Format yyyyMMdd-HHmmss) + '.log')) -Force | Out-Null
$deadline = (Get-Date).AddSeconds(120)
do {
    $gpu = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE&DEV_25A5*' } | Select-Object -First 1
    if ($gpu.ConfigManagerErrorCode -eq 0 -and $gpu.Name -like '*NVIDIA*') { break }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)
$gpu | Select-Object Name,PNPDeviceID,Status,ConfigManagerErrorCode | ConvertTo-Json
Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,Status,CurrentHorizontalResolution,CurrentVerticalResolution | ConvertTo-Json
if (-not $gpu -or $gpu.ConfigManagerErrorCode -ne 0 -or $gpu.Name -notlike '*NVIDIA*') {
    Write-Output 'NVIDIA_DRIVER_FAILED: device did not initialize successfully.'
    exit 4
}
$smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $smi) {
    $smi = Get-ChildItem "$env:windir\System32\DriverStore\FileRepository" -Filter nvidia-smi.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
}
if (-not $smi) { throw 'nvidia-smi was not found in the installed driver.' }
& $smi --query-gpu=name,driver_version,display_active --format=csv,noheader
if ($LASTEXITCODE -ne 0) { throw 'nvidia-smi could not communicate with the GPU.' }
Write-Output 'NVIDIA_DRIVER_PASS: device reports no error and nvidia-smi responds.'
Stop-Transcript | Out-Null
'''
    result = agent({'execute': 'guest-exec', 'arguments': {
        'path': r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        'arg': ['-NoProfile', '-NonInteractive', '-Command', script], 'capture-output': True}})
    pid = result['pid']
    status('Checking NVIDIA initialization.')
    deadline = time.monotonic() + 300
    next_progress = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = agent({'execute': 'guest-exec-status', 'arguments': {'pid': pid}})
        if result.get('exited'):
            output = ''
            for key in ('out-data', 'err-data'):
                if key in result:
                    decoded = base64.b64decode(result[key]).decode('utf-8', errors='replace')
                    print(decoded, flush=True)
                    if key == 'out-data':
                        output = decoded
            if result.get('exitcode') != 0 or 'NVIDIA_DRIVER_PASS:' not in output:
                raise RuntimeError('NVIDIA driver/display check did not finish successfully; see guest output.')
            (STATE / 'driver-passed').touch()
            return
        if time.monotonic() >= next_progress:
            status('Waiting for NVIDIA initialization.')
            next_progress = time.monotonic() + 10
        time.sleep(2)
    raise RuntimeError('NVIDIA driver/display check timed out.')


def wait_for_windows_shutdown():
    while True:
        try:
            if guest_state() == 'shut off':
                status('Windows has shut down; returning the GPU to Linux.')
                return
        except subprocess.SubprocessError as exc:
            # A temporary libvirt outage must not end a user's Windows session.
            status('Cannot query Windows right now; leaving the GPU assigned and retrying: ' + str(exc))
        time.sleep(5)


def nvidia_device_paths():
    paths = {str(p) for p in Path('/dev').glob('nvidia*')}
    for node in Path('/sys/class/drm').glob('*'):
        if (node / 'device').resolve().name == '0000:01:00.0':
            paths.add('/dev/dri/' + node.name)
    return paths


def herdr_gpu_holders():
    devices = nvidia_device_paths()
    found = []
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            if proc.stat().st_uid != 1000 or (proc / 'comm').read_text().strip() != 'herdr':
                continue
            if any(str(fd.resolve()) in devices for fd in (proc / 'fd').iterdir()):
                found.append(int(proc.name))
        except FileNotFoundError:
            pass
    return found


def release_herdr_gpu():
    holders = herdr_gpu_holders()
    if not holders:
        return
    status('Herdr is holding NVIDIA open; closing its terminal sessions before GPU handoff.')
    # Native orderly shutdown, not forced termination. Do this before stopping
    # Hyprland so a refusal leaves the Linux desktop available.
    command('runuser', '-u', 'marshall', '--',
        '/home/marshall/.nix-profile/bin/herdr', 'server', 'stop', timeout=20)
    deadline = time.monotonic() + 10
    while herdr_gpu_holders() and time.monotonic() < deadline:
        time.sleep(0.2)
    if herdr_gpu_holders():
        raise RuntimeError('Herdr still holds NVIDIA open; leaving Linux graphics running.')
    status('Herdr released NVIDIA.')


def desktop_t3_pids():
    """The headless service and every child in its cgroup must survive."""
    found = []
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            if proc.stat().st_uid != 1000 or (proc / 'comm').read_text().strip() != 't3code':
                continue
            if '/navis-t3-server.service' not in (proc / 'cgroup').read_text():
                found.append(int(proc.name))
        except FileNotFoundError:
            pass
    return found


def stop_t3_desktop():
    status('Closing the T3 desktop client before GPU handoff.')
    for sig, seconds in ((signal.SIGTERM, 8), (signal.SIGKILL, 3)):
        for pid in desktop_t3_pids():
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + seconds
        while desktop_t3_pids() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not desktop_t3_pids():
            break
    if desktop_t3_pids():
        raise RuntimeError('T3 desktop processes are still holding the GPU.')


def user_systemctl(*args, **kwargs):
    return command('systemctl', '--user', '--machine=marshall@.host', *args, **kwargs)


def start_t3_server():
    # Mark first: ExecStopPost must clean up even if start times out.
    (STATE / 't3-start-attempted').touch()
    user_systemctl('reset-failed', T3_UNIT, check=False)
    user_systemctl('start', '--no-block', T3_UNIT)
    status('Starting the Windows-accessible T3 server with the existing Linux data.')


def wait_for_t3_server():
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(T3_URL + '/api/auth/session', timeout=2) as response:
                if response.status == 200:
                    status('T3 server ready at ' + T3_URL)
                    return
        except OSError:
            pass
        time.sleep(0.5)
    raise RuntimeError('T3 server did not become ready; check its user-service journal.')


def stop_t3_server():
    if not (STATE / 't3-start-attempted').exists():
        return
    status('Stopping the T3 background server before restoring the Linux desktop.')
    user_systemctl('stop', T3_UNIT, timeout=65)
    state = user_systemctl('show', T3_UNIT, '-p', 'ActiveState', '--value').stdout.strip()
    if state not in ('inactive', 'failed'):
        raise RuntimeError('T3 background server has not stopped: ' + state)
    (STATE / 't3-start-attempted').unlink()


def pause_host_gpu_probes():
    units = [unit for unit in HOST_GPU_PROBES
             if command('systemctl', 'show', unit, '-p', 'LoadState', '--value').stdout.strip() == 'loaded']
    # Record before stopping so a partial failure still has a recovery path.
    (STATE / 'host-gpu-probes.json').write_text(json.dumps(units))
    if units:
        command('systemctl', 'stop', *units)
        status('Paused Linux NVIDIA telemetry and container-device probes.')


def resume_host_gpu_probes():
    snapshot = STATE / 'host-gpu-probes.json'
    if not snapshot.exists():
        return
    if binding.driver('0000:01:00.0') != 'nvidia':
        raise RuntimeError('Cannot resume Linux NVIDIA probes before the GPU is restored.')
    units = json.loads(snapshot.read_text())
    if any(unit not in HOST_GPU_PROBES for unit in units):
        raise RuntimeError('Unexpected host GPU probe service in recovery state.')
    snapshot.unlink()  # Release the unit condition before queuing their starts.
    if units:
        try:
            command('systemctl', 'start', '--no-block', *units)
        except Exception:
            snapshot.write_text(json.dumps(units))
            raise
        status('Resumed Linux NVIDIA telemetry and container-device probes.')


def ensure_share():
    if not os.path.ismount('/mnt/Shared'):
        raise RuntimeError('Shared NTFS partition is not mounted.')
    command('systemctl', 'start', 'samba-smbd.service')


if __name__ == '__main__':
    raise SystemExit('Use /etc/navis-windows-switch/windows-switch-control windows|linux.')
