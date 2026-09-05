"""Emit Vulkan structures, unions, callbacks, and layout metadata."""
from __future__ import annotations

from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable

from .emit_common import Context, write_generated
from . import naming
from .registry import Composite, FuncPointer, Member


@dataclass(frozen=True)
class PhysicalField:
    members: tuple[Member, ...]
    binding: str
    c_name: str

    @property
    def bitfield(self) -> bool:
        return self.members[0].bitfield is not None


def _storage_bits(ctype: str) -> int:
    if "64" in ctype:
        return 64
    if "16" in ctype:
        return 16
    if "8" in ctype:
        return 8
    return 32


def physical_fields(comp: Composite) -> list[PhysicalField]:
    fields: list[PhysicalField] = []
    i = 0
    while i < len(comp.members):
        member = comp.members[i]
        if member.bitfield is None:
            fields.append(PhysicalField((member,), naming.member_name(member.name), member.name))
            i += 1
            continue
        width = _storage_bits(member.ctype)
        group: list[Member] = []
        used = 0
        while i < len(comp.members):
            current = comp.members[i]
            if current.bitfield is None or current.ctype != member.ctype or used + current.bitfield > width:
                break
            group.append(current)
            used += current.bitfield
            i += 1
            if used == width:
                break
        fields.append(PhysicalField(tuple(group), naming.member_name(group[0].name) + "_bits", group[0].name))
    return fields


def _funcpointer(ctx: Context, fp: FuncPointer) -> str:
    module = naming.module_name(fp.name)
    arg_types = [ctx.value_type(p, owner=fp.name, strings=True) for p in fp.params]
    result_type = ctx.value_type(fp.result, owner=fp.name, strings=True)
    if not arg_types:
        fn_type = f"unit -> {result_type}"
        signature = f"void @-> returning ({ctx.foreign_typ(fp.result, owner=fp.name, strings=True)})"
    else:
        fn_type = " -> ".join(arg_types + [result_type])
        signature = " @-> ".join(
            [ctx.foreign_typ(p, owner=fp.name, strings=True) for p in fp.params]
            + [f"returning ({ctx.foreign_typ(fp.result, owner=fp.name, strings=True)})"]
        )
    return f"""module {module} = struct
  type fn = {fn_type}
  let signature = {signature}
  let t : fn typ = Foreign.funptr signature
  let opt : fn option typ = Foreign.funptr_opt signature
end"""


def _structure_type(ctx: Context, comp: Composite) -> str | None:
    member = next((m for m in comp.members if m.name == "sType" and m.values), None)
    if member is None:
        return None
    value = member.values.split(",")[0]
    structure_values = ctx.registry.enums.get("VkStructureType")
    if structure_values is None or value not in {item.name for item in structure_values.values}:
        return None
    return f"StructureType.{naming.enum_value_name('VkStructureType', value, ctx.registry.tags)}"


def _pair_maps(comp: Composite) -> tuple[dict[str, Member], dict[str, str], dict[str, str]]:
    by_name = {m.name: m for m in comp.members}
    pointer_for_count: dict[str, Member] = {}
    count_for_pointer: dict[str, str] = {}
    special: dict[str, str] = {}
    for member in comp.members:
        if not member.length:
            continue
        first = member.length.split(",")[0].strip()
        if first in by_name and by_name[first].pointer_depth == 0:
            if member.const and member.ctype != "void" and (member.pointer_depth == 1 or (member.ctype == "char" and member.pointer_depth == 2)):
                pointer_for_count[first] = member
                count_for_pointer[member.name] = first
        compact = member.length.replace(" ", "")
        if member.ctype == "uint32_t" and member.pointer_depth == 1 and "codeSize/4" in compact:
            special[member.name] = "codeSize"
        elif member.ctype == "void" and member.pointer_depth == 1 and first in by_name:
            special[member.name] = first
    return pointer_for_count, count_for_pointer, special


def _default(ctx: Context, member: Member) -> str | None:
    kind = ctx.kind(member.ctype)
    if member.arrays:
        return '""' if member.ctype == "char" else "[]"
    if member.pointer_depth:
        return None
    if kind in {"int", "uint32", "uint64", "int32", "external_enum"}:
        return "0"
    if kind == "float":
        return "0."
    if kind == "bool":
        return "false"
    if kind in {"enum", "flags"}:
        return f"{ctx.enum_module(member.ctype)}.of_int 0"
    if kind == "handle":
        return f"{naming.module_name(member.ctype)}.null"
    return None


def _constructor_arguments(ctx: Context, comp: Composite) -> tuple[list[str], dict[str, str]]:
    pointer_for_count, count_for_pointer, special = _pair_maps(comp)
    args: list[str] = []
    bindings: dict[str, str] = {}
    used: set[str] = set()

    def unique(label: str) -> str:
        original = label
        n = 2
        while label in used:
            label = f"{original}_{n}"
            n += 1
        used.add(label)
        return label

    if any(m.name == "pNext" for m in comp.members):
        args.append("?next:arg_next")
        bindings["pNext"] = "arg_next"
    if comp.returnedonly:
        return args, bindings

    for member in comp.members:
        if member.name in {"sType", "pNext"}:
            continue
        if member.name in pointer_for_count or member.name in special.values():
            continue
        if member.bitfield is not None:
            label = unique(naming.argument_name(member.name))
            binding = "arg_" + label
            args.append(f"?{label}:({binding}=0)")
            bindings[member.name] = binding
            continue
        pointer_like = member.pointer_depth > 0 or ctx.kind(member.ctype) == "pointer"
        label = naming.argument_name(member.name, 1 if pointer_like else 0)
        if pointer_like and not member.const and member.name not in count_for_pointer and member.name not in special:
            label = naming.member_name(member.name)
        label = unique(label)
        binding = "arg_" + label
        bindings[member.name] = binding
        if member.name in count_for_pointer:
            args.append(f"?{label}:({binding}=[])")
        elif member.name in special:
            args.append(f"?{label}:({binding}=\"\")")
        elif member.ctype == "char" and member.pointer_depth == 1 and member.const:
            args.append(f"?{label}:{binding}")
        elif pointer_like:
            args.append(f"?{label}:{binding}")
        elif ctx.kind(member.ctype) == "funcpointer":
            args.append(f"?{label}:{binding}")
        else:
            default = _default(ctx, member)
            args.append(f"?{label}:{binding}" if default is None else f"?{label}:({binding}={default})")
    return args, bindings


def _array_setter(ctx: Context, member: Member, binding: str, field_binding: str) -> list[str]:
    dims = [ctx.array_size(x) for x in member.arrays]
    total = 1
    for dim in dims:
        total *= dim
    lines = [f"  if List.length {binding} > {total} then invalid_arg \"{member.name}: too many elements\";"]
    lines.append(f"  let destination = getf value {field_binding} in")
    access = "destination"
    # Every dimension except the last selects a nested carray.
    stride = total
    indexes: list[str] = []
    for dim in dims[:-1]:
        stride //= dim
        indexes.append(f"(i / {stride}) mod {dim}")
    last_index = f"i mod {dims[-1]}"
    for index in indexes:
        access = f"CArray.get ({access}) ({index})"
    lines.append(f"  List.iteri (fun i x -> CArray.set ({access}) ({last_index}) x) {binding};")
    return lines


def _pointee_typ(ctx: Context, member: Member, owner: str) -> str:
    if member.pointer_depth < 1:
        raise ValueError(f"{owner}.{member.name} is not a pointer")
    pointee = replace(member, pointer_depth=member.pointer_depth - 1, arrays=())
    return ctx.foreign_typ(pointee, owner=owner)


def _null_pointer(ctx: Context, member: Member, owner: str) -> str:
    return f"Vk_base.null_ptr ({_pointee_typ(ctx, member, owner)})"


def _constructor(ctx: Context, comp: Composite, fields: list[PhysicalField]) -> str:
    args, bindings = _constructor_arguments(ctx, comp)
    head = "let make " + (" ".join(args) + " " if args else "") + "() ="
    lines = [f"  {head}", "  let value, keep = Vk_base.make_kept t in", "  ignore keep;"]
    structure_type = _structure_type(ctx, comp)
    pointer_for_count, count_for_pointer, special = _pair_maps(comp)
    by_name = {m.name: m for m in comp.members}

    for field in fields:
        if field.bitfield:
            if comp.returnedonly:
                continue
            offset = 0
            pieces = []
            for member in field.members:
                binding = bindings[member.name]
                mask = (1 << (member.bitfield or 0)) - 1
                piece = f"({binding} land {mask})"
                if offset:
                    piece = f"({piece} lsl {offset})"
                pieces.append(piece)
                offset += member.bitfield or 0
            lines.append(f"  setf value _{field.binding} ({' lor '.join(pieces)});")
            continue

        member = field.members[0]
        f = "_" + field.binding
        if member.name == "sType":
            if structure_type:
                lines.append(f"  setf value {f} {structure_type};")
            else:
                lines.append(f"  setf value {f} (StructureType.of_int 0);")
            continue
        if member.name == "pNext":
            next_binding = bindings["pNext"]
            pointee = _pointee_typ(ctx, member, comp.name)
            lines.extend([
                f"  (match {next_binding} with",
                f"   | None -> setf value {f} ({_null_pointer(ctx, member, comp.name)})",
                f"   | Some chain -> setf value {f} (from_voidp ({pointee}) (Vk_base.next_pointer chain)); Vk_base.retain keep chain);",
            ])
            continue
        if comp.returnedonly:
            continue
        if member.name in pointer_for_count:
            pointer = pointer_for_count[member.name]
            binding = bindings[pointer.name]
            lines.append(f"  setf value {f} (List.length {binding});")
            continue
        if member.name in special.values():
            pointer_name = next(name for name, count in special.items() if count == member.name)
            binding = bindings[pointer_name]
            lines.append(f"  setf value {f} (String.length {binding});")
            continue
        if member.name in count_for_pointer:
            binding = bindings[member.name]
            elem_typ = ctx.base_typ(member.ctype, owner=comp.name)
            if member.ctype == "char" and member.pointer_depth == 2:
                lines.extend([
                    f"  if {binding} = [] then setf value {f} ({_null_pointer(ctx, member, comp.name)}) else begin",
                    f"    let strings, pointers = Vk_base.carray_of_strings {binding} in",
                    f"    setf value {f} (CArray.start pointers);",
                    "    Vk_base.retain keep strings; Vk_base.retain keep pointers",
                    "  end;",
                ])
            else:
                lines.extend([
                    f"  if {binding} = [] then setf value {f} ({_null_pointer(ctx, member, comp.name)}) else begin",
                    f"    let items = CArray.of_list ({elem_typ}) {binding} in",
                    f"    setf value {f} (CArray.start items);",
                    f"    Vk_base.retain keep items; Vk_base.retain keep {binding}",
                    "  end;",
                ])
            continue
        if member.name in special:
            binding = bindings[member.name]
            if member.ctype == "uint32_t":
                lines.extend([
                    f"  if {binding} = \"\" then setf value {f} ({_null_pointer(ctx, member, comp.name)}) else begin",
                    f"    let words = Vk_base.uint32_carray_of_bytes {binding} in",
                    f"    setf value {f} (CArray.start words); Vk_base.retain keep words",
                    "  end;",
                ])
            else:
                lines.extend([
                    f"  if {binding} = \"\" then setf value {f} ({_null_pointer(ctx, member, comp.name)}) else begin",
                    f"    let bytes = CArray.of_string {binding} in",
                    f"    setf value {f} (to_voidp (CArray.start bytes)); Vk_base.retain keep bytes",
                    "  end;",
                ])
            continue

        binding = bindings.get(member.name)
        if binding is None:
            continue
        kind = ctx.kind(member.ctype)
        if member.arrays:
            if member.ctype == "char":
                size = ctx.array_size(member.arrays[0])
                lines.extend([
                    f"  if String.length {binding} >= {size} then invalid_arg \"{member.name}: string too long\";",
                    f"  let destination = getf value {f} in",
                    f"  String.iteri (fun i c -> CArray.set destination i c) {binding};",
                ])
            else:
                lines.extend(_array_setter(ctx, member, binding, f))
        elif kind == "funcpointer" and member.pointer_depth == 0:
            lines.extend([
                f"  (match {binding} with",
                f"   | None -> setf value {f} None",
                f"   | Some callback -> setf value {f} (Some callback); Vk_base.retain keep callback);",
            ])
        elif member.pointer_depth or kind == "pointer":
            if kind == "pointer" and member.pointer_depth == 0:
                lines.append(f"  setf value {f} (match {binding} with None -> Ctypes.null | Some p -> p);")
            elif member.ctype == "char" and member.const and member.pointer_depth == 1:
                lines.extend([
                    f"  (match {binding} with",
                    f"   | None -> setf value {f} ({_null_pointer(ctx, member, comp.name)})",
                    "   | Some text -> let text = CArray.of_string text in",
                    f"       setf value {f} (CArray.start text); Vk_base.retain keep text);",
                ])
            elif kind in {"struct", "union"} and member.const and member.pointer_depth == 1:
                lines.extend([
                    f"  (match {binding} with",
                    f"   | None -> setf value {f} ({_null_pointer(ctx, member, comp.name)})",
                    f"   | Some pointed -> setf value {f} (addr pointed); Vk_base.retain keep pointed);",
                ])
            else:
                lines.append(f"  setf value {f} (match {binding} with None -> {_null_pointer(ctx, member, comp.name)} | Some p -> p);")
        elif kind in {"struct", "union"}:
            lines.append(f"  (match {binding} with None -> () | Some x -> setf value {f} x);")
        else:
            lines.append(f"  setf value {f} {binding};")
    lines.append("  value")
    return "\n".join(lines)


def _union_constructor(ctx: Context, comp: Composite, field: PhysicalField) -> str:
    if field.bitfield:
        return ""
    member = field.members[0]
    name = naming.member_name(member.name)
    internal_field = "_" + field.binding
    if member.arrays:
        lines = [f"  let {name} values =", "    let value = make t in"]
        setter = _array_setter(ctx, member, "values", internal_field)
        lines.extend("  " + line for line in setter)
        lines.append("    value")
        return "\n".join(lines)
    return f"  let {name} x = let value = make t in setf value {internal_field} x; value"


def _composite(ctx: Context, comp: Composite) -> str:
    if comp.alias:
        return f"module {naming.module_name(comp.name)} = {naming.module_name(ctx.canonical_composite(comp.name))}"
    module = naming.module_name(comp.name)
    ctor = "structure" if comp.kind == "struct" else "union"
    fields = physical_fields(comp)
    lines = [f"module {module} = struct", "  type t", f"  let t : t {ctor} typ = {ctor} \"{comp.name}\""]
    for field in fields:
        member = field.members[0]
        if field.bitfield:
            bits = _storage_bits(member.ctype)
            typ = {8: "Vk_base.uint8", 16: "Vk_base.uint16", 32: "Vk_base.uint32", 64: "Vk_base.uint64"}[bits]
        else:
            typ = ctx.foreign_typ(member, owner=comp.name)
        lines.append(f"  let _{field.binding} = field t \"{field.c_name}\" ({typ})")
        lines.append(f"  let {field.binding} = _{field.binding}")
    lines.append("  let () = seal t")
    if comp.kind == "struct":
        structure_type = _structure_type(ctx, comp)
        lines.append(f"  let structure_type = {'Some ' + structure_type if structure_type else 'None'}")
        constructor = _constructor(ctx, comp, fields)
        lines.extend("  " + line if line else line for line in constructor.splitlines())
        for field in fields:
            member = field.members[0]
            if member.arrays and member.ctype == "char":
                lines.append(f"  let get_{naming.member_name(member.name)} value = Vk_base.string_of_char_array (getf value {field.binding})")
    else:
        for field in fields:
            constructor = _union_constructor(ctx, comp, field)
            if constructor:
                lines.append(constructor)
    lines.append("end")
    return "\n".join(lines)


def emit(ctx: Context, out: Path, *, chunk_size: int = 120) -> list[str]:
    # Remove stale chunks before writing deterministic output.
    for old in out.glob("vk_types_*.ml"):
        old.unlink()
    chunks = [ctx.order[i:i + chunk_size] for i in range(0, len(ctx.order), chunk_size)]
    chunk_names: list[str] = []
    for index, names in enumerate(chunks, 1):
        chunk_name = f"Vk_types_{index:02d}"
        chunk_names.append(chunk_name)
        prelude = ["open Ctypes", "open Vk_base", "open Vk_enums", "open Vk_handles"]
        prelude.extend(f"open {previous}" for previous in chunk_names[:-1])
        sections = ["\n".join(prelude)]
        for name in names:
            if name in ctx.registry.funcpointers:
                sections.append(_funcpointer(ctx, ctx.registry.funcpointers[name]))
            else:
                sections.append(_composite(ctx, ctx.registry.composites[name]))
        write_generated(out / f"vk_types_{index:02d}.ml", "\n\n".join(sections) + "\n")

    _emit_layout(ctx, out, chunk_names)
    return chunk_names


def _emit_layout(ctx: Context, out: Path, chunks: list[str]) -> None:
    lines = ["open Ctypes", *[f"open {chunk}" for chunk in chunks], "", "let all = ["]
    for name, comp in sorted(ctx.registry.composites.items()):
        module = naming.module_name(name)
        target = comp if not comp.alias else ctx.registry.composites[ctx.canonical_composite(name)]
        fields = physical_fields(target)
        lines.append(f"  (\"{name}\", sizeof {module}.t, [")
        for field in fields:
            for member in field.members:
                offset = "0" if target.kind == "union" else f"offsetof {module}._{field.binding}"
                lines.append(f"    (\"{member.name}\", {offset});")
        lines.append("  ]);")
    lines.append("]")
    write_generated(out / "vk_layout.ml", "\n".join(lines) + "\n")
