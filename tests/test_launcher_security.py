import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ARCHIVE = Path(os.environ.get('KIRIFIX_TEST_RUNTIME_ARCHIVE', ROOT.parent / 'dist/kirifix-wwmi-034.zip'))


@unittest.skipUnless(os.name == 'nt', 'Windows launcher')
@unittest.skipUnless(RUNTIME_ARCHIVE.is_file(), 'Set KIRIFIX_TEST_RUNTIME_ARCHIVE to a release ZIP with portable Python')
class LauncherSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([sys.executable, str(ROOT / 'scripts/build.py')], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.cmd = self.folder / 'KiriFix-WWMI.cmd'
        self.cmd.write_bytes((ROOT / 'dist/KiriFix-WWMI.cmd').read_bytes())
        self.mods = self.folder / 'Mods'
        self.mods.mkdir()
        self.service = self.folder / 'KiriFix-WWMI'
        with ZipFile(RUNTIME_ARCHIVE) as archive:
            for member in archive.namelist():
                if member.startswith('KiriFix-WWMI/runtime/'):
                    archive.extract(member, self.folder)
        (self.service / 'kirifix.py').write_bytes((ROOT / 'dist/kirifix.py').read_bytes())
        (self.service / 'data').mkdir(parents=True)
        (self.service / 'data/moonholder.json').write_text(json.dumps({
            'characters': {'Test': {'main_hashes': [{'new': '11111111'}]}},
            'version': {'current_version': '3.7.1'}}))
        (self.mods / 'mod.ini').write_text('[TextureOverrideComponent0]\nhash = 11111111\n')

    def launch(self, prefix='', mods=None):
        env = os.environ.copy()
        env['TEST_HELPER'] = str(self.cmd)
        env['TEST_MODS'] = str(self.mods if mods is None else mods)
        return subprocess.run(['powershell.exe', '-NoProfile', '-Command',
                               prefix + '& $env:TEST_HELPER $env:TEST_MODS scan; exit $LASTEXITCODE'],
                              env=env, capture_output=True, text=True, encoding='utf-8', timeout=40)

    def support_text(self):
        self.assertFalse((self.service / 'KiriFix-support.txt').exists())
        report = (self.service / 'logs/KiriFix-support.txt').read_text(encoding='utf-8')
        self.assertNotIn(str(self.folder), report)
        for key in ('USERNAME', 'COMPUTERNAME'):
            if os.environ.get(key):
                self.assertNotIn(os.environ[key].casefold(), report.casefold())
        self.assertNotRegex(report, r'[A-Za-z]:[\\/]|\\\\')
        return report

    def test_support_report_omits_mod_names_and_replaces_previous_run(self):
        mod = self.mods / 'Private Name - \u041c\u043e\u0434'
        mod.mkdir()
        (self.mods / 'mod.ini').rename(mod / 'private-config.ini')
        logs = self.service / 'logs'
        logs.mkdir()
        (logs / 'KiriFix-support.txt').write_text('Stale private data')
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(r'For support, share KiriFix-WWMI\logs\KiriFix-support.txt.', result.stdout)
        report = self.support_text()
        for private in (mod.name, 'private-config.ini', 'Stale private data'):
            self.assertNotIn(private, report)
        self.assertIn('Scanned 1 INI', report)
        self.assertIn('Exit code: 0', report)

    def test_support_report_describes_missing_folder(self):
        result = self.launch(mods=self.folder / 'Private Missing Mods')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        report = self.support_text()
        self.assertNotIn('Private Missing Mods', report)
        self.assertIn('The selected Mods folder does not exist or is not a directory.', report)
        self.assertIn('Exit code: 2', report)

    def test_local_python_module_cannot_execute(self):
        marker = self.folder / 'imported.txt'
        (self.service / 'json.py').write_text(
            f"from pathlib import Path\nPath({str(marker)!r}).write_text('executed')\nraise SystemExit(0)\n")
        result = self.launch()
        self.assertFalse(marker.exists(), result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('READ ONLY', result.stdout)

    def test_cmd_launches_readable_python_source_without_powershell(self):
        contents = self.cmd.read_text().lower()
        for token in ('powershell', 'executionpolicy', 'scriptblock'):
            self.assertNotIn(token, contents)
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.service / '.runtime/kirifix.py').exists())

    def test_unicode_mod_paths_with_legacy_console_encoding(self):
        mod = self.mods / '\u5fc3-\u041c\u043e\u0434-\U0001f431'
        mod.mkdir()
        (self.mods / 'mod.ini').rename(mod / 'mod.ini')
        result = self.launch('[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(1252); ')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        logs = list((self.service / 'logs').glob('run-*.log'))
        self.assertEqual(len(logs), 1)
        self.assertIn(mod.name, logs[0].read_text(encoding='utf-8-sig'))
        self.assertIn('READ ONLY', result.stdout)

    def test_redirected_runtime_directory_is_rejected(self):
        outside = self.folder / 'outside'
        outside.mkdir()
        env = os.environ.copy()
        env['LINK_PATH'] = str(self.service / '.runtime')
        env['LINK_TARGET'] = str(outside)
        subprocess.run(['powershell.exe', '-NoProfile', '-Command',
                        'New-Item -ItemType Junction -Path $env:LINK_PATH -Target $env:LINK_TARGET | Out-Null'],
                       env=env, check=True, capture_output=True)
        result = self.launch()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_second_instance_is_rejected(self):
        prefix = r"$m=[Threading.Mutex]::new($false,'Local\KiriFix-WWMI'); $null=$m.WaitOne(0); "
        result = self.launch(prefix)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('already running', result.stdout)

    def test_default_scan_uses_script_folder_and_groups_service_files(self):
        result = subprocess.run(f'"{os.environ["COMSPEC"]}" /d /s /c ""{self.cmd}" "" scan"',
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        reports = list((self.service / 'reports').glob('*/report.json'))
        self.assertEqual(len(reports), 1)
        self.assertIn(f'Mods: {self.folder}', result.stdout)
        self.assertTrue(list((self.service / 'logs').glob('run-*.log')))
        self.assertEqual({p.name for p in self.folder.iterdir()},
                         {'KiriFix-WWMI.cmd', 'Mods', 'KiriFix-WWMI'})

    def test_bundled_and_extracted_cmd_share_service_folder(self):
        nested = self.service / self.cmd.name
        nested.write_bytes(self.cmd.read_bytes())
        env = os.environ.copy()
        env['TEST_HELPER'] = str(nested)
        result = subprocess.run(f'"{os.environ["COMSPEC"]}" /d /s /c ""{nested}" "" scan"',
                                env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'Mods: {self.folder}', result.stdout)
        self.assertFalse((self.service / 'KiriFix-WWMI').exists())
        self.assertTrue(list((self.service / 'reports').glob('*/report.json')))

    def test_wrong_location_warns_without_creating_reports(self):
        (self.mods / 'mod.ini').unlink()
        result = subprocess.run(f'"{os.environ["COMSPEC"]}" /d /s /c ""{self.cmd}" "" scan"',
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn('WARNING: WWMI mods were not detected', result.stdout)
        self.assertFalse((self.service / 'reports').exists())
        report = self.support_text()
        self.assertIn('No compatible WWMI mods were detected in the selected folder.', report)
        self.assertIn('Exit code: 3', report)
