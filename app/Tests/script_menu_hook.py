"""Guard the scheduling boundary that engine-free spawn tests cannot reproduce."""
from pathlib import Path
import sys
import unittest

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'Scripts'))
from prepare_script_menu import patch
from engine_names import fn


class ScriptMenuHookTests(unittest.TestCase):
    def test_real_engine_hook_is_unique_and_idempotent(self):
        number = fn('GtaThread::Update(int)')
        head = f'u32 w2c_game_f{number}(w2c_game* instance, u64 var_p0, u32 var_p1) {{'
        source = next(p.read_text() for p in (root / 'Generated').glob('game_*.c') if head in p.read_text())
        patched = patch(source, number)
        self.assertEqual(patched.count('  pg_script_menu_tick(instance, var_p0);'), 1)
        self.assertEqual(patch(patched, number), patched)
        # Also exercise fresh preparation, not only the already-patched case.
        fresh = patched.replace('  pg_script_menu_tick(instance, var_p0);\n', '').replace(
            '\nextern void pg_script_menu_tick(w2c_game *instance, u64 thread);', '')
        self.assertEqual(patch(fresh, number), patched)
        with self.assertRaises(RuntimeError):
            patch(fresh.replace('614u', '615u'), number)

    def test_pad_worker_cannot_execute_menu_mutations(self):
        source = (root / 'Source/EngineHost.c').read_text()
        begin = source.index('void pg_virtual_pad_apply(')
        body = source[begin:source.index('\n}\n', begin)]
        self.assertNotIn('pg_vehicle_menu_', body)
        self.assertNotIn('pg_native_cheats_tick', body)
        self.assertNotIn('pg_script_menu_tick', body)
        for name in ['prepare.py', 'build_native.sh', 'build_simulator.sh']:
            self.assertIn('prepare_script_menu.py', (root / 'Scripts' / name).read_text())


if __name__ == '__main__':
    unittest.main()
