#!/usr/bin/env python3
"""Live GPU attachment and removal without shutting Windows down."""
import fcntl
import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import time
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('gpu', HERE / 'navis-windows-gpu.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
spec = importlib.util.spec_from_file_location('preserve', HERE / 'navis-hyprland-preserve.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
STATE = g.STATE


def guest_ps(script, timeout=90):
    pid = g.agent({'execute': 'guest-exec', 'arguments': {
        'path': r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        'arg': ['-NoProfile', '-NonInteractive', '-Command', script],
        'capture-output': True}})['pid']
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = g.agent({'execute': 'guest-exec-status', 'arguments': {'pid': pid}})
        if result.get('exited'):
            output = base64.b64decode(result.get('out-data', '')).decode('utf-8', errors='replace')
            error = base64.b64decode(result.get('err-data', '')).decode('utf-8', errors='replace')
            if result.get('exitcode') != 0:
                raise RuntimeError('Windows command failed: ' + output + error)
            return output.strip()
        time.sleep(1)
    raise RuntimeError(f'Windows command PID {pid} timed out; do not duplicate it.')


def boot_identity():
    return guest_ps('(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")')


def update_state():
    """Read-only hints; Windows Update exposes no atomic maintenance lock."""
    state = json.loads(guest_ps(r'''$ErrorActionPreference = 'Stop'
$installer = New-Object -ComObject Microsoft.Update.Installer
$system = New-Object -ComObject Microsoft.Update.SystemInfo
@{
    busy = [bool]$installer.IsBusy
    reboot = [bool]($system.RebootRequired -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
} | ConvertTo-Json -Compress
''', timeout=25))
    if not isinstance(state, dict) or any(type(state.get(k)) is not bool for k in ('busy', 'reboot')):
        raise RuntimeError('Windows Update status could not be verified.')
    return state


def check_updates():
    state = update_state()
    if state['busy'] or state['reboot']:
        raise RuntimeError('Windows Update is busy or needs a restart. Let it finish in Windows before switching GPUs; no shutdown requested.')


def wait_for_hotplug_devices():
    # A running guest agent is ready before Windows has enumerated a newly
    # attached PCI function. The cold-boot probe is too early on this path.
    output = guest_ps(r'''
$ErrorActionPreference = 'Stop'
$deadline = (Get-Date).AddSeconds(60)
do {
    $d = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' })
    $ids = @($d.PNPDeviceID)
    if (($ids -match 'DEV_25A5') -and ($ids -match 'DEV_2291')) {
        $d | Select-Object Name,PNPDeviceID,Status,ConfigManagerErrorCode | ConvertTo-Json
        exit 0
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
$d | Select-Object Name,PNPDeviceID,Status,ConfigManagerErrorCode | ConvertTo-Json
throw 'Windows did not enumerate both NVIDIA functions within 60 seconds.'
''', timeout=85)
    print(output, flush=True)


def live_devices():
    return ET.fromstring(g.virsh('dumpxml', g.UUID).stdout).findall('devices/hostdev')


def assert_gpu_released():
    if g.guest_state() != 'shut off' and live_devices():
        raise RuntimeError('Guest still owns host devices; refusing NVIDIA rebind.')
    # Libvirt removal must also have released QEMU's VFIO group descriptor.
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            for fd in (proc / 'fd').iterdir():
                try:
                    target = str(fd.readlink())
                except FileNotFoundError:
                    continue
                if target == '/dev/vfio/15' or target.startswith('/dev/vfio/devices/'):
                    raise RuntimeError(f'VFIO device is still open in process {proc.name}.')
        except (FileNotFoundError, ProcessLookupError):
            continue


def set_virtual_display(enabled):
    verb = 'Enable' if enabled else 'Disable'
    # Only the specific emulated VGA; never disable an arbitrary display adapter.
    return guest_ps('$ErrorActionPreference="Stop"; '
        '$d=@(Get-PnpDevice -Class Display -PresentOnly | '
        'Where-Object {$_.InstanceId -like "PCI\\VEN_1234&DEV_1111*"}); '
        'if ($d.Count -ne 1) {throw "Expected exactly one virtual VGA"}; '
        f'$d | {verb}-PnpDevice -Confirm:$false; '
        '$d | Select-Object FriendlyName,InstanceId | ConvertTo-Json')


def check_ready():
    g.preflight()
    if g.guest_state() != 'running' or live_devices():
        raise RuntimeError('Expected the running background VM with no host devices.')
    root = ET.fromstring(g.virsh('dumpxml', g.UUID).stdout)
    if int(root.findtext('memory')) != 48 * 1024 * 1024:
        raise RuntimeError('Expected the 48 GiB configuration.')
    actual = json.loads(g.virsh('qemu-monitor-command', g.UUID,
                               '{"execute":"query-balloon"}').stdout)['return']['actual']
    if actual != 48 * 1024**3:
        raise RuntimeError('Restore the balloon to 48 GiB before GPU attachment.')
    ports = {d['qdev_id']: d for bus in json.loads(g.virsh('qemu-monitor-command', g.UUID,
        '{"execute":"query-pci"}').stdout)['return'] for d in bus.get('devices', [])}
    ranges = ports['pci.6']['pci_bridge']['bus']
    for name, minimum in [('memory_range', 32 * 1024**2), ('prefetchable_range', 8 * 1024**3)]:
        area = ranges[name]
        if area['limit'] - area['base'] + 1 < minimum:
            raise RuntimeError('GPU hotplug address space is too small: ' + name)
    for index in ('6', '7'):
        target = root.find(f"devices/controller[@type='pci'][@index='{index}']/target")
        if target is None or target.get('hotplug') != 'on':
            raise RuntimeError('Expected hotplug enabled only on the GPU ports.')
    check_updates()
    g.status('Background Windows, update status, memory, and GPU port reservations verified.')


def attach(path):
    # Record the attempt first; even a timed-out command may attach a device.
    (STATE / 'warm-attach-attempted').touch()
    g.virsh('attach-device', g.UUID, str(path), '--live', timeout=45)


def exercise():
    check_ready()
    (STATE / 'warm-boot-before').write_text(boot_identity())
    preserve = h.begin(g)
    g.release_herdr_gpu()
    if preserve:
        g.stop_t3_desktop(graceful=True)
    else:
        g.stop_t3_desktop()
    g.start_t3_server()
    g.pause_host_gpu_probes()
    g.command('systemctl', 'start', 'getty@tty3.service')
    if preserve:
        h.park(g)
        g.binding.exercise(preserve_desktop=True)
    else:
        g.status('Closing Linux graphics; attaching NVIDIA to already-running Windows.')
        g.binding.exercise()
    g.restore_intel_console()
    attach(STATE / 'gpu-hotplug.xml')
    attach(STATE / 'audio-hotplug.xml')
    for path in sorted(STATE.glob('warm-usb-*.xml')):
        attach(path)
    wait_for_hotplug_devices()
    (STATE / 'guest-detected').touch()
    g.verify_nvidia_driver()
    # Physical output must not compete with the background virtual desktop.
    # Mark before changing it, so recovery restores it even if the command times out.
    (STATE / 'warm-vga-change-attempted').touch()
    print(set_virtual_display(False), flush=True)
    (STATE / 'warm-attached').touch()
    g.wait_for_t3_server()
    g.status('Windows is ready. Use Switch to Linux to return; Windows will stay running.')
    g.wait_for_windows_shutdown()


def detach_all():
    devices = live_devices()
    # Return input devices and audio first; detach the GPU last.
    devices.sort(key=lambda d: d.find('alias') is not None and
                 d.find('alias').get('name') == 'ua-warm-gpu')
    for index, device in enumerate(devices):
        path = STATE / f'warm-detach-{index}.xml'
        path.write_text(ET.tostring(device, encoding='unicode'))
        result = g.virsh('detach-device', g.UUID, str(path), '--live', timeout=20, check=False)
        if result.returncode:
            raise RuntimeError('Guest device removal request failed: ' + result.stderr)
    deadline = time.monotonic() + 30
    while live_devices() and time.monotonic() < deadline:
        time.sleep(1)
    assert_gpu_released()


def recover():
    g.status('Returning NVIDIA to Linux without shutting Windows down.')
    preserved = False
    same_boot = False
    if (STATE / 'warm-attach-attempted').exists() and g.guest_state() != 'shut off':
        # Failure leaves Windows and VFIO intact. Never convert a failed switch
        # into a guest shutdown, including during Windows Update.
        if (STATE / 'warm-vga-change-attempted').exists():
            print(set_virtual_display(True), flush=True)
        detach_all()
        preserved = True
        try:
            before = (STATE / 'warm-boot-before').read_text().strip()
            after = boot_identity()
            (STATE / 'warm-boot-after').write_text(after)
            same_boot = bool(before) and after == before
            if not same_boot:
                g.status('Windows boot-time value changed; continuity is unproven. Keeping Windows running.')
        except Exception as exc:
            g.status('Cannot verify Windows boot continuity; keeping it running: ' + str(exc))
    assert_gpu_released()
    g.stop_t3_server()
    preserve = h.state_file(g).exists()
    if (STATE / 'state.json').exists():
        if preserve:
            g.binding.recover(preserve_desktop=True)
        else:
            g.binding.recover()
    if preserve:
        h.restore(g)
    (STATE / 'recovered').touch()
    g.resume_host_gpu_probes()
    if preserved:
        (STATE / 'warm-preserved').touch()
        # Only cap CPU use. Keep all 48 GiB to avoid slow memory expansion
        # on the next switch. Throttling must not invalidate GPU recovery.
        try:
            check_updates()
            g.virsh('schedinfo', g.UUID, '--live', '--set', 'cpu_shares=256',
                    '--set', 'global_quota=200000')
        except Exception as exc:
            g.status('Leaving Windows resources available: ' + str(exc))
        if same_boot:
            (STATE / 'warm-returned').touch()
            label = 'WARM_GPU_ROUNDTRIP_PASS' if (STATE / 'warm-attached').exists() else 'WARM_DEVICE_RETURN_PASS'
            g.status(label + ': Windows boot-time value unchanged; Linux GPU restored.')
        else:
            g.status('WINDOWS_PRESERVED: devices released and Linux restored; boot continuity unproven.')
    else:
        g.status('Linux recovery complete; no running Windows attachment to preserve.')


def start(*, base):
    if g.active(g.UNIT):
        raise RuntimeError('A GPU session or recovery is already running.')
    if (STATE / 'state.json').exists() and not (STATE / 'recovered').exists():
        raise RuntimeError('Previous GPU recovery is incomplete.')
    if h.state_file(g).exists() and json.loads(h.state_file(g).read_text())['phase'] not in ('returned', 'fresh-desktop-fallback'):
        raise RuntimeError('Previous Hyprland preservation recovery is incomplete.')
    check_ready()
    base = Path(base)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Retain old diagnostic files, but no stale success/recovery markers.
    for name in ('state.json', 'bound', 'guest-start-attempted', 'guest-detected',
                 'driver-passed', 'recovered', 't3-start-attempted', 'hyprland-preserve.json'):
        (STATE / name).unlink(missing_ok=True)
    for path in STATE.glob('warm-*'):
        if path.is_file():
            path.unlink()
    (STATE / 'options.json').write_text(json.dumps({'vm': 'win11-native', 'controller': 'navis-windows-switch.py'}))
    for name in ('navis-windows-switch.py', 'navis-windows-gpu.py', 'navis-gpu-binding.py',
                 'navis-hyprland-preserve.py'):
        shutil.copyfile(HERE / name, STATE / name)
        (STATE / name).chmod(0o700)
    for name in ('gpu-hotplug.xml', 'audio-hotplug.xml'):
        shutil.copyfile(base / name, STATE / name)
    for i, device in enumerate(g.usb_devices()):
        ET.SubElement(device, 'alias', name=f'ua-warm-usb-{i}')
        (STATE / f'warm-usb-{i}.xml').write_text(ET.tostring(device, encoding='unicode'))
    logfile = base / ('gpu-hotplug-' + time.strftime('%H%M%S') + '.log')
    script = STATE / 'navis-windows-switch.py'
    exe = str(Path(sys.executable).resolve())
    g.command('systemctl', 'reset-failed', g.UNIT, check=False)
    g.command('systemd-run', '--unit=' + g.UNIT, '--collect', '--no-block',
              '--description=Windows live GPU session and recovery',
              '--property=Type=exec',
              '--property=After=navis-windows-background.service',
              '--property=RuntimeMaxSec=infinity',
              '--property=TimeoutStopSec=300s',
              '--property=ExecStopPost=' + exe + ' ' + str(script) + ' _recover',
              '--property=StandardOutput=append:' + str(logfile),
              '--property=StandardError=append:' + str(logfile),
              '--setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin',
              '--setenv=PYTHONDONTWRITEBYTECODE=1',
              exe, str(script), '_run')
    print('Windows GPU session started. Log: ' + str(logfile), flush=True)

BASE = Path('/var/lib/navis-windows-switch/state')
BACKGROUND = 'navis-windows-background.service'
REQUEST = 'navis-windows-request.service'
QEMU = '{http://libvirt.org/schemas/domain/qemu/1.0}'


def background_xml(source):
    root = ET.fromstring(source)
    if root.findtext('uuid') != g.UUID or root.findtext('name') != g.VM:
        raise RuntimeError('Unexpected Windows domain identity.')
    if root.findall('devices/hostdev'):
        raise RuntimeError('Background domain must not assign host devices.')
    if root.find('devices/video/model').get('type') != 'vga':
        raise RuntimeError('Expected the tested virtual VGA configuration.')
    root.find('memory').text = str(48 * 1024 * 1024)
    root.find('memory').set('unit', 'KiB')
    root.find('currentMemory').text = str(48 * 1024 * 1024)
    root.find('currentMemory').set('unit', 'KiB')
    for index in ('6', '7'):
        root.find(f"devices/controller[@type='pci'][@index='{index}']/target").set('hotplug', 'on')
    tune = root.find('cputune')
    if tune is None:
        tune = ET.SubElement(root, 'cputune')
    for key, value in [('shares', '256'), ('global_period', '100000'), ('global_quota', '200000')]:
        node = tune.find(key)
        if node is None:
            node = ET.SubElement(tune, key)
        node.text = value
    override = root.find(QEMU + 'override')
    if override is None:
        override = ET.SubElement(root, QEMU + 'override')
    if override.find(QEMU + "device[@alias='pci.6']") is not None:
        raise RuntimeError('GPU port override already exists; review it before replacing.')
    frontend = ET.SubElement(ET.SubElement(override, QEMU + 'device', alias='pci.6'), QEMU + 'frontend')
    for key, value in [('mem-reserve', 32 * 1024**2), ('pref64-reserve', 8 * 1024**3)]:
        ET.SubElement(frontend, QEMU + 'property', name=key, type='unsigned', value=str(value))
    ET.indent(root)
    return ET.tostring(root, encoding='unicode')


def prepare():
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    source = g.virsh('dumpxml', g.UUID, '--inactive').stdout
    g.check_existing_disk(source)
    candidate = background_xml(source)
    (BASE / 'background.xml').write_text(candidate)
    g.command('virt-xml-validate', str(BASE / 'background.xml'), 'domain')
    # Generate the exact guest port/address layout validated in the live trial.
    for name, function, bus in [('gpu', '0', '6'), ('audio', '1', '7')]:
        d = ET.Element('hostdev', mode='subsystem', type='pci', managed='no')
        src = ET.SubElement(d, 'source')
        ET.SubElement(src, 'address', domain='0x0000', bus='0x01', slot='0x00', function='0x' + function)
        ET.SubElement(d, 'alias', name='ua-warm-' + name)
        ET.SubElement(d, 'address', type='pci', domain='0x0000', bus='0x0' + bus, slot='0x00', function='0x0')
        (BASE / (name + '-hotplug.xml')).write_text(ET.tostring(d, encoding='unicode'))


def ensure_share():
    # The VM can reach its login screen before the foreground switch is ever
    # requested. Bring up its network/share during background startup too.
    if 'default' not in g.virsh('net-list', '--name').stdout.split():
        g.virsh('net-start', 'default')
    g.ensure_share()


def background():
    ensure_share()
    if g.guest_state() == 'running':
        if live_devices():
            raise RuntimeError('Existing Windows session still owns host devices; leaving it untouched.')
        g.status('Windows already runs in the background; no restart requested.')
        return
    if g.guest_state() != 'shut off':
        raise RuntimeError('Windows is not ready to start; leaving it untouched.')
    prepare()
    g.virsh('create', str(BASE / 'background.xml'), '--validate', timeout=90)
    g.status('Windows booting in the background. Linux keeps NVIDIA.')


def wait_agent():
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        try:
            g.agent({'execute': 'guest-ping'})
            return
        except Exception:
            time.sleep(3)
    raise RuntimeError('Windows is not ready yet; left running without interrupting boot or updates.')


def foreground():
    if g.active(g.UNIT):
        raise RuntimeError('A GPU switch/session is already active.')
    if (g.STATE / 'state.json').exists() and not (g.STATE / 'recovered').exists():
        raise RuntimeError('Previous GPU return is incomplete; use Switch to Linux to retry.')
    g.command('systemctl', 'start', BACKGROUND, timeout=120)
    # A manual Windows shutdown leaves the oneshot service active.
    if g.guest_state() == 'shut off':
        background()
    wait_agent()
    check_updates()
    if live_devices():
        raise RuntimeError('Windows already owns host devices; refusing another attachment.')
    g.preflight()
    g.status('Removing the background CPU limit; Windows keeps its existing 48 GiB.')
    g.virsh('schedinfo', g.UUID, '--live', '--set', 'cpu_shares=1024', '--set', 'global_quota=-1')
    start(base=BASE)


def return_linux():
    if g.active(REQUEST):
        raise RuntimeError('Windows preparation is still running; wait for the switch to finish.')
    if g.active(g.UNIT):
        g.command('systemctl', 'stop', '--no-block', g.UNIT)
    elif ((g.STATE / 'state.json').exists() or (g.STATE / 'hyprland-preserve.json').exists()) and not (g.STATE / 'recovered').exists():
        # Retry a failed safe removal using its original root-owned snapshot.
        options = json.loads((g.STATE / 'options.json').read_text())
        controller = options.get('controller', 'navis-warm-gpu-test.py')
        if controller not in ('navis-windows-switch.py', 'navis-windows-session.py', 'navis-warm-gpu-test.py'):
            raise RuntimeError('Unexpected recovery controller in the saved session.')
        script = g.STATE / controller
        if not script.exists():
            raise RuntimeError('No warm-switch recovery snapshot; refusing the old shutdown-based recovery.')
        g.command('systemd-run', '--unit=navis-windows-return', '--collect', '--no-block',
                  '--property=TimeoutStartSec=300', 'python3', str(script), '_recover')
    else:
        g.status('Linux already owns the desktop.')


def shutdown():
    # Only the background service's ExecStop calls this. No hard timeout or
    # destroy fallback: Windows may need time to finish servicing updates.
    if g.guest_state() == 'shut off':
        return
    requested = False
    while g.guest_state() != 'shut off':
        if not requested:
            for mode in ('agent', 'acpi'):
                result = g.virsh('shutdown', g.UUID, '--mode', mode, check=False)
                if result.returncode == 0:
                    requested = True
                    g.status('Waiting for Windows to shut down cleanly before Linux stops.')
                    break
        time.sleep(5)

def request_windows():
    g.command('systemctl', 'start', '--no-block', REQUEST)
    print('Preparing Windows. Linux stays available until GPU handoff.', flush=True)


def run_foreground():
    with open('/run/navis-windows-gpu-launch.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        foreground()


def recover_service():
    if g.command('systemctl', 'is-system-running', check=False).stdout.strip() != 'stopping':
        recover()


def main():
    # Fixed launcher/systemd operations, not a general-purpose CLI.
    actions = {'windows': request_windows, 'linux': return_linux,
               'background': background, 'shutdown': shutdown,
               '_foreground': run_foreground, '_run': exercise,
               '_recover': recover_service, '_remember': h.remember}
    if len(sys.argv) != 2 or sys.argv[1] not in actions or os.geteuid() != 0:
        raise RuntimeError('Use the installed Windows/Linux switch control.')
    if sys.argv[1] in ('_run', '_recover') and HERE != STATE:
        raise RuntimeError('Internal actions require the root-owned recovery snapshot.')
    actions[sys.argv[1]]()


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        g.status('Switch stopped safely: ' + str(exc))
        try:
            g.command('runuser', '-u', 'marshall', '--', 'env',
                      'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus',
                      '/home/marshall/.nix-profile/bin/notify-send',
                      'Windows switch stopped', str(exc), check=False, timeout=5)
        except Exception:
            pass
        raise SystemExit(1)
