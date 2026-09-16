#!/usr/bin/env python3
"""Preserve the opt-in physical Hyprland compositor across a Windows GPU switch."""
import json
import hashlib
import os
from pathlib import Path
import re
import signal
import socket
import struct
import time

ROOT = Path('/persist/var/lib/navis-hyprland-preserve')
PACKAGE = Path('/etc/navis-hyprland-preserve')
UID = 1000
PARK = 'MIGRATION-PARK'
MASKS = Path('/run/user/1000/systemd/user.control')
UNITS = ('caelestia.service', 'ranni-wallpaper.service',
         'xdg-desktop-portal-hyprland.service', 'xdg-desktop-portal-gtk.service',
         'xdg-desktop-portal.service')


def identity(pid):
    p = Path('/proc') / str(pid)
    if p.stat().st_uid != UID:
        raise RuntimeError('Unexpected compositor owner')
    return {'pid': pid, 'start': (p / 'stat').read_text().rsplit(')', 1)[1].split()[19],
            'exe': str((p / 'exe').resolve()), 'boot': Path('/proc/sys/kernel/random/boot_id').read_text().strip()}


def alive(session):
    try:
        return identity(session['process']['pid']) == session['process']
    except (OSError, RuntimeError):
        return False


def ipc(session, command, timeout=60):
    if not alive(session):
        raise RuntimeError('The original Hyprland process is no longer running')
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(timeout)
        connection.connect(session['ipc'])
        pid, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if pid != session['process']['pid'] or uid != UID:
            raise RuntimeError('Hyprland IPC peer does not match the preserved session')
        connection.sendall(command.encode())
        chunks = []
        while data := connection.recv(65536):
            chunks.append(data)
        return b''.join(chunks).decode().strip()


def request(session, command):
    result = ipc(session, command)
    if result != 'ok':
        raise RuntimeError(f'Hyprland rejected {command}: {result}')


def identify():
    executable = PACKAGE / 'libexec/Hyprland'
    if not executable.is_file():
        return None
    found = []
    expected_digest = None
    active = ROOT / 'active-executable'
    accepted = {str(executable.resolve())}
    if active.is_symlink() and active.lstat().st_uid == 0:
        accepted.add(str(active.resolve()))
    for lock in Path('/run/user/1000/hypr').glob('*/hyprland.lock'):
        try:
            pid = int(lock.read_text().splitlines()[0])
            process = identity(pid)
            if process['exe'] not in accepted:
                # A wrapper-only package update must still recognize the
                # identical immutable compositor that is already running.
                candidate = Path(process['exe'])
                if not str(candidate).startswith('/nix/store/') or candidate.name != 'Hyprland':
                    continue
                if expected_digest is None:
                    expected_digest = hashlib.sha256(executable.read_bytes()).digest()
                if hashlib.sha256(candidate.read_bytes()).digest() != expected_digest:
                    continue
            session = {'process': process, 'ipc': str(lock.parent / '.socket.sock'),
                       'wayland': lock.read_text().splitlines()[1]}
            if 'physical_enabled: true' not in ipc(session, '/migration status'):
                raise RuntimeError('The preservation compositor did not enable its physical backend')
            found.append(session)
        except (FileNotFoundError, ProcessLookupError, ValueError, IndexError):
            continue
    if len(found) > 1:
        raise RuntimeError('Multiple physical preservation sessions are running')
    return found[0] if found else None


def state_file(g):
    return g.STATE / 'hyprland-preserve.json'


def save(g, state):
    p = state_file(g)
    temp = p.with_suffix('.tmp')
    temp.write_text(json.dumps(state, indent=2))
    temp.chmod(0o600)
    temp.replace(p)


def wait_for(check, message, timeout=30):
    deadline = time.monotonic() + timeout
    while not check():
        if time.monotonic() >= deadline:
            raise RuntimeError(message)
        time.sleep(.2)


def begin(g):
    session = identify()
    if session is None:
        return False
    if 'drm_parked: true' in ipc(session, '/migration status'):
        raise RuntimeError('The physical compositor is already parked; recover it before switching')
    units = []
    for unit in UNITS:
        active = g.user_systemctl('is-active', unit, check=False).stdout.strip() == 'active'
        enabled = g.user_systemctl('is-enabled', unit, check=False).stdout.strip()
        units.append({'name': unit, 'active': active, 'was_masked': enabled.startswith('masked')})
    state = dict(session=session, units=units, masked=[], phase='closing-apps',
                 xwayland=json.loads(ipc(session, 'j/getoption xwayland:enabled'))['bool'])
    save(g, state)
    g.status('Keeping Hyprland alive. Requesting normal closure of Linux application windows; save prompts will stop the switch.')
    close_windows(session)
    return True


def close_windows(session):
    windows = json.loads(ipc(session, 'j/clients'))
    for window in windows:
        address = window['address']
        if not re.fullmatch(r'0x[0-9a-fA-F]+', address):
            raise RuntimeError('Unexpected window address')
        current = next((w for w in json.loads(ipc(session, 'j/clients')) if w['address'] == address), None)
        if current is None:
            continue
        if current['pid'] != window['pid']:
            raise RuntimeError('A window owner changed during closure; retry the switch')
        request(session, '/dispatch hl.dsp.window.close({window="address:' + address + '"})')
    wait_for(lambda: not json.loads(ipc(session, 'j/clients')),
             'Linux applications remain open. Save and close them, then retry; no applications were force-killed.', 45)


def close_clipboard_helpers(g, session):
    # wl-copy can daemonize after its parent window closes, retaining a render
    # node. Close only this seat's user-owned helper, never unrelated processes.
    display = session.get('wayland')
    if not display:
        raise RuntimeError('The compositor display identity is missing')
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            if proc.stat().st_uid != UID:
                continue
            executable = (proc / 'exe').resolve()
            if not str(executable).startswith('/nix/store/') or executable.name not in ('wl-copy', '.wl-copy-wrapped'):
                continue
            environment = (proc / 'environ').read_bytes().split(b'\0')
            if ('WAYLAND_DISPLAY=' + display).encode() not in environment:
                continue
            before = identity(int(proc.name))
            with_fd = os.pidfd_open(int(proc.name))
            try:
                if identity(int(proc.name)) != before:
                    raise RuntimeError('Clipboard helper identity changed')
                g.status('Closing the Linux clipboard helper before GPU release.')
                signal.pidfd_send_signal(with_fd, signal.SIGTERM)
            finally:
                os.close(with_fd)
        except (FileNotFoundError, ProcessLookupError):
            continue


def nvidia_path(path):
    if path.startswith('/dev/nvidia'):
        return True
    return path.startswith('/dev/dri/') and (Path('/sys/class/drm') / Path(path).name / 'device').resolve().name == '0000:01:00.0'


def holders():
    result = []
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            held = False
            for fd in (proc / 'fd').iterdir():
                try:
                    path = str(fd.readlink())
                    info = (proc / 'fdinfo' / fd.name).read_text().lower()
                    held |= nvidia_path(path) or 'exp_name:\tnv' in info
                except FileNotFoundError:
                    continue
            for line in (proc / 'maps').read_text().splitlines():
                parts = line.split(maxsplit=5)
                held |= len(parts) == 6 and nvidia_path(parts[5].removesuffix(' (deleted)'))
            if held:
                result.append(f"{proc.name} ({(proc / 'comm').read_text().strip()})")
        except (FileNotFoundError, ProcessLookupError):
            continue
        # Permissions and other read failures deliberately abort the handoff.
    return result


def render_node(pci):
    nodes = list((Path('/sys/bus/pci/devices') / pci / 'drm').glob('renderD*'))
    if len(nodes) != 1:
        raise RuntimeError(f'Expected one render node for {pci}')
    return '/dev/dri/' + nodes[0].name


def park(g):
    state = json.loads(state_file(g).read_text())
    session = state['session']
    # Stop desktop components without stopping graphical-session.target or the
    # seat/display manager. Prevent D-Bus activation from reopening GPU clients.
    for entry in state['units']:
        unit = entry['name']
        if not entry['was_masked']:
            if (MASKS / unit).exists() or (MASKS / unit).is_symlink():
                raise RuntimeError(f'Existing runtime control for {unit}; refusing to overwrite it')
            state['masked'].append(unit)
            save(g, state)  # record before installing the temporary mask
            # user.control outranks Home Manager's ~/.config unit files; the
            # ordinary systemctl --runtime mask directory does not.
            g.command('runuser', '-u', 'marshall', '--', 'mkdir', '-p', str(MASKS))
            mask = MASKS / unit
            mask.symlink_to('/dev/null')  # never overwrite an existing control
            g.user_systemctl('daemon-reload')
            g.user_systemctl('stop', unit, timeout=30)
            if g.user_systemctl('show', unit, '-p', 'LoadState', '--value').stdout.strip() != 'masked':
                raise RuntimeError(f'Could not prevent {unit} from reopening GPU clients')
    close_clipboard_helpers(g, session)
    request(session, '/eval hl.config({xwayland={enabled=false}})')
    reason = ['']
    def idle():
        reason[0] = ipc(session, '/migration can-release')
        return reason[0].startswith('CLIENTS_IDLE')
    try:
        wait_for(idle, 'Compositor clients did not release their GPU resources', 15)
    except RuntimeError as error:
        raise RuntimeError(f'{error}: {reason[0]}') from error
    request(session, '/output create headless ' + PARK)
    wait_for(lambda: any(m['name'] == PARK and m['width'] > 0 for m in json.loads(ipc(session, 'j/monitors'))),
             'Headless parking output did not become ready', 10)
    state['phase'] = 'park-requested'
    save(g, state)
    response = ipc(session, '/migration park ' + render_node('0000:00:02.0'))
    if not response.startswith('PARK_PASS'):
        raise RuntimeError(response)
    state['phase'] = 'parked'
    save(g, state)
    # Include background and inherited descriptors, not just visible windows.
    remaining = holders()
    if remaining:
        raise RuntimeError('NVIDIA is still held by: ' + ', '.join(remaining))
    g.status('Hyprland preserved on Intel; every process released NVIDIA. Proceeding to VFIO.')


def restore(g):
    path = state_file(g)
    if not path.exists():
        return False
    state = json.loads(path.read_text())
    session = state['session']
    preserved = alive(session)
    error = None
    try:
        if not preserved:
            raise RuntimeError('The experimental compositor exited')
        if 'drm_parked: true' in ipc(session, '/migration status'):
            response = ipc(session, '/migration resume ' + render_node('0000:01:00.0'))
            if not response.startswith('RESUME_PASS'):
                raise RuntimeError(response)
            wait_for(lambda: any(m['hardwareDetails']['backend'] == 'drm' and m['width'] > 0
                                 for m in json.loads(ipc(session, 'j/monitors'))),
                     'Physical displays did not return', 15)
        if any(m['name'] == PARK for m in json.loads(ipc(session, 'j/monitors'))):
            request(session, '/output remove ' + PARK)
        if state['xwayland']:
            request(session, '/eval hl.config({xwayland={enabled=true}})')
    except Exception as exc:
        preserved = False
        error = str(exc)
        g.status('Session preservation failed; restoring a fresh Linux desktop: ' + error)
    # Always remove only masks introduced by this switch.
    for unit in state['masked']:
        mask = MASKS / unit
        if mask.is_symlink() and str(mask.readlink()) == '/dev/null':
            mask.unlink()
        elif mask.exists() or mask.is_symlink():
            raise RuntimeError(f'Runtime control changed for {unit}; refusing to remove it')
    if state['masked']:
        g.user_systemctl('daemon-reload')
    if not preserved:
        # Hardware recovery has already verified that QEMU released the GPU.
        # Restarting the display service also removes a stuck preserved session.
        (ROOT / 'enabled').unlink(missing_ok=True)
        (ROOT / 'disabled').touch()
        g.command('systemctl', 'restart', 'display-manager', timeout=60)
    else:
        for entry in state['units']:
            if entry['active'] and not entry['was_masked']:
                g.user_systemctl('start', entry['name'], timeout=30)
    state['phase'] = 'returned' if preserved else 'fresh-desktop-fallback'
    state['error'] = error
    save(g, state)
    g.status('HYPRLAND_PRESERVED: compositor PID unchanged.' if preserved else 'Linux desktop recovery completed; session preservation did not pass.')
    return preserved


def remember():
    session = identify()
    if not session:
        return
    ROOT.mkdir(parents=True, exist_ok=True)
    executable = session['process']['exe']
    # Pin the running package before Nix replaces the /etc links.
    for link, target in (
        (ROOT / 'active-executable', executable),
        (Path('/nix/var/nix/gcroots/navis-hyprland-active'), Path(*Path(executable).parts[:4])),
    ):
        temporary = link.with_suffix('.new')
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(target)
        temporary.replace(link)
