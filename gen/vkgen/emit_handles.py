"""Emit Vulkan handle modules."""
from __future__ import annotations

from pathlib import Path

from .emit_common import Context, spec_doc, write_generated
from . import naming


def emit(ctx: Context, out: Path) -> None:
    lines = ["module type HANDLE = Vk_base.HANDLE", ""]
    for name, handle in ctx.registry.handles.items():
        if handle.alias:
            continue
        functor = "Dispatchable" if handle.dispatchable else "Non_dispatchable"
        kind = "Dispatchable handle " if handle.dispatchable else "Non-dispatchable handle "
        lines.append("")
        lines.append(spec_doc(name, kind))
        lines.append(f"module {naming.module_name(name)} : HANDLE = Vk_base.{functor} ()")
    for name, handle in ctx.registry.handles.items():
        if handle.alias and handle.alias in ctx.registry.handles:
            lines.append("")
            lines.append(spec_doc(name, "Alias of "))
            lines.append(f"module {naming.module_name(name)} = {naming.module_name(handle.alias)}")
    write_generated(out / "vk_handles.ml", "\n".join(lines) + "\n")
