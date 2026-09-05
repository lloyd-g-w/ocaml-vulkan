"""Emit faithful raw Vulkan command bindings and proc-address loaders."""
from __future__ import annotations

from pathlib import Path

from .emit_common import Context, spec_doc, write_generated
from . import naming
from .registry import Command


def _signature(ctx: Context, command: Command) -> str:
    parts = [ctx.foreign_typ(param, strings=True) for param in command.params]
    result = ctx.foreign_typ(command.result, strings=True) if command.result else "Ctypes.void"
    if not parts:
        parts = ["Ctypes.void"]
    return " @-> ".join(parts + [f"returning ({result})"])


def _declaration(ctx: Context, command: Command) -> str:
    name = naming.command_name(command.name)
    args = [f"arg{i}" for i in range(len(command.params))]
    if not args:
        args = ["()"]
    ensure = "Vk_base.Loader.ensure (); " if command.level == "global" else ""
    call = "f " + " ".join(args)
    return f'''let {name}_typ = {_signature(ctx, command)}
let {name}_ref = ref (bind {name}_typ Ctypes.null)

{spec_doc(command.name, "Raw ")}
let {name} {' '.join(args)} =
  {ensure}match !{name}_ref with
  | Some f -> {call}
  | None -> Vk_base.not_loaded "{command.name}"'''


def emit(ctx: Context, out: Path, chunks: list[str]) -> None:
    opens = ["open Ctypes", "open Vk_enums", "open Vk_handles", *[f"open {chunk}" for chunk in chunks]]
    sections = ["\n".join(opens), "let bind signature address = coerce (ptr void) (Foreign.funptr_opt signature) address"]
    commands = list(ctx.registry.commands.values())
    sections.extend(_declaration(ctx, command) for command in commands)

    global_commands = [c for c in commands if c.level == "global"]
    instance_commands = [c for c in commands if c.level in {"instance", "device"}]
    device_commands = [c for c in commands if c.level == "device"]

    global_lines = ["let load_global () =", "  let get name = Vk_base.Loader.get_instance_proc_addr Ctypes.null name in"]
    for command in global_commands:
        name = naming.command_name(command.name)
        global_lines.append(f"  {name}_ref := bind {name}_typ (get \"{command.name}\");")
    global_lines.append("  ()")
    sections.append("\n".join(global_lines))

    instance_lines = [
        "let load_instance instance =",
        "  Vk_base.Loader.ensure ();",
        "  let raw = Ctypes.ptr_of_raw_address (Instance.to_nativeint instance) in",
        "  let get name = Vk_base.Loader.get_instance_proc_addr raw name in",
    ]
    for command in instance_commands:
        name = naming.command_name(command.name)
        instance_lines.append(f"  {name}_ref := bind {name}_typ (get \"{command.name}\");")
    instance_lines.append("  ()")
    sections.append("\n".join(instance_lines))

    device_lines = [
        "let load_device device =",
        "  Vk_base.Loader.ensure ();",
        "  let raw = Ctypes.ptr_of_raw_address (Device.to_nativeint device) in",
        "  let get name = Vk_base.Loader.get_device_proc_addr raw name in",
    ]
    for command in device_commands:
        name = naming.command_name(command.name)
        device_lines.append(f"  {name}_ref := bind {name}_typ (get \"{command.name}\");")
    device_lines.append("  ()")
    sections.append("\n".join(device_lines))

    sections.append("""let () =
  Vk_base.Loader.global_hook := load_global;
  Vk_base.Loader.instance_hook :=
    (fun raw -> load_instance (Instance.of_nativeint (Ctypes.raw_address_of_ptr raw)));
  Vk_base.Loader.device_hook :=
    (fun raw -> load_device (Device.of_nativeint (Ctypes.raw_address_of_ptr raw)))""")
    write_generated(out / "vk_fn.ml", "\n\n".join(sections) + "\n")
