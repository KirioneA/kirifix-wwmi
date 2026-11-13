import json
import contextlib
import io
import threading
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import kirifix as h


class FullRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'Mods'
        self.stage = self.base / 'stage'
        self.root.mkdir()
        self.stage.mkdir()
        (self.root / 'mod.ini').write_bytes(b'[TextureOverrideComponent0]\nhash = 11111111\n[ResourceBlend]\nfilename = Blend.buf\n')
        (self.root / 'Blend.buf').write_bytes(b'old blend')

    def test_binary_and_ini_and_new_file_rollback_exact(self):
        originals = h.prepare_stage(self.root, self.stage)
        (self.stage / 'Blend.buf').write_bytes(b'new blend')
        (self.stage / 'mod.ini').write_bytes(b'new ini')
        (self.stage / 'mask.png').write_bytes(b'mask')
        (self.stage / 'junk.BAK').write_bytes(b'ignored')
        journal = h.commit_full(self.root, self.stage, originals, self.base / 'backups')
        self.assertEqual((self.root / 'Blend.buf').read_bytes(), b'new blend')
        self.assertFalse((self.root / 'junk.BAK').exists())
        h.rollback_full(self.root, journal)
        self.assertFalse((self.root / 'mask.png').exists())
        for name, checksum in originals.items():
            self.assertEqual(h.file_digest(self.root / name), checksum)
        h.rollback_full(self.root, journal)

    def test_concurrent_edit_prevents_entire_batch(self):
        originals = h.prepare_stage(self.root, self.stage)
        (self.stage / 'Blend.buf').write_bytes(b'new blend')
        (self.root / 'mod.ini').write_bytes(b'edited')
        with self.assertRaisesRegex(ValueError, 'Concurrent edit'):
            h.commit_full(self.root, self.stage, originals, self.base / 'backups')
        self.assertEqual((self.root / 'Blend.buf').read_bytes(), b'old blend')

    def test_later_new_file_edit_blocks_whole_rollback(self):
        originals = h.prepare_stage(self.root, self.stage)
        (self.stage / 'Blend.buf').write_bytes(b'new blend')
        (self.stage / 'mask.png').write_bytes(b'mask')
        journal = h.commit_full(self.root, self.stage, originals, self.base / 'backups')
        (self.root / 'mask.png').write_bytes(b'user edit')
        with self.assertRaisesRegex(ValueError, 'Later edits'):
            h.rollback_full(self.root, journal)
        self.assertEqual((self.root / 'Blend.buf').read_bytes(), b'new blend')

    def test_missing_asset_stops_before_writes(self):
        (self.root / 'Blend.buf').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing resource'):
            h.prepare_stage(self.root, self.stage)

    def test_external_asset_refused(self):
        (self.root / 'mod.ini').write_text('[Resource]\nfilename = ../outside.buf\n')
        with self.assertRaises(ValueError):
            h.prepare_stage(self.root, self.stage)

    def test_incomplete_mod_skipped_without_blocking_complete_mod(self):
        (self.root / 'mod.ini').unlink()
        broken = self.root / 'Broken'
        good = self.root / 'Good'
        for folder in [broken / 'Body', broken / 'Hair', good]:
            folder.mkdir(parents=True)
        (broken / 'Body/mod.ini').write_text('[Resource]\nfilename = missing.dds\n')
        (broken / 'Hair/mod.ini').write_text('[TextureOverrideComponent0]\nhash = 11111111\n')
        (good / 'mod.ini').write_text('[TextureOverrideComponent0]\nhash = 22222222\n')
        skipped = []
        originals = h.prepare_stage(self.root, self.stage, skipped)
        self.assertEqual(set(originals), {'Good/mod.ini'})
        self.assertFalse((self.stage / 'Broken').exists())
        self.assertEqual(skipped[0]['mod'], 'Broken')
        self.assertIn('missing.dds', skipped[0]['reason'])

    def test_no_partial_copy_of_incomplete_single_mod(self):
        (self.root / 'mod.ini').write_text('[Resource]\nfilename = missing.dds\n')
        skipped = []
        with self.assertRaisesRegex(ValueError, 'Missing resource'):
            h.prepare_stage(self.root, self.stage, skipped)
        self.assertEqual(list(self.stage.iterdir()), [])

    def test_corrupt_cli_refused_before_execution(self):
        runtime = self.base / '.runtime'
        runtime.mkdir()
        (runtime / 'wuwa-mod-cli-3.7.0.exe').write_bytes(b'bad executable')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            h.moonholder_cli(runtime)

    def test_cli_failure_keeps_originals(self):
        db = self.base / 'data/moonholder.json'
        db.parent.mkdir()
        db.write_text(json.dumps({'characters': {}}))
        runtime = self.base / '.runtime'
        runtime.mkdir()
        result = type('Result', (), {'returncode': 1, 'stdout': b'', 'stderr': b'failed'})()
        with patch.object(h, 'moonholder_cli', return_value=runtime / 'cli.exe'), patch.object(h, 'run_moonholder', return_value=(1, [])):
            with self.assertRaisesRegex(ValueError, 'originals unchanged'):
                h.full_run(self.root, db, self.base / 'backups', self.base / 'reports')
        self.assertEqual((self.root / 'Blend.buf').read_bytes(), b'old blend')
        self.assertFalse((self.base / 'backups').exists())

    def test_activity_emits_heartbeat_and_stops_thread(self):
        signal = threading.Event()
        messages = []
        def capture(*args, **kwargs):
            messages.append(str(args[0]))
            if messages[-1].startswith('WORKING:'):
                signal.set()
        with patch('builtins.print', side_effect=capture):
            with h.activity('Copying', interval=0.01):
                self.assertTrue(signal.wait(1))
            count = len(messages)
            self.assertTrue(messages[0].startswith('STAGE:'))
            self.assertEqual(len(messages), count)

    def test_moonholder_progress_stream_and_raw_logs(self):
        destination = self.base / 'reports'
        destination.mkdir()
        code = ('import json,time,sys; '
                'print(json.dumps({"event":"progress","current":1,"total":2,"percent":50}),flush=True); '
                'time.sleep(0.3); '
                'print(json.dumps({"event":"finish","success":True}),flush=True); '
                'print("diagnostic",file=sys.stderr,flush=True)')
        console = io.StringIO()
        with contextlib.redirect_stdout(console):
            status, events = h.run_moonholder([sys.executable, '-I', '-u', '-c', code], str(self.base), destination)
        self.assertEqual(status, 0)
        self.assertIn('MOONHOLDER: 1/2 INI; 50%', console.getvalue())
        self.assertEqual(events[-1]['event'], 'finish')
        self.assertIn(b'"event": "progress"', (destination / 'moonholder.stdout.log').read_bytes())
        self.assertIn(b'diagnostic', (destination / 'moonholder.stderr.log').read_bytes())

    def test_moonholder_timeout_stops_child(self):
        destination = self.base / 'reports'
        destination.mkdir()
        with self.assertRaises(h.subprocess.TimeoutExpired):
            h.run_moonholder([sys.executable, '-I', '-c', 'import time; time.sleep(30)'],
                            str(self.base), destination, timeout=0.01)

    def cached_run(self, force=False):
        db = self.base / 'data/moonholder.json'
        if not db.exists():
            db.parent.mkdir()
            db.write_text(json.dumps({'characters': {'Test': {'main_hashes': [{'new': '11111111'}]}}}))
        (self.base / '.runtime').mkdir(exist_ok=True)
        h.full_run(self.root, db, self.base / 'backups', self.base / 'reports', force=force)

    def test_unchanged_cache_skips_cli_and_copy(self):
        finish = (0, [{'event': 'finish', 'success': True}])
        with patch.object(h, 'moonholder_cli', return_value=self.base / 'cli.exe'), patch.object(h, 'run_moonholder', return_value=finish) as run:
            self.cached_run()
            with patch.object(h, 'prepare_stage', side_effect=AssertionError('Must not copy unchanged mods')):
                self.cached_run()
            self.assertEqual(run.call_count, 1)

    def test_resource_changes_added_files_and_force_invalidate_cache(self):
        finish = (0, [{'event': 'finish', 'success': True}])
        with patch.object(h, 'moonholder_cli', return_value=self.base / 'cli.exe'), patch.object(h, 'run_moonholder', return_value=finish) as run:
            self.cached_run()
            (self.root / 'Blend.buf').write_bytes(b'changed blend')
            self.cached_run()
            (self.root / 'new.dds').write_bytes(b'new resource')
            self.cached_run()
            self.cached_run(force=True)
            self.assertEqual(run.call_count, 4)

    def test_database_change_invalidates_cache(self):
        finish = (0, [{'event': 'finish', 'success': True}])
        with patch.object(h, 'moonholder_cli', return_value=self.base / 'cli.exe'), patch.object(h, 'run_moonholder', return_value=finish) as run:
            self.cached_run()
            db = self.base / 'data/moonholder.json'
            value = json.loads(db.read_text())
            value['revision'] = 'changed'
            db.write_text(json.dumps(value))
            self.cached_run()
            self.assertEqual(run.call_count, 2)

    def test_only_changed_mod_is_staged(self):
        (self.root / 'mod.ini').unlink()
        for name in ['A', 'B']:
            folder = self.root / name
            folder.mkdir()
            (folder / 'mod.ini').write_text('[TextureOverrideComponent0]\nhash = 11111111\n')
        staged = []
        def upstream(command, cwd, destination):
            stage = Path(command[command.index('--path') + 1])
            staged.append({p.parent.name for p in stage.rglob('mod.ini')})
            return 0, [{'event': 'finish', 'success': True}]
        with patch.object(h, 'moonholder_cli', return_value=self.base / 'cli.exe'), patch.object(h, 'run_moonholder', side_effect=upstream):
            self.cached_run()
            (self.root / 'A/mod.ini').write_text('[TextureOverrideComponent0]\nhash = 11111111\n;changed\n')
            self.cached_run()
        self.assertEqual(staged, [{'A', 'B'}, {'A'}])

    def test_rabbitfx_change_reprocesses_dependent_mods(self):
        (self.root / 'mod.ini').unlink()
        for name in ['A', 'RabbitFX']:
            folder = self.root / name
            folder.mkdir()
            (folder / 'mod.ini').write_text('[TextureOverrideComponent0]\nhash = 11111111\n')
        rabbit = self.root / 'RabbitFX/mod.ini'
        rabbit.write_text('namespace = RabbitFX\n[CommandListSetTextures]\n')
        finish = (0, [{'event': 'finish', 'success': True}])
        with patch.object(h, 'moonholder_cli', return_value=self.base / 'cli.exe'), patch.object(h, 'run_moonholder', return_value=finish) as run:
            self.cached_run()
            self.cached_run()
            self.assertEqual(run.call_count, 1)
            rabbit.write_text(rabbit.read_text() + '; new dependency\n')
            self.cached_run()
            self.assertEqual(run.call_count, 2)

    def test_repaired_missing_resource_invalidates_cached_skip(self):
        (self.root / 'mod.ini').unlink()
        for name in ['Good', 'Broken']:
            (self.root / name).mkdir()
        (self.root / 'Good/mod.ini').write_text('[TextureOverrideComponent0]\nhash = 11111111\n')
        (self.root / 'Broken/mod.ini').write_text('[TextureOverrideComponent0]\nhash = 11111111\n[Resource]\nfilename = missing.dds\n')
        finish = (0, [{'event': 'finish', 'success': True}])
        with patch.object(h, 'moonholder_cli', return_value=self.base / 'cli.exe'), patch.object(h, 'run_moonholder', return_value=finish) as run:
            self.cached_run()
            self.cached_run()
            self.assertEqual(run.call_count, 1)
            (self.root / 'Broken/missing.dds').write_bytes(b'restored')
            self.cached_run()
            cache = json.loads((self.base / 'data/processed-mods.json').read_bytes())
            self.assertIsNone(cache['mods']['Broken']['skipped'])
            self.assertEqual(run.call_count, 2)

    def test_cached_database_does_not_make_network_request(self):
        database = self.base / 'database.json'
        database.write_text(json.dumps({'characters': {'Test': {'main_hashes': [{'new': '11111111'}]}}}))
        with patch.object(h, 'check_database'), patch.object(h, 'update_database', side_effect=AssertionError('No second download expected')), patch.object(h, 'full_run') as run:
            result = h.main(['full-run', str(self.root), '--database', str(database)])
        self.assertEqual(result, 0)
        run.assert_called_once()

    def test_changed_character_rules_only_stage_affected_character(self):
        (self.root / 'mod.ini').unlink()
        for name, value in [('A', '11111111'), ('B', '22222222')]:
            (self.root / name).mkdir()
            (self.root / name / 'mod.ini').write_text(f'[TextureOverrideComponent0]\nhash = {value}\n')
        db = self.base / 'data/moonholder.json'
        db.parent.mkdir()
        content = {'characters': {'HeroA': {'main_hashes': [{'new': '11111111'}]},
                                  'HeroB': {'main_hashes': [{'new': '22222222'}]}}}
        db.write_text(json.dumps(content))
        staged = []
        def upstream(command, cwd, destination):
            stage = Path(command[command.index('--path') + 1])
            staged.append({p.parent.name for p in stage.rglob('mod.ini')})
            return 0, [{'event': 'finish', 'success': True}]
        with patch.object(h, 'moonholder_cli', return_value=self.base / 'cli.exe'), patch.object(h, 'run_moonholder', side_effect=upstream):
            self.cached_run()
            content['characters']['HeroA']['skip_components'] = [7]
            db.write_text(json.dumps(content))
            self.cached_run()
            content['version'] = {'current_version': '3.8.0'}
            db.write_text(json.dumps(content))
            self.cached_run()
        self.assertEqual(staged, [{'A', 'B'}, {'A'}])

    def test_unknown_mod_invalidated_by_new_character_rule(self):
        db = {'characters': {'Hero': {'main_hashes': [{'new': '22222222'}]}}}
        old = h.mod_rule_signatures(self.root, db, {'.': {}})
        db['characters']['NewHero'] = {'main_hashes': [{'new': '11111111'}]}
        self.assertNotEqual(old, h.mod_rule_signatures(self.root, db, {'.': {}}))

    def test_database_check_304_and_daily_interval(self):
        database = self.base / 'database.json'
        raw = json.dumps({'characters': {'Hero': {'main_hashes': [{'new': '11111111'}]}}}).encode()
        database.write_bytes(raw)
        h.save_json(database.with_suffix('.source.json'), {'sha256': h.digest(raw), 'etag': 'test-etag'})
        error = h.urllib.error.HTTPError(h.DATABASE_URL, 304, 'Not Modified', {}, None)
        with patch.object(h.urllib.request, 'urlopen', side_effect=error) as request:
            h.check_database(database, now=100000)
            self.assertEqual(request.call_args[0][0].get_header('If-none-match'), 'test-etag')
            h.check_database(database, now=100001)
            self.assertEqual(request.call_count, 1)
        self.assertEqual(database.read_bytes(), raw)

    def test_database_offline_fallback_and_retry_delay(self):
        database = self.base / 'database.json'
        raw = json.dumps({'characters': {'Hero': {'main_hashes': [{'new': '11111111'}]}}}).encode()
        database.write_bytes(raw)
        with patch.object(h.urllib.request, 'urlopen', side_effect=OSError('offline')) as request:
            h.check_database(database, now=100000)
            h.check_database(database, now=100001)
            self.assertEqual(request.call_count, 1)
        self.assertEqual(database.read_bytes(), raw)
        with patch.object(h.urllib.request, 'urlopen', side_effect=OSError('offline')):
            with self.assertRaisesRegex(ValueError, 'no valid cache'):
                h.check_database(self.base / 'missing.json', now=100000)

    def test_download_validation_and_conditional_refresh(self):
        database = self.base / 'database.json'
        raw = json.dumps({'characters': {'Hero': {'main_hashes': [{'new': '11111111'}]}}}).encode()
        class Response:
            url = h.DATABASE_URL
            headers = {'ETag': 'new-etag'}
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, size):
                return raw
        with patch.object(h.urllib.request, 'urlopen', return_value=Response()) as request:
            h.check_database(database, now=100000)
            self.assertEqual(database.read_bytes(), raw)
            h.check_database(database, now=100001, force=True)
            self.assertEqual(request.call_count, 2)
            self.assertEqual(request.call_args[1]['timeout'], 3)

    def test_preview4_cache_reprocesses_once_with_current_repair_rules(self):
        finish = (0, [{'event': 'finish', 'success': True}])
        with patch.object(h, 'moonholder_cli', return_value=self.base / 'cli.exe'), patch.object(h, 'run_moonholder', return_value=finish) as upstream:
            self.cached_run()
            path = self.base / 'data/processed-mods.json'
            saved = json.loads(path.read_bytes())
            saved['context'].pop('global_rules')
            saved['context']['logic'] = '0.3.0-preview.4'
            saved['context']['database'] = h.digest((self.base / 'data/moonholder.json').read_bytes())
            for record in saved['mods'].values():
                record.pop('rules')
            h.save_json(path, saved)
            self.cached_run()
            self.assertEqual(upstream.call_count, 2)
            self.assertIn('rules', json.loads(path.read_bytes())['mods']['.'])
            self.cached_run()
            self.assertEqual(upstream.call_count, 2)

    def test_invalid_database_response_keeps_valid_cache(self):
        database = self.base / 'database.json'
        raw = json.dumps({'characters': {'Hero': {'main_hashes': [{'new': '11111111'}]}}}).encode()
        database.write_bytes(raw)
        class Response:
            url = h.DATABASE_URL
            headers = {}
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, size):
                return b'<html>server error</html>'
        with patch.object(h.urllib.request, 'urlopen', return_value=Response()):
            h.check_database(database, now=100000)
        self.assertEqual(database.read_bytes(), raw)
