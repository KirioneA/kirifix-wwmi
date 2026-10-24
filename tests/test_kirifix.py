import copy
import json
from pathlib import Path
import tempfile
import unittest
import contextlib
import io
from unittest.mock import patch

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import kirifix as h


DB = {
    'version': {'current_version': '3.7.1'},
    'characters': {'Hero': {
        'main_hashes': [{'old': ['11111111'], 'new': '22222222'}],
        'skip_components': [7],
        'textures': {
            'bbbbbbbb': {'replace': ['aaaaaaaa'], 'meta': {'id': [3, 4], 'type': 'D'}},
            'dddddddd': {'replace': ['cccccccc'], 'meta': {'id': 3, 'type': 'N'}},
        },
    }},
}
INI = ('[TextureOverrideComponent3]\r\nhash = 11111111\r\n'
       'if $mod_enabled\r\n    run = CommandListTriggerResourceOverrides\r\n'
       '    run = CommandListOverrideSharedResources\r\n'
       '    drawindexed = 12, 0, 0\r\nendif\r\n'
       '[ResourceBody]\r\nfilename = Textures/Body.dds\r\n'
       '[TextureOverrideBody]\r\nhash = aaaaaaaa ; old\r\n'
       'if $object_detected\r\n    this = ResourceBody\r\nendif\r\n')


class PlannerTests(unittest.TestCase):
    def test_known_hash_and_binding_before_draw_idempotent(self):
        p = h.plan_bytes(INI.encode(), DB, True)
        self.assertEqual(p.character, 'Hero')
        text = p.after.decode()
        self.assertIn('hash = bbbbbbbb ; old', text)
        self.assertIn('hash = 11111111', text)  
        self.assertIn('Resource\\RabbitFX\\Diffuse = ref ResourceBody', text)
        self.assertLess(text.index('CommandList\\RabbitFX\\SetTextures'), text.index('drawindexed'))
        self.assertEqual(h.plan_bytes(p.after, DB, True).after, p.after)

    def test_unknown_or_multiple_characters_unchanged(self):
        self.assertEqual(h.plan_bytes(b'[X]\nhash = 11111111\n', DB, True).after,
                         b'[X]\nhash = 11111111\n')
        db = copy.deepcopy(DB)
        db['characters']['Other'] = copy.deepcopy(db['characters']['Hero'])
        self.assertEqual(h.plan_bytes(INI.encode(), db, True).after, INI.encode())

    def test_conditional_resource_switch_not_flattened(self):
        text = INI.replace('    this = ResourceBody',
                           '    if $outfit\r\n        this = ResourceBody\r\n    else\r\n        this = ResourceOther\r\n    endif')
        p = h.plan_bytes(text.encode(), DB, True)
        self.assertNotIn(b'Resource\\RabbitFX\\Diffuse', p.after)
        self.assertTrue(p.warnings)

    def test_existing_bindings_preserved(self):
        text = INI.replace('    drawindexed', '    Resource\\RabbitFX\\Normalmap = ref ResourceCustom\r\n    run = CommandList\\RabbitFX\\SetTextures\r\n    drawindexed')
        p = h.plan_bytes(text.encode(), DB, True)
        self.assertIn(b'Normalmap = ref ResourceCustom', p.after)
        self.assertNotIn(b'Resource\\RabbitFX\\Diffuse', p.after)

    def test_missing_rabbit_or_texture_is_reported(self):
        p = h.plan_bytes(INI.encode(), DB, False)
        self.assertNotIn(b'SetTextures', p.after)
        self.assertTrue(p.warnings)

    def test_utf16_bom_and_crlf_preserved(self):
        p = h.plan_bytes(INI.encode('utf-16'), DB, True)
        self.assertTrue(p.after.startswith(b'\xff\xfe'))
        self.assertIn('hash = bbbbbbbb', p.after.decode('utf-16'))
        self.assertNotIn('\n', p.after.decode('utf-16').replace('\r\n', ''))

    def test_ambiguous_character_skipped_without_blocking_other_characters(self):
        db = copy.deepcopy(DB)
        db['characters']['Hero']['textures']['eeeeeeee'] = {'replace': ['aaaaaaaa']}
        h.validate_database(db)
        p = h.plan_bytes(INI.encode(), db, True)
        self.assertEqual(p.after, INI.encode())
        self.assertTrue(p.warnings)

    def test_slot_only_metadata_can_update_hash_without_injection(self):
        db = copy.deepcopy(DB)
        db['characters']['Hero']['textures']['bbbbbbbb']['meta'] = {'slot': [8]}
        h.validate_database(db)
        p = h.plan_bytes(INI.encode(), db, True)
        self.assertIn(b'hash = bbbbbbbb', p.after)
        self.assertNotIn(b'SetTextures', p.after)

    def test_global_16_digit_rules_are_valid_but_not_applied(self):
        db = copy.deepcopy(DB)
        db['characters']['UID'] = {'textures': {'1234567890abcdef': {'replace': ['1111222233334444']}}}
        h.validate_database(db)
        self.assertEqual(h.plan_bytes(INI.encode(), db, True).character, 'Hero')

    def test_skip_component_does_not_receive_bindings(self):
        text = INI.replace('Component3', 'Component7')
        db = copy.deepcopy(DB)
        db['characters']['Hero']['textures']['bbbbbbbb']['meta']['id'] = 7
        p = h.plan_bytes(text.encode(), db, True)
        self.assertIn(b'hash = bbbbbbbb', p.after)
        self.assertNotIn(b'SetTextures', p.after)

    def test_two_resources_for_same_channel_not_arbitrarily_chosen(self):
        text = INI + '[ResourceOther]\nfilename = Other.dds\n[TextureOverrideOther]\nhash = aaaaaaaa\nthis = ResourceOther\n'
        p = h.plan_bytes(text.encode(), DB, True)
        self.assertNotIn(b'SetTextures', p.after)
        self.assertTrue(any('ambiguous' in w for w in p.warnings))

    def test_big_endian_bom_preserved(self):
        p = h.plan_bytes(b'\xfe\xff' + INI.encode('utf-16-be'), DB, True)
        self.assertTrue(p.after.startswith(b'\xfe\xff'))
        self.assertIn('hash = bbbbbbbb', p.after.decode('utf-16'))

    def test_command_list_texture_assignment_not_bypassed(self):
        for directive in ('run = CommandListChooseTexture', 'handling = skip', 'condition = $outfit'):
            text = INI.replace('    this = ResourceBody', '    this = ResourceBody\r\n    ' + directive)
            p = h.plan_bytes(text.encode(), DB, True)
            self.assertNotIn(b'SetTextures', p.after)
            self.assertTrue(p.warnings)


class FileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mod = self.root / 'Hero' / 'mod.ini'
        self.mod.parent.mkdir()
        self.mod.write_bytes(INI.encode())
        (self.mod.parent / 'Textures').mkdir()
        (self.mod.parent / 'Textures' / 'Body.dds').write_bytes(b'DDS test')
        rabbit = self.root / 'RabbitFX'
        rabbit.mkdir()
        (rabbit / 'RabbitFX.ini').write_text('namespace = RabbitFX\n[CommandListSetTextures]\n')

    def test_scan_is_readonly_apply_and_rollback_exact(self):
        plans = h.scan(self.root, DB)
        self.assertEqual(self.mod.read_bytes(), INI.encode())
        journal = h.apply(self.root, plans, self.root / 'state')
        self.assertIn(b'hash = bbbbbbbb', self.mod.read_bytes())
        h.rollback(self.root, journal)
        self.assertEqual(self.mod.read_bytes(), INI.encode())

    def test_stale_plan_refused_before_any_write(self):
        plans = h.scan(self.root, DB)
        self.mod.write_bytes(b'user edit')
        with self.assertRaises(ValueError):
            h.apply(self.root, plans, self.root / 'state')
        self.assertEqual(self.mod.read_bytes(), b'user edit')

    def test_rollback_refuses_to_overwrite_later_edit(self):
        journal = h.apply(self.root, h.scan(self.root, DB), self.root / 'state')
        self.mod.write_bytes(b'user edit')
        with self.assertRaises(ValueError):
            h.rollback(self.root, journal)
        self.assertEqual(self.mod.read_bytes(), b'user edit')

    def test_disabled_folders_not_scanned(self):
        off = self.root / 'DISABLED_old'
        off.mkdir()
        (off / 'mod.ini').write_bytes(INI.encode())
        self.assertEqual(len(h.scan(self.root, DB)), 1)

    def test_missing_local_resource_skips_binding(self):
        (self.mod.parent / 'Textures' / 'Body.dds').unlink()
        p = h.scan(self.root, DB)[0]
        self.assertNotIn(b'SetTextures', p.after)
        self.assertTrue(p.warnings)

    def test_journal_path_traversal_refused(self):
        journal = h.apply(self.root, h.scan(self.root, DB), self.root / 'state')
        data = json.loads(journal.read_text())
        data['entries'][0]['path'] = '../outside.ini'
        journal.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            h.rollback(self.root, journal)

    def test_backup_corruption_refused(self):
        journal = h.apply(self.root, h.scan(self.root, DB), self.root / 'state')
        changed = self.mod.read_bytes()
        (journal.parent / '0000.bak').write_bytes(b'broken')
        with self.assertRaises(ValueError):
            h.rollback(self.root, journal)
        self.assertEqual(self.mod.read_bytes(), changed)

    def test_entire_batch_preflight_before_first_write(self):
        second = self.mod.parent / 'second.ini'
        second.write_bytes(INI.encode())
        plans = h.scan(self.root, DB)
        second.write_bytes(b'changed after scan')
        with self.assertRaises(ValueError):
            h.apply(self.root, plans, self.root / 'state')
        self.assertEqual(self.mod.read_bytes(), INI.encode())
        self.assertFalse((self.root / 'state').exists())

    def test_cli_version_mismatch_and_no_yes_are_readonly(self):
        database = self.root / 'database.json'
        database.write_text(json.dumps(DB))
        for extra in (['--game-version', '3.6', '--yes'], ['--game-version', '3.7']):
            with contextlib.redirect_stderr(io.StringIO()):
                code = h.main(['apply', str(self.root), '--database', str(database), *extra])
            self.assertEqual(code, 2)
            self.assertEqual(self.mod.read_bytes(), INI.encode())

    def test_cli_apply_report_and_rollback(self):
        database = self.root / 'database.json'
        database.write_text(json.dumps(DB))
        state = self.root / 'backups'
        with contextlib.redirect_stdout(io.StringIO()):
            code = h.main(['apply', str(self.root), '--database', str(database),
                           '--reports', str(self.root / 'reports'), '--state', str(state),
                           '--game-version', '3.7', '--yes'])
        self.assertEqual(code, 0)
        reports = list((self.root / 'reports').glob('*/report.json'))
        self.assertEqual(len(reports), 1)
        self.assertEqual(json.loads(reports[0].read_text())['files'][0]['character'], 'Hero')
        journal = next(state.glob('*/journal.json'))
        h.rollback(self.root, journal)
        self.assertEqual(self.mod.read_bytes(), INI.encode())

    def test_automatic_run_updates_scans_applies_without_prompts(self):
        database = self.root / 'database.json'
        def download(destination):
            destination.write_text(json.dumps(DB))
        with patch.object(h, 'update_database', side_effect=download), contextlib.redirect_stdout(io.StringIO()):
            code = h.main(['run', str(self.root), '--database', str(database),
                           '--reports', str(self.root / 'reports'), '--state', str(self.root / 'backups')])
        self.assertEqual(code, 0)
        self.assertIn(b'hash = bbbbbbbb', self.mod.read_bytes())
        self.assertEqual(len(list((self.root / 'backups').glob('*/journal.json'))), 1)

    def test_automatic_run_uses_valid_cache_when_offline(self):
        database = self.root / 'database.json'
        database.write_text(json.dumps(DB))
        with patch.object(h, 'update_database', side_effect=OSError('offline')), contextlib.redirect_stdout(io.StringIO()):
            code = h.main(['run', str(self.root), '--database', str(database),
                           '--reports', str(self.root / 'reports'), '--state', str(self.root / 'backups')])
        self.assertEqual(code, 0)
        self.assertIn(b'hash = bbbbbbbb', self.mod.read_bytes())

    def test_automatic_run_without_database_fails_without_writes(self):
        with patch.object(h, 'update_database', side_effect=OSError('offline')), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = h.main(['run', str(self.root), '--database', str(self.root / 'missing.json')])
        self.assertEqual(code, 2)
        self.assertEqual(self.mod.read_bytes(), INI.encode())


if __name__ == '__main__':
    unittest.main()
