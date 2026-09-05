"""Emit the ergonomic command layer.

The planner is intentionally shape based: unfamiliar registry additions still
receive a wrapper, while count/pointer, allocation-callback, enumeration, and
trailing-output idioms are recognized without a command-name allow-list.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from pathlib import Path

from .emit_common import Context, write_generated
from . import naming
from .registry import Command, Member


@dataclass
class Arg:
    param: Member
    label: str
    binding: str
    declaration: str
    call: str
    optional: bool = False
    prep: list[str] | None = None


def _pointee(ctx: Context, member: Member) -> str:
    return ctx.foreign_typ(replace(member, pointer_depth=member.pointer_depth - 1, arrays=()))


def _null(ctx: Context, member: Member) -> str:
    return f"Vk_base.null_ptr ({_pointee(ctx, member)})"


def _is_result(command: Command) -> bool:
    return command.result is not None and command.result.ctype == "VkResult" and command.result.pointer_depth == 0


def _is_void(command: Command) -> bool:
    return command.result is not None and command.result.ctype == "void" and command.result.pointer_depth == 0


def _has_stype(ctx: Context, ctype: str) -> bool:
    if ctype not in ctx.registry.composites:
        return False
    target = ctx.registry.composites[ctx.canonical_composite(ctype)]
    return any(m.name == "sType" for m in target.members)


def _input_pairs(command: Command) -> tuple[dict[str, list[Member]], dict[str, str]]:
    by_name = {p.name: p for p in command.params}
    pointer_for_count: dict[str, list[Member]] = {}
    count_for_pointer: dict[str, str] = {}
    for p in command.params:
        if not p.const or p.ctype == "void" or not p.length:
            continue
        count_name = p.length.split(",")[0].strip()
        count = by_name.get(count_name)
        if count and count.pointer_depth == 0 and (p.pointer_depth == 1 or (p.ctype == "char" and p.pointer_depth == 2)):
            pointer_for_count.setdefault(count_name, []).append(p)
            count_for_pointer[p.name] = count_name
    return pointer_for_count, count_for_pointer


def _enumeration(command: Command) -> tuple[Member, Member] | None:
    by_name = {p.name: p for p in command.params}
    for items in command.params:
        if items.const or items.pointer_depth != 1 or not items.length:
            continue
        count_name = items.length.split(",")[0].strip()
        count = by_name.get(count_name)
        if count and count.ctype == "uint32_t" and count.pointer_depth == 1 and not count.const:
            return count, items
    return None


def _trailing_output(ctx: Context, command: Command) -> Member | None:
    if not command.params:
        return None
    p = command.params[-1]
    if p.const or p.pointer_depth < 1 or p.length:
        return None
    if p.ctype == "void" and p.pointer_depth == 1:
        return None
    pointer_name = (
        p.name.startswith("p") and len(p.name) > 1 and p.name[1].isupper()
    ) or (
        p.name.startswith("pp") and len(p.name) > 2 and p.name[2].isupper()
    )
    if not pointer_name:
        return None
    # An output sType structure is supplied by the caller for pNext chaining.
    if p.pointer_depth == 1 and ctx.kind(p.ctype) == "struct" and _has_stype(ctx, p.ctype):
        return None
    return p


def _make_args(ctx: Context, command: Command, hidden: set[str]) -> tuple[list[Arg], dict[str, Arg]]:
    pointer_for_count, count_for_pointer = _input_pairs(command)
    used: set[str] = set()
    args: list[Arg] = []
    by_param: dict[str, Arg] = {}

    def fresh(value: str) -> str:
        root = value
        n = 2
        while value in used:
            value = f"{root}_{n}"
            n += 1
        used.add(value)
        return value

    for p in command.params:
        if p.name in hidden or p.name in pointer_for_count:
            continue
        if p.name in count_for_pointer:
            label = fresh(naming.argument_name(p.name, p.pointer_depth))
            binding = "arg_" + label
            elem_typ = ctx.base_typ(p.ctype)
            prep: list[str]
            if p.ctype == "char" and p.pointer_depth == 2:
                prep = [
                    f"  let strings_{label}, array_{label} = Vk_base.carray_of_strings {binding} in",
                    f"  ignore strings_{label};",
                    f"  let pointer_{label} = if {binding} = [] then {_null(ctx, p)} else CArray.start array_{label} in",
                ]
            else:
                prep = [
                    f"  let array_{label} = CArray.of_list ({elem_typ}) {binding} in",
                    f"  let pointer_{label} = if {binding} = [] then {_null(ctx, p)} else CArray.start array_{label} in",
                ]
            arg = Arg(p, label, binding, binding, f"pointer_{label}", prep=prep)
            args.append(arg); by_param[p.name] = arg
            continue

        label = fresh(naming.argument_name(p.name, p.pointer_depth))
        binding = "arg_" + label
        kind = ctx.kind(p.ctype)
        if p.name == "pAllocator" and p.ctype == "VkAllocationCallbacks" and p.pointer_depth == 1:
            arg = Arg(p, "allocator", "arg_allocator", "?allocator:arg_allocator",
                      "(match arg_allocator with None -> Vk_base.null_ptr AllocationCallbacks.t | Some x -> addr x)", True)
        elif p.ctype == "char" and p.pointer_depth == 1 and p.const and any(p.optional):
            arg = Arg(p, label, binding, f"?{label}:{binding}", binding, True)
        elif p.ctype == "char" and p.pointer_depth == 1 and p.const:
            arg = Arg(p, label, binding, binding, binding)
        elif p.pointer_depth == 1 and kind in {"struct", "union"} and (p.const or _has_stype(ctx, p.ctype)):
            arg = Arg(p, label, binding, binding, f"addr {binding}")
        else:
            arg = Arg(p, label, binding, binding, binding)
        args.append(arg); by_param[p.name] = arg

    # Count calls are derived from their list argument.  Vulkan has a few
    # commands (notably vkCmdBindVertexBuffers) where several arrays share one
    # count; reject mismatched OCaml lists before entering C.
    for count_name, pointers in pointer_for_count.items():
        list_args = [by_param[pointer.name] for pointer in pointers if pointer.name in by_param]
        if list_args:
            first = list_args[0]
            first.prep = first.prep or []
            for other in list_args[1:]:
                first.prep.append(
                    f"  if List.length {other.binding} <> List.length {first.binding} then invalid_arg \"{command.name}: array lengths differ\";"
                )
            synthetic = Arg(next(p for p in command.params if p.name == count_name), "", "", "",
                            f"List.length {first.binding}")
            by_param[count_name] = synthetic
    return args, by_param


def _function_head(command: Command, args: list[Arg], name: str, *, destructor: bool = False) -> str:
    optionals = [a for a in args if a.optional]
    required = [a for a in args if not a.optional]
    if destructor:
        declarations = [a.declaration for a in required] + [a.declaration for a in optionals] + ["()"]
    else:
        declarations = [a.declaration for a in optionals] + [a.declaration for a in required]
        if not required:
            declarations.append("()")
    return f"let {name} {' '.join(declarations)} ="


def _call(command: Command, by_param: dict[str, Arg], overrides: dict[str, str] | None = None) -> str:
    overrides = overrides or {}
    values = [overrides[p.name] if p.name in overrides else by_param[p.name].call for p in command.params]
    if not values:
        values = ["()"]
    return f"Vk_fn.{naming.command_name(command.name)} " + " ".join(f"({value})" for value in values)


def _output_allocation(ctx: Context, output: Member) -> tuple[list[str], str, str]:
    kind = ctx.kind(output.ctype)
    if output.pointer_depth == 1 and kind == "struct":
        module = naming.module_name(ctx.canonical_composite(output.ctype))
        return [f"  let output = {module}.make () in"], "addr output", "output"
    if output.pointer_depth == 1 and kind == "union":
        module = naming.module_name(ctx.canonical_composite(output.ctype))
        return [f"  let output = Ctypes.make {module}.t in"], "addr output", "output"
    pointee = _pointee(ctx, output)
    if output.pointer_depth > 1:
        initial = _null(ctx, replace(output, pointer_depth=output.pointer_depth - 1))
    elif kind == "handle":
        initial = f"{naming.module_name(output.ctype)}.null"
    elif kind in {"enum", "flags"}:
        initial = f"{ctx.enum_module(output.ctype)}.of_int 0"
    elif kind == "bool":
        initial = "false"
    elif kind == "float":
        initial = "0."
    elif kind == "pointer":
        initial = "Ctypes.null"
    elif kind == "void" or kind == "opaque":
        initial = "()"
    else:
        initial = "0"
    return [f"  let output = allocate ({pointee}) ({initial}) in"], "output", "!@ output"


def _result_tail(command: Command, value: str | None, *, create_instance: bool = False) -> list[str]:
    extra_success = [x for x in command.successcodes if x not in {"VK_SUCCESS", "VK_INCOMPLETE"}]
    lines = ["  check result;"]
    if create_instance and value:
        lines.append(f"  Vk_fn.load_instance {value};")
    if extra_success:
        lines.append(f"  (result, {value})" if value else "  result")
    else:
        lines.append(f"  {value}" if value else "  ()")
    return lines


def _emit_enumeration(ctx: Context, command: Command, pair: tuple[Member, Member]) -> str:
    count, items = pair
    hidden = {count.name, items.name}
    args, by_param = _make_args(ctx, command, hidden)
    name = naming.command_name(command.name)
    lines = [_function_head(command, args, name)]
    for arg in args:
        lines.extend(arg.prep or [])
    lines.extend([
        "  let count = allocate Vk_base.uint32 0 in",
        "  let rec fetch () =",
    ])
    null_items = _null(ctx, items)
    first_call = _call(command, by_param, {count.name: "count", items.name: null_items})
    if _is_result(command):
        lines.extend([f"    let first = {first_call} in", "    if Result.to_int first < 0 then check first;"])
    else:
        lines.append(f"    {first_call};")
    extra_success = [x for x in command.successcodes if x not in {"VK_SUCCESS", "VK_INCOMPLETE"}]
    empty_result = "(first, [])" if _is_result(command) and extra_success else "[]"
    lines.extend([
        "    let requested = !@ count in",
        f"    if requested = 0 then {empty_result} else",
    ])
    elem_typ = ctx.base_typ(items.ctype)
    kind = ctx.kind(items.ctype)
    if kind == "struct":
        module = naming.module_name(ctx.canonical_composite(items.ctype))
        lines.append(f"    let storage = CArray.of_list ({elem_typ}) (List.init requested (fun _ -> {module}.make ())) in")
    else:
        lines.append(f"    let storage = CArray.make ({elem_typ}) requested in")
    second_call = _call(command, by_param, {count.name: "count", items.name: "CArray.start storage"})
    if _is_result(command):
        lines.extend([
            f"    let result = {second_call} in",
            "    if Result.equal result Result.incomplete then fetch () else begin",
            "      check result;",
            ("      (result, CArray.to_list (CArray.from_ptr (CArray.start storage) (!@ count)))"
             if extra_success else
             "      CArray.to_list (CArray.from_ptr (CArray.start storage) (!@ count))"),
            "    end",
        ])
    else:
        lines.extend([
            f"    {second_call};",
            "    CArray.to_list (CArray.from_ptr (CArray.start storage) (!@ count))",
        ])
    lines.extend(["  in", "  fetch ()"])
    return "\n".join(lines)


def _emit_regular(ctx: Context, command: Command) -> str:
    output = _trailing_output(ctx, command)
    hidden = {output.name} if output else set()
    args, by_param = _make_args(ctx, command, hidden)
    name = naming.command_name(command.name)
    destructor = _is_void(command) and any(a.param.name == "pAllocator" for a in args) and output is None
    lines = [_function_head(command, args, name, destructor=destructor)]
    for arg in args:
        lines.extend(arg.prep or [])

    output_value = None
    overrides: dict[str, str] = {}
    if output:
        allocation, call_value, output_value = _output_allocation(ctx, output)
        lines.extend(allocation)
        overrides[output.name] = call_value
    call = _call(command, by_param, overrides)
    if _is_result(command):
        lines.append(f"  let result = {call} in")
        lines.extend(_result_tail(command, output_value,
                                  create_instance=command.name == "vkCreateInstance"))
    elif _is_void(command):
        if output_value:
            lines.extend([f"  {call};", f"  {output_value}"])
        else:
            lines.append(f"  {call}")
    else:
        lines.append(f"  {call}")
    return "\n".join(lines)


def emit(ctx: Context, out: Path, chunks: list[str]) -> None:
    opens = ["open Ctypes", "open Vk_enums", "open Vk_handles", *[f"open {chunk}" for chunk in chunks]]
    sections = ["\n".join(opens)]
    for command in ctx.registry.commands.values():
        pair = _enumeration(command)
        sections.append(_emit_enumeration(ctx, command, pair) if pair else _emit_regular(ctx, command))
    write_generated(out / "vk_api.ml", "\n\n".join(sections) + "\n")
