#!/usr/bin/env python3
"""Exercise install cleanup in temporary folders without touching login services."""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('lift_manager', Path(__file__).resolve().parents[1] / 'manage.py')
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)
real_run = subprocess.run


class InstallCleanupTests(unittest.TestCase):
    def exercise(self, *, paused=False, registration_fails=False, archive_fails=False, modern=False):
        with tempfile.TemporaryDirectory(prefix='Lift-install-test-') as temporary:
            root = Path(temporary)
            source = root / 'source'
            built = source / 'build/轻退.app'
            installed = root / 'Applications/轻退.app'
            for app, content in [(built, b'new'), (installed, b'old')]:
                (app / 'Contents/MacOS').mkdir(parents=True)
                name = manager.GUI_NAME if app == built or modern else 'Lift'
                executable = app / 'Contents/MacOS' / name
                executable.write_bytes(content)
                executable.chmod(0o755)
                (app / 'Contents/current').symlink_to('MacOS/' + name)
            plist = root / 'LaunchAgents/agent.plist'
            plist.parent.mkdir()
            old_config = plistlib.dumps({'previous': True})
            plist.write_bytes(old_config)

            def launchctl(*args, **kwargs):
                output = f'"{manager.LEGACY_LABEL}" => true' if paused and args[0] == 'print-disabled' else ''
                return subprocess.CompletedProcess(args, 0, output)

            actions = []
            def background(action):
                actions.append(action)
                if registration_fails and action == 'enable':
                    raise subprocess.CalledProcessError(1, ['--background', action])
                return subprocess.CompletedProcess([], 0, 'notRegistered' if paused else 'enabled')

            def run(args, **kwargs):
                if args[0] == '/usr/bin/ditto':
                    if archive_fails:
                        raise subprocess.CalledProcessError(1, args)
                    return real_run(args, **kwargs)
                self.assertTrue(args[0].endswith('/lsregister'))
                return subprocess.CompletedProcess(args, 0)

            with contextlib.ExitStack() as stack:
                for key, value in {'SOURCE': source, 'APP': installed, 'SUPPORT': root / 'support', 'PLIST': plist}.items():
                    stack.enter_context(patch.object(manager, key, value))
                stack.enter_context(patch.object(manager, 'build', return_value=built))
                stack.enter_context(patch.object(manager, 'launchctl', side_effect=launchctl))
                stack.enter_context(patch.object(manager, 'background', side_effect=background))
                stack.enter_context(patch.object(manager.subprocess, 'run', side_effect=run))
                stack.enter_context(patch.object(manager.time, 'sleep'))
                stack.enter_context(patch('sys.argv', ['manage.py', 'install']))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                if registration_fails or archive_fails:
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        manager.main()
                else:
                    manager.main()

            self.assertEqual((installed / 'Contents/MacOS' / manager.GUI_NAME).read_bytes(), b'new')
            if registration_fails or archive_fails:
                self.assertTrue(built.is_dir())
                backup = next((source / 'build').glob('upgrade-backup-*'))
                self.assertEqual((backup / '轻退.app/Contents/MacOS' / (manager.GUI_NAME if modern else 'Lift')).read_bytes(), b'old')
                return
            self.assertFalse(plist.exists())
            self.assertEqual('enable' in actions, not paused)
            if modern:
                self.assertIn('disable', actions)
            self.assertFalse(built.exists())
            self.assertEqual(list((source / 'build').rglob('*.app')), [])
            archive = next((source / 'build').glob('upgrade-backup-*.zip'))
            restored = root / 'restored'
            real_run(['/usr/bin/ditto', '-x', '-k', str(archive), str(restored)], check=True)
            backup = next(restored.iterdir())
            old_app = backup / '轻退.app'
            self.assertEqual((old_app / 'Contents/MacOS' / (manager.GUI_NAME if modern else 'Lift')).read_bytes(), b'old')
            self.assertTrue((old_app / 'Contents/MacOS' / (manager.GUI_NAME if modern else 'Lift')).stat().st_mode & 0o111)
            self.assertTrue((old_app / 'Contents/current').is_symlink())
            self.assertEqual((backup / plist.name).read_bytes(), old_config)

    def test_success_retains_recoverable_archive_without_duplicate_apps(self):
        self.exercise()

    def test_paused_upgrade_also_cleans_up(self):
        self.exercise(paused=True)

    def test_registration_failure_preserves_build_and_backup(self):
        self.exercise(registration_fails=True)

    def test_modern_upgrade_retains_paused_state(self):
        self.exercise(paused=True, modern=True)

    def test_modern_upgrade_reregisters_one_service(self):
        self.exercise(modern=True)

    def test_archive_failure_preserves_build_and_backup(self):
        self.exercise(archive_fails=True)


if __name__ == '__main__':
    unittest.main()
