import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Windows launcher')
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
        (self.folder / 'data').mkdir()
        (self.folder / 'data/moonholder.json').write_text(json.dumps({
            'characters': {'Test': {'main_hashes': [{'new': '11111111'}]}},
            'version': {'current_version': '3.7.1'}}))

    def launch(self, prefix=''):
        env = os.environ.copy()
        env['TEST_HELPER'] = str(self.cmd)
        env['TEST_MODS'] = str(self.mods)
        return subprocess.run(['powershell.exe', '-NoProfile', '-Command',
                               prefix + '& $env:TEST_HELPER $env:TEST_MODS scan; exit $LASTEXITCODE'],
                              env=env, capture_output=True, text=True, timeout=40)

    def test_local_python_module_cannot_execute(self):
        runtime = self.folder / '.runtime'
        runtime.mkdir()
        marker = self.folder / 'imported.txt'
        (runtime / 'json.py').write_text(
            f"from pathlib import Path\nPath({str(marker)!r}).write_text('executed')\nraise SystemExit(0)\n")
        result = self.launch()
        self.assertFalse(marker.exists(), result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('READ ONLY', result.stdout)

    def test_redirected_runtime_directory_is_rejected(self):
        outside = self.folder / 'outside'
        outside.mkdir()
        env = os.environ.copy()
        env['LINK_PATH'] = str(self.folder / '.runtime')
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
