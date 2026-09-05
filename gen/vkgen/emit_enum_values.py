"""Emit the enum-value golden-check companion table (DESIGN.md \u00a75/\u00a712/\u00a713).

`Vk.Enum_values.all` pairs every C enum constant / bitmask bit name with its
resolved OCaml `int` value, using exactly the same enum/bitmask block
selection and alias resolution as emit_enums.py (`resolve_enum_values` in
emit_common.py) so the two can never silently disagree about what a given
value module *means* -- only whether the registry's arithmetic (bitpos,
extension offset, alias chasing, ...) matches what the real Vulkan-Headers
enumerator/`#define` actually evaluates to, which is what
test/test_enum_values.ml checks against test/enum_values/<arch>.txt
(produced by gen/enum_check.py + scripts/gen_enum_values.sh from the real
headers, mirroring gen/layout_check.py + scripts/gen_layout.sh).
"""
from __future__ import annotations

from pathlib import Path

from .emit_common import Context, ocaml_int, resolve_enum_values, write_generated


def emit(ctx: Context, out: Path) -> None:
    registry = ctx.registry
    pairs: list[tuple[str, int]] = []
    seen: set[str] = set()

    def add(values) -> None:
        for value, number in resolve_enum_values(ctx, values):
            if value.name in seen:
                continue
            seen.add(value.name)
            pairs.append((value.name, number))

    # Mirrors emit_enums.py's three passes exactly: ordinary enums, one flags
    # module per Flags typedef (values from the paired FlagBits enum, if
    # any), then standalone FlagBits blocks with no paired Flags typedef.
    for name, enum in registry.enums.items():
        if enum.kind == "enum" and not enum.alias:
            add(enum.values)

    for name, bitmask in registry.bitmasks.items():
        if bitmask.alias:
            continue
        bits_name = bitmask.bits
        if not bits_name:
            bits_name = next((bits for bits, flags in ctx.bits_to_flags.items() if flags == name), None)
        enum = registry.enums.get(bits_name or "")
        if enum:
            add(enum.values)

    for name, enum in registry.enums.items():
        if enum.kind == "bitmask" and name not in ctx.bits_to_flags:
            add(enum.values)

    pairs.sort(key=lambda pair: pair[0])
    lines = ["let all : (string * int) list = ["]
    lines.extend(f'  ("{name}", {ocaml_int(number)});' for name, number in pairs)
    lines.append("]")
    write_generated(out / "vk_enum_values.ml", "\n".join(lines) + "\n")
