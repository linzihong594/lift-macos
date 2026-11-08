#!/usr/bin/env python3
"""Check bounded comparison memory; optionally compare an archived implementation."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', type=Path, help='Optional previous GuardCore.swift to compare')
args = parser.parse_args()
if args.baseline is not None and not args.baseline.is_file():
    parser.error('--baseline must point to an existing Swift source file')
(project / 'build').mkdir(exist_ok=True)
temporary = Path(tempfile.mkdtemp(prefix='Lift-memory-', dir='/private/tmp'))
try:
    source = temporary / 'source.app'
    (source / 'Contents/Resources').mkdir(parents=True)
    chunk = os.urandom(1024 * 1024)
    with (source / 'Contents/Resources/large').open('wb') as f:
        for _ in range(64):
            f.write(chunk)
    for n in range(2000):
        (source / 'Contents/Resources' / f'entry-{n}').write_bytes(chunk[:1024])
    destination = temporary / 'destination.app'
    shutil.copytree(source, destination)
    results = {}
    cases = [('before', args.baseline.resolve(), 'legacy')] if args.baseline else []
    cases.append(('after', project / 'Sources/GuardCore.swift', 'pooled'))
    for name, core, mode in cases:
        executable = project / 'build' / ('memory-' + name)
        subprocess.run(['xcrun', 'swiftc', '-O', str(core), str(project / 'Tests/MemoryBench.swift'), '-o', str(executable)], check=True)
        raw = subprocess.check_output([str(executable), str(source), str(destination), mode], timeout=60)
        results[name] = json.loads(raw)
        print(name, results[name], flush=True)
    assert results['after']['after'] < 32 * 1024 * 1024, 'idle memory regression'
    assert results['after']['peak'] < 64 * 1024 * 1024, 'peak memory regression'
    (project / 'build/performance.json').write_text(json.dumps(results, indent=2))
    print('PASS bounded comparison memory after three large-bundle verifications', flush=True)
finally:
    shutil.rmtree(temporary)
