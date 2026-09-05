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
    # Extra local temporaries (besides `binding` itself) introduced by `prep`
    # that must also stay reachable past the raw call -- see
    # `_keep_alive_exprs` (P0-2, DESIGN.md §9/§10).
    keep_extra: list[str] | None = None


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


def _output_list_by_count(command: Command) -> tuple[Member, Member] | None:
    """An output array whose `len` is a plain (by value) input count that also
    sizes an input array -- vkCreateGraphicsPipelines/vkCreateComputePipelines/
    vkCreateRayTracingPipelines{KHR,NV} (`pPipelines` len=`createInfoCount`,
    the same count that sizes `pCreateInfos`) and similar batch-create
    commands. Unlike `_enumeration` the count is not an in/out pointer, so
    there is no query call: the output array is exactly as long as the input
    array(s) sharing its count."""
    by_name = {p.name: p for p in command.params}
    input_pointer_for_count, _ = _input_pairs(command)
    for p in command.params:
        if p.const or p.pointer_depth != 1 or not p.length:
            continue
        count_name = p.length.split(",")[0].strip()
        count = by_name.get(count_name)
        if (
            count and count.pointer_depth == 0 and not count.const and count.ctype == "uint32_t"
            and count_name in input_pointer_for_count
        ):
            return count, p
    return None


def _output_list_by_struct_field(ctx: Context, command: Command) -> tuple[Member, Member, str] | None:
    """An output array whose `len` is `<param>-><field>`: vkAllocateCommandBuffers
    (`pCommandBuffers` len=`pAllocateInfo->commandBufferCount`) and
    vkAllocateDescriptorSets (`pDescriptorSets` len=`pAllocateInfo->descriptorSetCount`).
    The count lives inside a single const input struct rather than being its
    own parameter."""
    by_name = {p.name: p for p in command.params}
    for p in command.params:
        if p.const or p.pointer_depth != 1 or not p.length:
            continue
        length = p.length.split(",")[0].strip()
        if "->" not in length:
            continue
        struct_name, field_name = length.split("->", 1)
        info = by_name.get(struct_name)
        if info and info.const and info.pointer_depth == 1 and ctx.kind(info.ctype) == "struct":
            return info, p, field_name
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
                # `strings_{label}` (the per-string CArrays) and `array_{label}`
                # (the pointer-to-each-string array) are fresh allocations that
                # only `pointer_{label}` (a raw ptr with no back-reference) is
                # derived from; ctypes' `ignore` above is not a keep-alive.
                keep_extra = [f"strings_{label}", f"array_{label}"]
            else:
                prep = [
                    f"  let array_{label} = CArray.of_list ({elem_typ}) {binding} in",
                    f"  let pointer_{label} = if {binding} = [] then {_null(ctx, p)} else CArray.start array_{label} in",
                ]
                keep_extra = [f"array_{label}"]
            arg = Arg(p, label, binding, binding, f"pointer_{label}", prep=prep, keep_extra=keep_extra)
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


def _keep_alive_stmt(args: list[Arg]) -> str | None:
    """P0-2 (DESIGN.md §9/§10): after the raw `Vk_fn.*` call returns, every
    argument the wrapper built -- the original OCaml value the caller passed
    in *and* any temporary CArray/pointer-list `_make_args` derived from it
    -- must still be reachable, or OCaml's precise GC is free to treat it as
    dead as soon as its last syntactic use (typically the `CArray.of_list`/
    `addr`/`CArray.start` call that copied out of it) has passed, which can
    be *before* the C call it was built for has actually run or returned:

    * List-of-struct arguments (`queue_submit`'s `submits`, `create_graphics_
      pipelines`'s `infos`, ...) are copied element-by-element into a fresh
      CArray (`CArray.of_list`); the copy is a raw byte-copy of each struct's
      fields, including any pointer fields (pCommandBuffers, pNext, ...) --
      it does not, and cannot, extend the lifetime of the heap allocations
      those pointers reference, which are otherwise only protected by the
      *original* structure's own keep-alive list/finaliser (`Vk_base.
      make_kept`). If the original list argument (and, for a list of
      strings, the per-string CArrays `Vk_base.carray_of_strings` builds)
      becomes unreachable and is collected before/during the call, the copy
      the C function actually reads is left holding dangling pointers.
    * A single struct passed as `addr arg` is, by inspection of ctypes'
      `Ctypes_memory`/`Ctypes_ffi` (`Ctypes.addr` returns the structure's own
      `Fat.t`, and `Ctypes_ffi.write_arg`/`invoke`'s `Call` case already
      keeps every marshalled argument value reachable via `Ctypes_memory_
      stubs.use_value` until *after* the underlying C call returns) already
      protected by ctypes itself for the duration of the call. Retaining it
      here too is redundant but cheap, uniform, and does not depend on that
      ctypes internal remaining true across versions -- DESIGN.md §9/§10
      says to err on the side of keeping everything alive past the call.

    `ignore (Sys.opaque_identity (...))` is the standard way to defeat the
    compiler's liveness analysis and force a value to stay reachable up to
    that specific program point (a single-element tuple `(x)` is just `x`,
    so this reads naturally whether there is one argument or several).
    """
    exprs: list[str] = []
    for arg in args:
        if arg.binding:
            exprs.append(arg.binding)
        exprs.extend(arg.keep_extra or [])
    if not exprs:
        return None
    return f"  ignore (Sys.opaque_identity ({', '.join(exprs)}));"


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
    keep_alive = _keep_alive_stmt(args)
    if keep_alive:
        lines.extend(["  in", "  let enumeration_result = fetch () in", keep_alive, "  enumeration_result"])
    else:
        lines.extend(["  in", "  fetch ()"])
    return "\n".join(lines)


def _emit_output_list(ctx: Context, command: Command, output: Member, count_expr_of) -> str:
    """Shared body for `_output_list_by_count`/`_output_list_by_struct_field`
    matches: allocate a `CArray` sized by `count_expr_of by_param`, call the
    raw command with it in place of the hidden output pointer, and return the
    handles as a list (DESIGN.md §10). `check` still runs first so a negative
    VkResult raises `Error`; when the command has extra success codes (e.g.
    VK_PIPELINE_COMPILE_REQUIRED_EXT) the result is kept alongside the list."""
    hidden = {output.name}
    args, by_param = _make_args(ctx, command, hidden)
    name = naming.command_name(command.name)
    lines = [_function_head(command, args, name)]
    for arg in args:
        lines.extend(arg.prep or [])
    elem_typ = ctx.base_typ(output.ctype)
    lines.append(f"  let output_count = {count_expr_of(by_param)} in")
    lines.append(f"  let storage = CArray.make ({elem_typ}) output_count in")
    call = _call(command, by_param, {output.name: "CArray.start storage"})
    lines.append(f"  let result = {call} in")
    keep_alive = _keep_alive_stmt(args)
    if keep_alive:
        lines.append(keep_alive)
    lines.extend(_result_tail(command, "(CArray.to_list storage)"))
    return "\n".join(lines)


def _emit_output_list_count(ctx: Context, command: Command, count: Member, output: Member) -> str:
    return _emit_output_list(ctx, command, output, lambda by_param: by_param[count.name].call)


def _emit_output_list_struct_field(
    ctx: Context, command: Command, info: Member, output: Member, field_name: str
) -> str:
    info_module = naming.module_name(ctx.canonical_composite(info.ctype))
    field_ocaml = naming.member_name(field_name)

    def count_expr(by_param: dict[str, Arg]) -> str:
        return f"Ctypes.getf {by_param[info.name].binding} {info_module}.{field_ocaml}"

    return _emit_output_list(ctx, command, output, count_expr)


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
    keep_alive = _keep_alive_stmt(args)
    if _is_result(command):
        lines.append(f"  let result = {call} in")
        if keep_alive:
            lines.append(keep_alive)
        lines.extend(_result_tail(command, output_value,
                                  create_instance=command.name == "vkCreateInstance"))
    elif _is_void(command):
        lines.append(f"  {call};")
        if keep_alive:
            lines.append(keep_alive)
        lines.append(f"  {output_value}" if output_value else "  ()")
    else:
        lines.append(f"  let call_result = {call} in")
        if keep_alive:
            lines.append(keep_alive)
        lines.append("  call_result")
    return "\n".join(lines)


def emit(ctx: Context, out: Path, chunks: list[str]) -> None:
    opens = ["open Ctypes", "open Vk_enums", "open Vk_handles", *[f"open {chunk}" for chunk in chunks]]
    sections = ["\n".join(opens)]
    for command in ctx.registry.commands.values():
        pair = _enumeration(command)
        if pair:
            sections.append(_emit_enumeration(ctx, command, pair))
            continue
        # The two output-array shapes below only make sense for the ordinary
        # "returns a VkResult" idiom (every known instance in the registry is
        # one); anything else safely falls through to `_emit_regular`, which
        # never omits a command (DESIGN.md §10).
        if _is_result(command):
            count_pair = _output_list_by_count(command)
            if count_pair:
                sections.append(_emit_output_list_count(ctx, command, *count_pair))
                continue
            struct_field = _output_list_by_struct_field(ctx, command)
            if struct_field:
                sections.append(_emit_output_list_struct_field(ctx, command, *struct_field))
                continue
        sections.append(_emit_regular(ctx, command))
    write_generated(out / "vk_api.ml", "\n\n".join(sections) + "\n")
