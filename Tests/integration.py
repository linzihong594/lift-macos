#!/usr/bin/env python3
"""Exercise real disk images, without touching the user's apps or other volumes."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
ROOT = Path(tempfile.mkdtemp(prefix='DMGAutoEject-test-', dir='/private/tmp')).resolve()
APPLICATIONS = ROOT / 'Applications'
APPLICATIONS.mkdir()
MOUNTS = []
AGENT = None
REPORT = []


def run(*args):
    result = subprocess.run(list(map(str, args)), check=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=45)
    return result.stdout


def catalog():
    return plistlib.loads(run('/usr/bin/hdiutil', 'info', '-plist')).get('images', [])


def mounted(image):
    for entry in catalog():
        if entry.get('image-path') == str(image):
            return next((Path(e['mount-point']) for e in entry.get('system-entities', []) if e.get('mount-point')), None)
    return None


def wait_for(predicate, message, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        if AGENT is not None and AGENT.poll() is not None:
            raise AssertionError('agent exited unexpectedly: ' + AGENT.stderr.read().decode())
        time.sleep(.4)
    raise AssertionError(message)


def log():
    path = ROOT / 'agent.log'
    return path.read_text() if path.exists() else ''


def app_fixture(directory, name, version='1'):
    app = directory / (name + '.app')
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/Resources').mkdir()
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.test.' + name.replace(' ', ''),
        'CFBundleExecutable': 'Example', 'CFBundleVersion': version,
    }))
    executable = app / 'Contents/MacOS/Example'
    executable.write_text('#!/bin/sh\nexit 0\n')
    executable.chmod(0o755)
    (app / 'Contents/Resources/payload').write_bytes(b'correct-payload\n' * 8192)
    (app / 'Contents/Resources/link').symlink_to('payload')
    return app


def fixture(name, *, package=False, writable=False, extension='dmg'):
    folder = ROOT / ('source ' + name)
    folder.mkdir()
    app_fixture(folder, name)
    (folder / 'Applications').symlink_to(APPLICATIONS)
    if package:
        (folder / 'Additional Installer.pkg').mkdir()
    image = ROOT / ('unrelated filename ' + name + '.dmg')
    run('/usr/bin/hdiutil', 'create', '-srcfolder', folder, '-volname', 'Different Volume ' + name,
        '-format', 'UDRW' if writable else 'UDZO', '-o', image)
    if extension != 'dmg':
        image = image.rename(image.with_suffix('.' + extension))
    args = ['/usr/bin/hdiutil', 'attach', '-nobrowse', '-plist']
    if not writable:
        args.append('-readonly')
    args.append(str(image))
    attached = plistlib.loads(run(*args))
    mount = next(Path(e['mount-point']) for e in attached['system-entities'] if e.get('mount-point'))
    MOUNTS.append((image, mount))
    return image, mount, mount / (name + '.app'), APPLICATIONS / (name + '.app')


def check_stays(image, seconds=6):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        assert mounted(image), 'image ejected before a verified completed installation'
        time.sleep(.5)


def eject(image):
    mount = mounted(image)
    if mount:
        run('/usr/sbin/diskutil', 'eject', mount)


def passed(message):
    REPORT.append('PASS ' + message)
    print(REPORT[-1], flush=True)


try:
    AGENT = subprocess.Popen([str(PROJECT / 'build/dmg-auto-eject'), '--test-root', str(ROOT)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    wait_for(lambda: 'START' in log(), 'agent did not start')

    image, mount, source, target = fixture('Slow Copy')
    wait_for(lambda: 'WATCH Slow Copy.app' in log(), 'new mount not detected')
    check_stays(image)
    passed('opening a DMG without starting installation leaves it mounted')

    shutil.copytree(source, target, symlinks=True, ignore=shutil.ignore_patterns('payload'))
    payload = target / 'Contents/Resources/payload'
    original = (source / 'Contents/Resources/payload').read_bytes()
    with payload.open('wb') as handle:
        handle.write(original[:len(original) // 2])
        handle.flush()
        os.fsync(handle.fileno())
        check_stays(image)
    passed('a paused, incomplete slow copy is not ejected')

    payload.write_bytes(b'X' * len(original))
    shutil.copystat(source / 'Contents/Resources/payload', payload)
    check_stays(image)
    passed('same-size incorrect or preallocated data is not treated as complete')

    copy_finished = time.monotonic()
    shutil.copy2(source / 'Contents/Resources/payload', payload)
    wait_for(lambda: not mounted(image), 'completed installation was not ejected')
    eject_seconds = time.monotonic() - copy_finished
    assert eject_seconds < 8, f'ejection latency regressed: {eject_seconds:.1f}s'
    (PROJECT / 'build/speed-check.json').write_text(str(round(eject_seconds, 2)))
    assert image.exists() and payload.read_bytes() == original
    passed(f'complete byte-verified copy ejects in {eject_seconds:.1f}s; correct differently named volume, DMG and installed app preserved')

    # Same version already installed before the DMG mounts: opening it must be harmless.
    pre_source = ROOT / 'preexisting'
    pre_source.mkdir()
    pre_app = app_fixture(pre_source, 'Already Installed')
    shutil.copytree(pre_app, APPLICATIONS / pre_app.name, symlinks=True)
    image, mount, source, target = fixture('Already Installed')
    wait_for(lambda: 'WATCH Already Installed.app' in log(), 'same-version image not observed')
    check_stays(image)
    passed('preexisting same-version application does not cause immediate eject')
    target.rename(ROOT / 'previous bundle.app')
    shutil.copytree(source, target, symlinks=True)
    wait_for(lambda: not mounted(image), 'reinstalled bundle was not ejected')
    passed('a real same-version bundle replacement is detected')

    image, mount, source, target = fixture('Cancelled Copy')
    wait_for(lambda: 'WATCH Cancelled Copy.app' in log(), 'cancel test image not observed')
    shutil.copytree(source, target, symlinks=True, ignore=shutil.ignore_patterns('payload'))
    check_stays(image, 3)
    shutil.rmtree(target)
    check_stays(image)
    eject(image)
    passed('cancelled installation leaves the image mounted')

    image, mount, source, target = fixture('Busy Disk')
    wait_for(lambda: 'WATCH Busy Disk.app' in log(), 'busy test image not observed')
    holder = subprocess.Popen([sys.executable, '-c',
                               'import sys,time; f=open(sys.argv[1],"rb"); print("ready",flush=True); time.sleep(60)',
                               str(source / 'Contents/Resources/payload')], stdout=subprocess.PIPE)
    assert holder.stdout.readline().strip() == b'ready'
    try:
        shutil.copytree(source, target, symlinks=True)
        wait_for(lambda: 'BUSY/DEFER ' + str(mount) in log(), 'busy disk did not defer eject')
        assert mounted(image)
    finally:
        holder.terminate()
        holder.wait(timeout=5)
    wait_for(lambda: not mounted(image), 'released disk was not retried')
    passed('open files prevent normal eject; releasing them allows automatic retry')

    for name, options in [('Package Installer', {'package': True}),
                          ('Writable Data', {'writable': True}),
                          ('ISO Image', {'extension': 'iso'})]:
        image, mount, source, target = fixture(name, **options)
        shutil.copytree(source, target, symlinks=True)
        check_stays(image)
        assert 'WATCH ' + name + '.app' not in log()
        eject(image)
        passed(name + ' is excluded')
    print(f'ALL {len(REPORT)} INTEGRATION CHECKS PASSED', flush=True)
finally:
    if AGENT:
        AGENT.terminate()
        AGENT.wait(timeout=5)
    for image, mount in MOUNTS:
        if mounted(image):
            subprocess.run(['/usr/sbin/diskutil', 'eject', str(mount)], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    output = PROJECT / 'build/last-integration.log'
    output.write_text('\n'.join(REPORT) + '\n\n' + log())
    if any(mounted(image) for image, _ in MOUNTS):
        print('A busy test disk remains mounted; test files preserved at ' + str(ROOT), file=sys.stderr)
    else:
        shutil.rmtree(ROOT)
