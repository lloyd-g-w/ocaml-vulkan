"""Emit registry constants and extension metadata."""
from __future__ import annotations

from pathlib import Path

from .emit_common import Context, ocaml_int, ocaml_string, write_generated
from . import naming


def _literal(value: int | float | str) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return ocaml_int(value)
    if isinstance(value, float):
        text = repr(value)
        return text if any(c in text for c in ".eE") else text + "."
    return ocaml_string(value)


def emit(ctx: Context, out: Path) -> None:
    lines: list[str] = []
    for c_name, value in sorted(ctx.registry.constants.items()):
        lines.append(f"let {naming.constant_name(c_name)} = {_literal(value)}")
    if "VK_HEADER_VERSION" in ctx.registry.constants:
        lines.append("let header_version = vk_header_version")
    if "VK_WHOLE_SIZE" not in ctx.registry.constants:
        lines.append("let whole_size = -1")

    lines.append("\nmodule Ext = struct")
    for ext in sorted(ctx.registry.extensions.values(), key=lambda x: x.name):
        ident = naming.extension_name(ext.name)
        if ext.extension_name is not None:
            lines.append(f"  let {ident} = {ocaml_string(ext.extension_name)}")
        else:
            # The registry name is the C extension string for reserved entries
            # that do not carry explicit metadata.
            lines.append(f"  let {ident} = {ocaml_string(ext.name)}")
        if ext.spec_version is not None:
            lines.append(f"  let {ident}_spec_version = {ext.spec_version}")
    lines.append("end")
    write_generated(out / "vk_consts.ml", "\n".join(lines) + "\n")
