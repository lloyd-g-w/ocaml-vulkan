"""Emit enum and flag modules."""
from __future__ import annotations

from pathlib import Path

from .emit_common import Context, ocaml_int, write_generated
from . import naming
from .registry import EnumValue


def _resolved_values(ctx: Context, values: list[EnumValue]) -> list[tuple[EnumValue, int]]:
    global_values: dict[str, int] = {}
    pending: list[EnumValue] = []
    for enum in ctx.registry.enums.values():
        for value in enum.values:
            if isinstance(value.value, int):
                global_values.setdefault(value.name, value.value)
            elif value.alias:
                pending.append(value)
    changed = True
    while changed and pending:
        changed = False
        rest: list[EnumValue] = []
        for value in pending:
            if value.alias in global_values:
                global_values[value.name] = global_values[value.alias]
                changed = True
            else:
                rest.append(value)
        pending = rest
    out = []
    for value in values:
        resolved = value.value if isinstance(value.value, int) else global_values.get(value.alias or "")
        if isinstance(resolved, int):
            out.append((value, resolved))
    return out


def _module(ctx: Context, ctype: str, module: str, values: list[EnumValue],
            *, flags: bool, bitwidth: int) -> str:
    functor = ("Flags" if flags else "Enum") + ("64" if bitwidth == 64 else "32")
    lines = [f"module {module} = struct", f"  include Vk_base.{functor} ()", f"  let () = set_type_name \"{module}\""]
    used: dict[str, int] = {}
    constants: list[tuple[str, str]] = []
    for value, number in _resolved_values(ctx, values):
        identifier = naming.enum_value_name(ctype, value.name, ctx.registry.tags)
        if identifier in used:
            used[identifier] += 1
            identifier = f"{identifier}_{used[identifier]}"
        else:
            used[identifier] = 1
        lines.append(f"  let {identifier} = of_int ({ocaml_int(number)})")
        constants.append((identifier, value.name))
    lines.append("  let () = register [")
    lines.extend(f'    ({identifier}, "{c_name}");' for identifier, c_name in constants)
    lines.append("  ]")
    lines.append("end")
    return "\n".join(lines)


def emit(ctx: Context, out: Path) -> None:
    registry = ctx.registry
    sections = ["open Ctypes\n"]

    # Ordinary enums (aliases are emitted after canonical modules).
    for name, enum in registry.enums.items():
        if enum.kind != "enum" or enum.alias:
            continue
        sections.append(_module(ctx, name, naming.module_name(name), enum.values,
                                flags=False, bitwidth=enum.bitwidth))

    # One flags module per Flags typedef.  Its values come from the paired
    # FlagBits enum (possibly empty).
    for name, bitmask in registry.bitmasks.items():
        if bitmask.alias:
            continue
        bits_name = bitmask.bits
        if not bits_name:
            bits_name = next((bits for bits, flags in ctx.bits_to_flags.items() if flags == name), None)
        enum = registry.enums.get(bits_name or "")
        values = enum.values if enum else []
        width = 64 if bitmask.base == "VkFlags64" or (enum and enum.bitwidth == 64) else 32
        sections.append(_module(ctx, bits_name or name, naming.module_name(name), values,
                                flags=True, bitwidth=width))

    # Rare standalone FlagBits blocks still get a useful flags module.
    for name, enum in registry.enums.items():
        if enum.kind == "bitmask" and name not in ctx.bits_to_flags:
            sections.append(_module(ctx, name, naming.module_name(name), enum.values,
                                    flags=True, bitwidth=enum.bitwidth))

    for name, enum in registry.enums.items():
        if enum.alias and enum.alias in registry.enums:
            sections.append(f"module {naming.module_name(name)} = {ctx.enum_module(enum.alias)}")
    for name, bitmask in registry.bitmasks.items():
        if bitmask.alias and bitmask.alias in registry.bitmasks:
            sections.append(f"module {naming.module_name(name)} = {naming.module_name(bitmask.alias)}")

    if "VkResult" in registry.enums:
        sections.append("""exception Error of Result.t
let check result = if Result.to_int result < 0 then raise (Error result)
let () =
  Printexc.register_printer (function
    | Error result -> Some (\"Vk.Error(\" ^ Result.to_string result ^ \")\")
    | _ -> None)""")

    write_generated(out / "vk_enums.ml", "\n\n".join(sections) + "\n")
