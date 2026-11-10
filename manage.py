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
import hashlib
import tempfile

SOURCE = Path(__file__).resolve().parent
SUPPORT = Path.home() / 'Library/Application Support/DMG Auto Eject'
LABEL = 'local.suis.lift.background'
LEGACY_LABEL = 'local.suis.dmg-auto-eject'
PLIST = Path.home() / 'Library/LaunchAgents' / (LEGACY_LABEL + '.plist')
SERVICE = f'gui/{os.getuid()}/{LABEL}'
LEGACY_SERVICE = f'gui/{os.getuid()}/{LEGACY_LABEL}'
GUI_NAME = '轻退设置'
AGENT_NAME = '轻退'
APP = Path('/Applications/轻退.app') if os.access('/Applications', os.W_OK) else Path.home() / 'Applications/轻退.app'


def launchctl(*args, check=True):
    return subprocess.run(['/bin/launchctl', *args], check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def background(action):
    result = subprocess.run([str(APP / 'Contents/MacOS' / GUI_NAME), '--background', action],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or '未能更改轻退后台服务。')
    return result


def build(architecture=None, folder=None):
    folder = folder or SOURCE / 'build'
    folder.mkdir(parents=True, exist_ok=True)
    target = f'{architecture or platform.machine()}-apple-macos14.0'
    def swift(files, output, extra=()):
        subprocess.run(['xcrun', 'swiftc', '-O', '-target', target,
                        *[str(SOURCE / f) for f in files], *extra, '-o', str(output)], check=True)
    identity = folder / 'process-identity.o'
    subprocess.run(['xcrun', 'clang', '-Os', '-target', target, '-c',
                    str(SOURCE / 'Sources/ProcessIdentity.c'), '-o', str(identity)], check=True)
    swift(['Sources/GuardCore.swift', 'Sources/LiftState.swift', 'Sources/main.swift'], folder / AGENT_NAME,
          ['-import-objc-header', str(SOURCE / 'Sources/ProcessIdentity.h'), str(identity), '-framework', 'ApplicationServices'])
    swift(['Sources/LiftState.swift', 'App/ServiceControl.swift', 'App/LiftApp.swift'], folder / GUI_NAME)
    # The asset generator runs on the build host, including during cross builds.
    subprocess.run(['xcrun', 'swiftc', '-O', str(SOURCE / 'App/DrawIcon.swift'),
                    '-o', str(folder / 'draw-icon')], check=True)
    subprocess.run([str(folder / 'draw-icon'), str(folder / 'LiftIcon.png')], check=True)
    app = folder / '轻退.app'
    if app.exists():
        shutil.rmtree(app)
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    resources = contents / 'Resources'
    resources.mkdir()
    shutil.copy2(SOURCE / 'LICENSE', resources / 'LICENSE.txt')
    helper = contents / 'Library/LaunchServices/轻退.app'
    helpers = helper / 'Contents/MacOS'
    helpers.mkdir(parents=True)
    shutil.copy2(folder / GUI_NAME, contents / 'MacOS' / GUI_NAME)
    shutil.copy2(folder / AGENT_NAME, helpers / AGENT_NAME)
    # The test driver continues to use this standalone copy.
    shutil.copy2(folder / AGENT_NAME, folder / 'dmg-auto-eject')
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
        'CFBundleName': '轻退', 'CFBundleDisplayName': '轻退', 'CFBundleExecutable': GUI_NAME,
        'CFBundleIdentifier': 'local.suis.lift', 'CFBundlePackageType': 'APPL',
        'CFBundleIconFile': 'AppIcon', 'CFBundleShortVersionString': '1.4.0', 'CFBundleVersion': '5',
        'CFBundleDevelopmentRegion': 'zh_CN', 'LSMinimumSystemVersion': '14.0',
        'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
        'NSHumanReadableCopyright': '轻退 · Lift — 本地自动弹出工具',
    }
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    helper_info = {
        'CFBundleName': '轻退', 'CFBundleDisplayName': '轻退', 'CFBundleExecutable': AGENT_NAME,
        'CFBundleIdentifier': LABEL, 'CFBundlePackageType': 'APPL',
        'CFBundleIconFile': 'AppIcon', 'CFBundleShortVersionString': '1.4.0', 'CFBundleVersion': '5',
        'LSMinimumSystemVersion': '14.0', 'LSBackgroundOnly': True,
    }
    (helper / 'Contents/Info.plist').write_bytes(plistlib.dumps(helper_info))
    helper_resources = helper / 'Contents/Resources'
    helper_resources.mkdir()
    shutil.copy2(resources / 'AppIcon.icns', helper_resources / 'AppIcon.icns')
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(helper)], check=True)
    agents = contents / 'Library/LaunchAgents'
    agents.mkdir()
    settings = {
        'Label': LABEL, 'BundleProgram': 'Contents/Library/LaunchServices/轻退.app/Contents/MacOS/' + AGENT_NAME,
        'ProgramArguments': [AGENT_NAME],
        'RunAtLoad': True, 'KeepAlive': True, 'ProcessType': 'Background',
        'LimitLoadToSessionType': 'Aqua', 'ThrottleInterval': 10,
        'LowPriorityIO': True, 'Nice': 10, 'Umask': 0o077,
    }
    (agents / (LABEL + '.plist')).write_bytes(plistlib.dumps(settings))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return app


def package():
    folder = SOURCE / 'build'
    folder.mkdir(exist_ok=True)
    destination = folder / 'releases'
    destination.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='Lift-package-', dir=folder) as temporary:
        staging = Path(temporary)
        builds = {arch: build(arch, staging / arch) for arch in ['arm64', 'x86_64']}
        image = staging / 'image'
        image.mkdir()
        app = image / '轻退.app'
        shutil.copytree(builds['arm64'], app, symlinks=True)
        helper = Path('Contents/Library/LaunchServices/轻退.app')
        for relative in [Path('Contents/MacOS') / GUI_NAME, helper / 'Contents/MacOS' / AGENT_NAME]:
            subprocess.run(['xcrun', 'lipo', '-create',
                            *[str(builds[arch] / relative) for arch in builds],
                            '-output', str(app / relative)], check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app / helper)], check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        version = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
        name = 'Lift-' + version + '-universal'
        (image / 'Applications').symlink_to('/Applications')
        shutil.copy2(SOURCE / 'LICENSE', image / 'LICENSE.txt')
        (image / '安装说明.txt').write_text(
            '轻退 · Lift ' + version + '\n\n'
            '适用于 macOS 14+，包含 Apple Silicon 和 Intel 两种架构。\n'
            '1. 把“轻退.app”拖到“Applications（应用程序）”。\n'
            '2. 从“应用程序”打开轻退，开启“自动弹出”。\n'
            '3. 关闭管理窗口后后台继续运行；关闭主开关可持续停用。\n\n'
            '此版本使用 ad-hoc 签名，尚未经过 Apple 公证。\n'
            '若系统阻止打开，请核实下载来自本项目，再参考 Apple 官方说明：\n'
            'https://support.apple.com/102445\n\n'
            'Install: drag 轻退.app into Applications, open it, and enable Auto Eject.\n'
            'Requires macOS 14+. Universal arm64 + x86_64; Intel hardware has not been tested.\n'
            'Locally ad-hoc signed; not Apple-notarized. No Python or compiler is needed.\n\n'
            'Project: https://github.com/linzihong594/lift-macos\n')
        zip_file = staging / (name + '.zip')
        dmg_file = staging / (name + '.dmg')
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                        str(app), str(zip_file)], check=True)
        subprocess.run(['/usr/bin/hdiutil', 'create', '-srcfolder', str(image),
                        '-volname', '轻退 ' + version, '-format', 'UDZO', str(dmg_file)], check=True)
        sums = []
        for artifact in [dmg_file, zip_file]:
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            output = destination / artifact.name
            artifact.replace(output)
            sums.append(digest + '  ' + output.name)
        (destination / 'SHA256SUMS.txt').write_text('\n'.join(sums) + '\n')
    print('已生成下载文件：' + str(destination))
    return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['build', 'package', 'install', 'pause', 'resume', 'status', 'uninstall'])
    action = parser.parse_args().action
    if action == 'build':
        print(build())
    elif action == 'package':
        package()
    elif action == 'install':
        app = build()
        SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
        disabled = launchctl('print-disabled', f'gui/{os.getuid()}', check=False).stdout
        was_paused = bool(re.search(r'"' + re.escape(LEGACY_LABEL) + r'"\s*=>\s*true', disabled))
        if (APP / 'Contents/MacOS' / GUI_NAME).exists():
            previous = background('status')
            was_paused = previous.stdout.strip() in ('notRegistered', 'requiresApproval')
            background('disable')
        backup = SOURCE / 'build' / ('upgrade-backup-' + time.strftime('%Y%m%d-%H%M%S'))
        backup.mkdir()
        if PLIST.exists():
            shutil.copy2(PLIST, backup / PLIST.name)
        legacy = SUPPORT / 'dmg-auto-eject'
        if legacy.exists():
            shutil.copy2(legacy, backup / 'dmg-auto-eject')
        launchctl('bootout', LEGACY_SERVICE, check=False)
        if PLIST.exists():
            PLIST.unlink()
            launchctl('enable', LEGACY_SERVICE, check=False)
        APP.parent.mkdir(parents=True, exist_ok=True)
        staging = APP.parent / ('.Lift-update-' + uuid.uuid4().hex + '.app')
        shutil.copytree(app, staging, symlinks=True)
        if APP.exists():
            shutil.move(str(APP), str(backup / APP.name))
        staging.replace(APP)
        # Register the installed bundle before SMAppService associates its agent.
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(APP)],
                       check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not was_paused:
            background('enable')
        legacy.unlink(missing_ok=True)
        # Keep rollback data without leaving another launchable/indexable app.
        archive = backup.with_suffix('.zip')
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                        str(backup), str(archive)], check=True)
        shutil.rmtree(backup)
        shutil.rmtree(app)
        print('已安装：' + str(APP) + ('（保持暂停）' if was_paused else '（后台已启动）'))
    elif action == 'pause':
        if (APP / 'Contents/MacOS' / GUI_NAME).exists():
            background('disable')
        else:
            launchctl('disable', LEGACY_SERVICE)
            launchctl('bootout', LEGACY_SERVICE, check=False)
        print('已暂停，重启电脑后也保持暂停。')
    elif action == 'resume':
        if (APP / 'Contents/MacOS' / GUI_NAME).exists():
            background('enable')
        else:
            launchctl('enable', LEGACY_SERVICE)
            if launchctl('print', LEGACY_SERVICE, check=False).returncode:
                launchctl('bootstrap', f'gui/{os.getuid()}', str(PLIST))
        print('已恢复。')
    elif action == 'status':
        result = launchctl('print', SERVICE if (APP / 'Contents/MacOS' / GUI_NAME).exists() else LEGACY_SERVICE, check=False)
        print(result.stdout if not result.returncode else '当前未运行。')
        log = SUPPORT / 'agent.log'
        if log.exists():
            print('\n最近记录：\n' + '\n'.join(log.read_text().splitlines()[-12:]))
    elif action == 'uninstall':
        if (APP / 'Contents/MacOS' / GUI_NAME).exists():
            background('disable')
        launchctl('bootout', LEGACY_SERVICE, check=False)
        launchctl('enable', LEGACY_SERVICE, check=False)
        PLIST.unlink(missing_ok=True)
        if SUPPORT.exists():
            shutil.rmtree(SUPPORT)
        if APP.exists():
            shutil.rmtree(APP)
        print('已移除轻退和后台服务，保留项目源码与所有 DMG。')


if __name__ == '__main__':
    main()
