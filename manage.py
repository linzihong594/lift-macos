#!/usr/bin/env python3
"""Build, install, pause or remove this user's DMG auto-eject agent."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import platform
import re
import time
import uuid

SOURCE = Path(__file__).resolve().parent
SUPPORT = Path.home() / 'Library/Application Support/DMG Auto Eject'
LABEL = 'local.suis.dmg-auto-eject'
PLIST = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
SERVICE = f'gui/{os.getuid()}/{LABEL}'
APP = Path('/Applications/轻退.app') if os.access('/Applications', os.W_OK) else Path.home() / 'Applications/轻退.app'


def launchctl(*args, check=True):
    return subprocess.run(['/bin/launchctl', *args], check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def build():
    folder = SOURCE / 'build'
    folder.mkdir(exist_ok=True)
    target = f'{platform.machine()}-apple-macos14.0'
    def swift(files, output):
        subprocess.run(['xcrun', 'swiftc', '-O', '-target', target,
                        *[str(SOURCE / f) for f in files], '-o', str(output)], check=True)
    swift(['Sources/GuardCore.swift', 'Sources/LiftState.swift', 'Sources/main.swift'], folder / 'LiftAgent')
    swift(['Sources/LiftState.swift', 'App/LiftApp.swift'], folder / 'Lift')
    swift(['App/DrawIcon.swift'], folder / 'draw-icon')
    subprocess.run([str(folder / 'draw-icon'), str(folder / 'LiftIcon.png')], check=True)
    app = folder / '轻退.app'
    if app.exists():
        shutil.rmtree(app)
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    resources = contents / 'Resources'
    resources.mkdir()
    helpers = contents / 'Library/LaunchServices'
    helpers.mkdir(parents=True)
    shutil.copy2(folder / 'Lift', contents / 'MacOS/Lift')
    shutil.copy2(folder / 'LiftAgent', helpers / 'LiftAgent')
    # The test driver continues to use this standalone copy.
    shutil.copy2(folder / 'LiftAgent', folder / 'dmg-auto-eject')
    iconset = folder / 'Lift.iconset'
    iconset.mkdir(exist_ok=True)
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            subprocess.run(['/usr/bin/sips', '-z', str(size * scale), str(size * scale),
                            str(folder / 'LiftIcon.png'), '--out', str(iconset / name)],
                           check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
    info = {
        'CFBundleName': '轻退', 'CFBundleDisplayName': '轻退', 'CFBundleExecutable': 'Lift',
        'CFBundleIdentifier': 'local.suis.lift', 'CFBundlePackageType': 'APPL',
        'CFBundleIconFile': 'AppIcon', 'CFBundleShortVersionString': '1.2.0', 'CFBundleVersion': '3',
        'CFBundleDevelopmentRegion': 'zh_CN', 'LSMinimumSystemVersion': '14.0',
        'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
        'NSHumanReadableCopyright': '轻退 · Lift — 本地自动弹出工具',
    }
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'local.suis.lift.agent', str(helpers / 'LiftAgent')], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return app


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['build', 'install', 'pause', 'resume', 'status', 'uninstall'])
    action = parser.parse_args().action
    if action == 'build':
        print(build())
    elif action == 'install':
        app = build()
        SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
        PLIST.parent.mkdir(parents=True, exist_ok=True)
        disabled = launchctl('print-disabled', f'gui/{os.getuid()}', check=False).stdout
        was_paused = bool(re.search(r'"' + re.escape(LABEL) + r'"\s*=>\s*true', disabled))
        backup = SOURCE / 'build' / ('upgrade-backup-' + time.strftime('%Y%m%d-%H%M%S'))
        backup.mkdir()
        if PLIST.exists():
            shutil.copy2(PLIST, backup / PLIST.name)
        legacy = SUPPORT / 'dmg-auto-eject'
        if legacy.exists():
            shutil.copy2(legacy, backup / 'dmg-auto-eject')
        launchctl('bootout', SERVICE, check=False)
        APP.parent.mkdir(parents=True, exist_ok=True)
        staging = APP.parent / ('.Lift-update-' + uuid.uuid4().hex + '.app')
        shutil.copytree(app, staging, symlinks=True)
        if APP.exists():
            shutil.move(str(APP), str(backup / APP.name))
        staging.replace(APP)
        installed = APP / 'Contents/Library/LaunchServices/LiftAgent'
        settings = {
            'Label': LABEL, 'ProgramArguments': [str(installed)],
            'RunAtLoad': True, 'KeepAlive': True, 'ProcessType': 'Background',
            'LimitLoadToSessionType': 'Aqua', 'ThrottleInterval': 10,
            'LowPriorityIO': True, 'Nice': 10, 'Umask': 0o077,
            'AssociatedBundleIdentifiers': ['local.suis.lift'],
            'StandardOutPath': str(SUPPORT / 'launchd.log'),
            'StandardErrorPath': str(SUPPORT / 'launchd.log'),
        }
        PLIST.write_bytes(plistlib.dumps(settings))
        PLIST.chmod(0o644)
        # Register the new bundle before launchd/BTM resolve its embedded helper.
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(APP)],
                       check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not was_paused:
            launchctl('enable', SERVICE)
            # Removal of the previous launchd job can complete asynchronously.
            for attempt in range(12):
                loaded = launchctl('bootstrap', f'gui/{os.getuid()}', str(PLIST), check=False)
                if loaded.returncode == 0:
                    break
                if attempt == 11:
                    raise RuntimeError(loaded.stdout.strip() or '启动轻退后台服务失败')
                time.sleep(0.25)
        legacy.unlink(missing_ok=True)
        print('已安装：' + str(APP) + ('（保持暂停）' if was_paused else '（后台已启动）'))
    elif action == 'pause':
        launchctl('disable', SERVICE)
        launchctl('bootout', SERVICE, check=False)
        print('已暂停，重启电脑后也保持暂停。')
    elif action == 'resume':
        launchctl('enable', SERVICE)
        if launchctl('print', SERVICE, check=False).returncode:
            launchctl('bootstrap', f'gui/{os.getuid()}', str(PLIST))
        print('已恢复。')
    elif action == 'status':
        result = launchctl('print', SERVICE, check=False)
        print(result.stdout if not result.returncode else '当前未运行。')
        log = SUPPORT / 'agent.log'
        if log.exists():
            print('\n最近记录：\n' + '\n'.join(log.read_text().splitlines()[-12:]))
    elif action == 'uninstall':
        launchctl('bootout', SERVICE, check=False)
        launchctl('enable', SERVICE, check=False)
        PLIST.unlink(missing_ok=True)
        if SUPPORT.exists():
            shutil.rmtree(SUPPORT)
        if APP.exists():
            shutil.rmtree(APP)
        print('已移除轻退和后台服务，保留项目源码与所有 DMG。')


if __name__ == '__main__':
    main()
