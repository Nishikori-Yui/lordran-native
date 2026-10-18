"""Budget table export regression: small logs with closed-form expectations, no game or GPU needed; temp files go only under run/gfx."""
import csv
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
DM_ROOT = os.environ.get('DM_ROOT') or os.path.expanduser('~/dm-work')   # Workspace root (game files, build outputs and run artifacts are all under it)

TOOL = Path(os.environ.get('TBDR_BUDGET_TOOL', Path(__file__).resolve().parents[1] / 'tools/tbdr_budget.py'))

class BudgetExport(unittest.TestCase):
    def export(self, text):
        root = Path(DM_ROOT) / 'run/gfx'
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='budget_test_', dir=root) as tmp:
            log, out = Path(tmp) / 'pass.log', Path(tmp) / 'pass.tsv'
            log.write_text(text)
            p = subprocess.run([sys.executable, str(TOOL), str(log), '700', '170', '--tsv=' + str(out)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertTrue(out.exists(), '全量通道 TSV 未导出')
            with out.open() as f:
                return list(csv.DictReader(f, delimiter='\t'))

    def test_all_passes_not_only_console_top25(self):
        # 30 independent 4×4 RGBA8 clears: each stores 4×4×4=64 bytes.
        rows = self.export(''.join(f'[pass] F700 P {p} c0 ser={p} fmt=70 4x4 ms1 lv0 sl0 clear\n' for p in range(1, 31)))
        self.assertEqual(len(rows), 30)
        self.assertEqual([int(x['pass']) for x in rows], list(range(1, 31)))
        self.assertEqual(sum(int(x['store_bytes']) for x in rows), 1920)
        self.assertTrue(all(x['draw_source'] == 'clear_only' for x in rows))

    def test_draws_attachment_bytes_and_untruncated_shader_keys(self):
        key = '0123456789abcdef'
        rows = self.export(f'''[pass] F700 P 501 c0 ser=1 fmt=70 4x4 ms1 lv0 sl0 load
[pass] F700 Z 501 c ser=1 lv0 sl0 dontcare why=0
[pass] F700 P 502 c0 ser=2 fmt=70 8x4 ms1 lv0 sl0 clear
[pass] F700 K 502 st1 key={key}_b nb=1
[pass] F700 B 502 st1 tex reg0 tid=1 实 ser=12 fmt=70 8x4x1
[pass] F700 R 502 st1 ser=12
[pass] F700 d 502 fs={key}_b vc=3
[pass] F700 d 502 fs={key}_b vc=3
''')
        self.assertEqual((rows[0]['load_bytes'], rows[0]['store_bytes']), ('64', '0'))
        self.assertEqual((rows[1]['draws'], rows[1]['draw_source']), ('2', 'PASSDUMP_ALL'))
        self.assertEqual(rows[1]['fragment_keys'], key)
        self.assertEqual(rows[1]['texture_est_bytes'], '128')
        self.assertEqual(rows[1]['unknown_textures'], '0')

    def test_unknown_texture_metadata_is_reported(self):
        rows = self.export('''[pass] F700 P 1 c0 ser=1 fmt=70 4x4 ms1 lv0 sl0 clear
[pass] F700 R 1 st1 ser=99
[pass] F700 d 1 fs=unknown_b vc=3
''')
        self.assertEqual(rows[0]['unknown_textures'], '1')
        self.assertEqual(rows[0]['texture_est_bytes'], '64')

    def test_english_records_with_timestamp_level_and_thread(self):
        prefix = '[2026-10-19T00:00:00.001Z] [DEBUG] [metal.pass] [thread=42] '
        records = '''[pass] F700 P 1 c0 ser=1 fmt=70 8x4 ms1 lv0 sl0 clear
[pass] F700 B 1 st1 tex reg0 tid=1 real ser=99 fmt=70 8x4x1
[pass] F700 R 1 st1 ser=99
[pass] F700 d 1 fs=unknown_b vc=3
[pass] F700 F 1 merging next pass (tile readable): physical_attachments=1 previous_attachments=1
'''
        rows = self.export(''.join(prefix + line + '\n' for line in records.splitlines()))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['texture_est_bytes'], '128')
        self.assertEqual(rows[0]['unknown_textures'], '0')
        self.assertIn('tile', rows[0]['note'])

    def test_pass_analysis_tools_accept_structured_prefix(self):
        records = '''[pass] F700 P 1 c0 ser=1 fmt=70 1024x1024 ms1 lv0 sl0 clear
[pass] F700 P 2 c0 ser=1 fmt=70 1024x1024 ms1 lv0 sl0 load
[pass] F700 D 2 prim=4 vc=3 inst=1 blend=0 wm=f dt=0 dw=0 df=8 st=0 sc=0,0,1024,1024 tgt=1024x1024 vp=0,0,1024,1024
[pass] F701 P 3 c0 ser=1 fmt=70 1024x1024 ms1 lv0 sl0 clear
'''
        prefix = '[2026-10-19T00:00:00.001Z] [DEBUG] [metal.pass] [thread=42] '
        root = Path(DM_ROOT) / 'run/gfx'
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='pass_test_', dir=root) as tmp:
            raw, structured = Path(tmp) / 'raw.log', Path(tmp) / 'structured.log'
            raw.write_text(records)
            structured.write_text(''.join(prefix + line + '\n' for line in records.splitlines()))
            for name in ('tbdr_pass_merge.py', 'tbdr_store_dead.py', 'tbdr_load_dead.py'):
                with self.subTest(tool=name):
                    results = [subprocess.run([sys.executable, str(TOOL.with_name(name)), str(log)],
                        capture_output=True, text=True) for log in (raw, structured)]
                    for result in results:
                        self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(results[0].stdout, results[1].stdout)
                    self.assertIn('4.2' if name != 'tbdr_pass_merge.py' else '8.4', results[1].stdout)

    def test_texture_views_do_not_leak_between_passes(self):
        # Both passes output 8×4; the actual bound views of the same ser=99 are 8×4 and 4×4 respectively.
        # RGBA8: independent expectations of 128 / 64 bytes; the later pass's size must not overwrite the earlier pass's.
        rows = self.export('''[pass] F700 P 1 c0 ser=1 fmt=70 8x4 ms1 lv0 sl0 clear
[pass] F700 B 1 st1 tex reg0 tid=1 实 ser=99 fmt=70 8x4x1
[pass] F700 R 1 st1 ser=99
[pass] F700 d 1 fs=unknown_b vc=3
[pass] F700 P 2 c0 ser=2 fmt=70 8x4 ms1 lv0 sl0 clear
[pass] F700 B 2 st1 tex reg0 tid=2 实 ser=99 fmt=70 4x4x1
[pass] F700 R 2 st1 ser=99
[pass] F700 d 2 fs=unknown_b vc=3
''')
        self.assertEqual([x['texture_est_bytes'] for x in rows], ['128', '64'])

    def test_distinct_views_within_same_pass_are_kept(self):
        rows = self.export('''[pass] F700 P 1 c0 ser=1 fmt=70 8x4 ms1 lv0 sl0 clear
[pass] F700 B 1 st1 tex reg0 tid=1 实 ser=99 fmt=70 8x4x1
[pass] F700 R 1 st1 ser=99
[pass] F700 B 1 st1 tex reg1 tid=2 实 ser=99 fmt=70 4x4x1
[pass] F700 R 1 st1 ser=99
[pass] F700 d 1 fs=unknown_b vc=3
''')
        self.assertEqual(rows[0]['texture_est_bytes'], '192')

if __name__ == '__main__':
    unittest.main()
