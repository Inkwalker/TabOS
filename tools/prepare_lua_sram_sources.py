"""Generate tagged Lua allocation sites without modifying managed sources.

Lua's allocator sees a type tag only on new allocations. Tag initial VM stacks
and bytecode arrays; the TabOS allocator retains that class across realloc/free.
Refuse unfamiliar upstream code so dependency upgrades cannot silently lose
the placement policy. Generated files retain the upstream copyright notice.
"""
import argparse
from pathlib import Path


REPLACEMENTS = {
    'lstate.c': (
        'L1->stack.p = luaM_newvector(L, BASIC_STACK_SIZE + EXTRA_STACK, StackValue);',
        'L1->stack.p = cast(StackValue *, luaM_malloc_(L,\n'
        '      cast_sizet(BASIC_STACK_SIZE + EXTRA_STACK) * sizeof(StackValue),\n'
        '      TABOS_LUA_ALLOC_STACK));'),
    'lcode.c': (
        '  /* put new instruction in code array */\n'
        '  luaM_growvector(fs->ls->L, f->code, fs->pc, f->sizecode, Instruction,',
        '  /* Tag the initial buffer; subsequent grows retain its allocation class. */\n'
        '  if (f->code == NULL) {\n'
        '    f->code = cast(Instruction *, luaM_malloc_(fs->ls->L,\n'
        '        4 * sizeof(Instruction), TABOS_LUA_ALLOC_BYTECODE));\n'
        '    f->sizecode = 4;  /* same initial capacity as luaM_growaux_ */\n'
        '  }\n'
        '  /* put new instruction in code array */\n'
        '  luaM_growvector(fs->ls->L, f->code, fs->pc, f->sizecode, Instruction,'),
    'lundump.c': (
        'f->code = luaM_newvectorchecked(S->L, n, Instruction);',
        'luaM_checksize(S->L, n, sizeof(Instruction));\n'
        '    f->code = cast(Instruction *, luaM_malloc_(S->L,\n'
        '        cast_sizet(n) * sizeof(Instruction), TABOS_LUA_ALLOC_BYTECODE));'),
}


def generate(component, output):
    prepared = {}
    for name, (old, new) in REPLACEMENTS.items():
        source = (component / 'lua' / name).read_text()
        if source.count(old) != 1:
            raise ValueError(f'Unrecognized Lua allocation site in {name}; review the dependency update')
        prepared[name] = '#include "lua_memory_tags.h"\n' + source.replace(old, new, 1)
    output.mkdir(parents=True, exist_ok=True)
    for name, source in prepared.items():
        path = output / name
        if not path.exists() or path.read_text() != source:
            path.write_text(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component-dir', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    generate(args.component_dir, args.output_dir)
