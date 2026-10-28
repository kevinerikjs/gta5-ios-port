"""Generate fail-fast glue for imports not implemented by the native host yet."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
header = (root / 'Generated/game.h').read_text()
implemented = '\n'.join(p.read_text() for p in (root / 'Source').glob('*') if p.suffix in ('.c', '.m', '.mm'))
pattern = r"/\* import: '([^']+)' '([^']+)' \*/\n(\w+) (w2c_\w+)\(([^;]+)\);"
functions = re.findall(pattern, header)
output = ['#include "HostInternal.h"\n#include "wasm-rt-impl.h"\n#include <string.h>\n']
report = []
for module, field, result, name, signature in functions:
    if re.search(r'\b'+name+r'\s*\([^;]*\)\s*\{', implemented):
        report.append(f'{module}.{field}\timplemented')
        continue
    types = [x.strip() for x in signature.split(',')]
    params = [f'{kind} a{i}' for i, kind in enumerate(types)]
    output.append(f'{result} {name}({", ".join(params)}) {{')
    if field.startswith('invoke_'):
        args = types[2:]
        cast = ', '.join(['void *'] + args)
        # The caller's instance, not the entry's (the same pointer, unless the table is shared: GTA-217)
        actual = ', '.join(['&a0->game'] + [f'a{i}' for i in range(2,len(types))])
        wasm_types = {'u32':'WASM_RT_I32', 'u64':'WASM_RT_I64', 'f32':'WASM_RT_F32', 'f64':'WASM_RT_F64'}
        signature_types = args + ([] if result == 'void' else [result])
        expected = ', '.join([str(len(args)), '0' if result == 'void' else '1'] + [wasm_types[t] for t in signature_types])
        output.extend([
            '  wasm_rt_funcref_table_t *table = w2c_game_0x5F_indirect_function_table(&a0->game);',
            '  if (a1 >= table->size) wasm_rt_trap(WASM_RT_TRAP_CALL_INDIRECT);',
            '  wasm_rt_funcref_t entry = table->data[a1];',
            '  if (!entry.func) wasm_rt_trap(WASM_RT_TRAP_CALL_INDIRECT);',
            f'  wasm_rt_func_type_t expected = wasm2c_game_get_func_type({expected});',
            '  if (!entry.func_type || memcmp(entry.func_type, expected, 32)) wasm_rt_trap(WASM_RT_TRAP_CALL_INDIRECT);',
            f'  {"return " if result != "void" else ""}(({result} (*)({cast}))entry.func)({actual});'
        ])
        report.append(f'{module}.{field}\tforwarded to native engine table; EH remains unported')
    else:
        output.append(f'  pg_missing_import("{module}.{field}");')
        if result != 'void': output.append('  return 0;')
        report.append(f'{module}.{field}\tunported: stops the boot probe')
    output.append('}\n')
(root / 'Generated/Imports.c').write_text('\n'.join(output))
(root / 'Build/import-status.tsv').write_text('\n'.join(report)+'\n')
print(f'Generated {len(functions)} typed import bindings.')
