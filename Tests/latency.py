#!/usr/bin/env python3
"""Measure copy-to-eject time on private DMGs with an optional agent baseline."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid

PROJECT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', type=Path, help='Optional previous standalone agent executable')
parser.add_argument('--samples', type=int, default=3)
args = parser.parse_args()
if not 1 <= args.samples <= 10:
    parser.error('--samples must be between 1 and 10')
executables = [('baseline', args.baseline.resolve())] if args.baseline else []
executables.append(('current', PROJECT / 'build/dmg-auto-eject'))
for name, executable in executables:
    if not executable.is_file():
        parser.error(f'{name} executable not found: {executable}')


def run(*command):
    return subprocess.check_output(list(map(str, command)), stderr=subprocess.PIPE, timeout=45)


root = Path(tempfile.mkdtemp(prefix='Lift-latency-', dir='/private/tmp')).resolve()
mounts = []
results = {}
try:
    executables = [(name, Path(shutil.copy2(executable, root / (name + '-agent')))) for name, executable in executables]
    source = root / 'source/Lift Latency.app'
    (source / 'Contents/MacOS').mkdir(parents=True)
    resources = source / 'Contents/Resources'
    resources.mkdir()
    (source / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.test.lift.latency', 'CFBundleExecutable': 'Example', 'CFBundleVersion': '1',
    }))
    executable = source / 'Contents/MacOS/Example'
    executable.write_text('#!/bin/sh\nexit 0\n')
    executable.chmod(0o755)
    block = os.urandom(1024 * 1024)
    with (resources / 'payload').open('wb') as f:
        for _ in range(32):
            f.write(block)
    for n in range(250):
        (resources / f'file-{n}').write_bytes(block[:1024])
    image = root / 'fixture.dmg'
    run('/usr/bin/hdiutil', 'create', '-srcfolder', source.parent, '-volname', 'Lift Latency ' + uuid.uuid4().hex[:8],
        '-format', 'UDZO', '-o', image)
    for name, agent in executables:
        case = root / name
        applications = case / 'Applications'
        applications.mkdir(parents=True)
        process = subprocess.Popen([str(agent), '--test-root', str(case)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        timings = []
        try:
            for sample in range(args.samples):
                target = applications / source.name
                if target.exists():
                    shutil.rmtree(target)
                current_image = case / f'installer-{sample}.dmg'
                shutil.copy2(image, current_image)
                attached = plistlib.loads(run('/usr/bin/hdiutil', 'attach', '-nobrowse', '-readonly', '-plist', current_image))
                mount = next(Path(e['mount-point']) for e in attached['system-entities'] if e.get('mount-point'))
                mounts.append(mount)
                deadline = time.monotonic() + 10
                log = case / 'agent.log'
                while time.monotonic() < deadline:
                    if log.exists() and log.read_text().count('WATCH Lift Latency.app') > sample:
                        break
                    time.sleep(.025)
                else:
                    raise AssertionError('agent did not observe the test image')
                shutil.copytree(mount / source.name, target, symlinks=True)
                finished = time.monotonic()
                while mount.exists() and time.monotonic() - finished < 15:
                    if process.poll() is not None:
                        raise AssertionError('agent exited: ' + process.stderr.read().decode())
                    time.sleep(.025)
                assert not mount.exists(), 'completed test copy did not eject'
                seconds = round(time.monotonic() - finished, 3)
                timings.append(seconds)
                print(f'{name} sample {sample + 1}: {seconds:.3f}s', flush=True)
            results[name] = {'seconds': timings, 'median_seconds': round(statistics.median(timings), 3)}
        finally:
            process.terminate()
            process.wait(timeout=5)
    results['fixture'] = {'large_file_mib': 32, 'small_files': 250}
    (PROJECT / 'build/latency.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results), flush=True)
finally:
    for mount in mounts:
        if mount.exists():
            subprocess.run(['/usr/sbin/diskutil', 'eject', str(mount)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    if any(mount.exists() for mount in mounts):
        print('Busy test volume: preserved files at ' + str(root), flush=True)
    else:
        shutil.rmtree(root)
