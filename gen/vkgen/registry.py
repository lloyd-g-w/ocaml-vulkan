"""Parser for the Khronos Vulkan XML registry.

The emitter deliberately consumes a small, typed model rather than reaching back
into ElementTree.  Keeping all of the slightly odd vk.xml spelling rules here
also makes the generator straightforward to test and update.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import ast
import re
import xml.etree.ElementTree as ET
from typing import Iterable


def api_matches(value: str | None) -> bool:
    """Whether an api/supported attribute includes ordinary Vulkan."""
    if value is None:
        return True
    return "vulkan" in {x.strip() for x in value.split(",")}


def _name(node: ET.Element) -> str | None:
    return node.get("name") or node.findtext("name")


def declaration(node: ET.Element) -> str:
    """Return normalized C declaration text, including mixed XML content."""
    return " ".join("".join(node.itertext()).split())


@dataclass(frozen=True)
class Member:
    name: str
    ctype: str
    pointer_depth: int = 0
    const: bool = False
    arrays: tuple[str, ...] = ()
    bitfield: int | None = None
    length: str | None = None
    altlen: str | None = None
    optional: tuple[bool, ...] = ()
    values: str | None = None
    selector: str | None = None
    selection: str | None = None
    declaration: str = ""


@dataclass(frozen=True)
class BaseType:
    name: str
    target: str | None
    declaration: str


@dataclass(frozen=True)
class Bitmask:
    name: str
    base: str
    bits: str | None
    alias: str | None = None


@dataclass(frozen=True)
class Handle:
    name: str
    parent: tuple[str, ...]
    dispatchable: bool
    alias: str | None = None


@dataclass(frozen=True)
class EnumValue:
    name: str
    value: int | float | str | None = None
    alias: str | None = None
    bitpos: int | None = None
    source: str | None = None


@dataclass
class Enum:
    name: str
    kind: str
    bitwidth: int
    values: list[EnumValue] = field(default_factory=list)
    alias: str | None = None


@dataclass(frozen=True)
class Composite:
    name: str
    kind: str
    members: tuple[Member, ...] = ()
    alias: str | None = None
    returnedonly: bool = False
    structextends: tuple[str, ...] = ()


@dataclass(frozen=True)
class FuncPointer:
    name: str
    result: Member
    params: tuple[Member, ...]


@dataclass(frozen=True)
class Command:
    name: str
    result: Member | None = None
    params: tuple[Member, ...] = ()
    successcodes: tuple[str, ...] = ()
    errorcodes: tuple[str, ...] = ()
    alias: str | None = None
    level: str = "global"


@dataclass(frozen=True)
class Extension:
    name: str
    number: int
    spec_version_name: str | None
    spec_version: int | None
    extension_name_name: str | None
    extension_name: str | None


@dataclass
class Registry:
    platforms: dict[str, str]
    tags: tuple[str, ...]
    basetypes: dict[str, BaseType]
    defines: dict[str, str]
    bitmasks: dict[str, Bitmask]
    handles: dict[str, Handle]
    enums: dict[str, Enum]
    composites: dict[str, Composite]
    funcpointers: dict[str, FuncPointer]
    commands: dict[str, Command]
    constants: dict[str, int | float | str]
    extensions: dict[str, Extension]

    @classmethod
    def parse(cls, path: str | Path) -> "Registry":
        root = ET.parse(path).getroot()
        platforms = {
            p.get("name", ""): p.get("protect", "")
            for p in root.findall("./platforms/platform")
        }
        tags = tuple(t.get("name", "") for t in root.findall("./tags/tag"))

        basetypes: dict[str, BaseType] = {}
        defines: dict[str, str] = {}
        bitmasks: dict[str, Bitmask] = {}
        handles: dict[str, Handle] = {}
        composites: dict[str, Composite] = {}
        funcpointers: dict[str, FuncPointer] = {}
        enum_aliases: list[tuple[str, str]] = []

        for node in root.findall("./types/type"):
            if not api_matches(node.get("api")):
                continue
            category = node.get("category")
            name = _name(node)
            if category == "funcpointer" and not name:
                name = node.findtext("proto/name")
            if not name:
                continue
            alias = node.get("alias")
            if category == "basetype":
                type_child = node.find("type")
                basetypes[name] = BaseType(
                    name, type_child.text.strip() if type_child is not None and type_child.text else None,
                    declaration(node),
                )
            elif category == "define":
                # Duplicate Vulkan/VulkanSC defines are filtered above.
                defines[name] = declaration(node)
            elif category == "bitmask":
                base = node.findtext("type") or "VkFlags"
                bitmasks[name] = Bitmask(name, base, node.get("bitvalues") or node.get("requires"), alias)
            elif category == "handle":
                dispatchable = "VK_DEFINE_HANDLE" in declaration(node)
                parents = tuple(x for x in (node.get("parent") or "").split(",") if x)
                handles[name] = Handle(name, parents, dispatchable, alias)
            elif category == "enum" and alias:
                enum_aliases.append((name, alias))
            elif category in {"struct", "union"}:
                members = tuple(
                    parse_member(m) for m in node.findall("member") if api_matches(m.get("api"))
                )
                composites[name] = Composite(
                    name=name,
                    kind=category,
                    members=members,
                    alias=alias,
                    returnedonly=node.get("returnedonly") == "true",
                    structextends=tuple(x for x in (node.get("structextends") or "").split(",") if x),
                )
            elif category == "funcpointer":
                proto = node.find("proto")
                if proto is None:
                    raise ValueError(f"funcpointer {name} has no prototype")
                result = parse_member(proto, result=True)
                funcpointers[name] = FuncPointer(name, result, tuple(parse_member(p) for p in node.findall("param")))

        # Alias nodes omit their declaration details; inherit the canonical
        # handle/bitmask ABI now that every target has been seen.
        for name, handle in list(handles.items()):
            if handle.alias and handle.alias in handles:
                target = handles[handle.alias]
                handles[name] = Handle(name, target.parent, target.dispatchable, handle.alias)
        for name, bitmask in list(bitmasks.items()):
            if bitmask.alias and bitmask.alias in bitmasks:
                target = bitmasks[bitmask.alias]
                bitmasks[name] = Bitmask(name, target.base, target.bits, bitmask.alias)

        enums: dict[str, Enum] = {}
        constants: dict[str, int | float | str] = {}
        for block in root.findall("./enums"):
            block_name = block.get("name")
            kind = block.get("type")
            if kind == "constants":
                for value_node in block.findall("enum"):
                    if not api_matches(value_node.get("api")):
                        continue
                    value_name = value_node.get("name")
                    if not value_name or value_node.get("alias"):
                        continue
                    raw = value_node.get("value")
                    if raw is not None:
                        constants[value_name] = parse_constant(raw)
                continue
            if kind not in {"enum", "bitmask"} or not block_name:
                continue
            enum = Enum(block_name, kind, int(block.get("bitwidth", "32")))
            for value_node in block.findall("enum"):
                if api_matches(value_node.get("api")):
                    v = parse_enum_value(value_node, source=block_name)
                    if v is not None:
                        enum.values.append(v)
            enums[block_name] = enum

        # Type aliases are represented as enum entries so naming/type resolution
        # has one source of truth.
        for name, target in enum_aliases:
            enums[name] = Enum(name, "alias", 32, alias=target)

        # Core features and extensions add values to existing enum blocks.
        for feature in root.findall("./feature"):
            if not api_matches(feature.get("api")):
                continue
            _add_required_enums(enums, feature.findall("require"), None, feature.get("name"))

        extensions: dict[str, Extension] = {}
        for ext in root.findall("./extensions/extension"):
            if not api_matches(ext.get("supported")) or ext.get("supported") == "disabled":
                continue
            # Provisional declarations remain parseable, but values and public
            # extension constants requiring VK_ENABLE_BETA_EXTENSIONS are not
            # part of the default Vulkan API promised by this package.
            if ext.get("provisional") == "true":
                continue
            ext_name = ext.get("name")
            if not ext_name:
                continue
            number = int(ext.get("number", "0"))
            _add_required_enums(enums, ext.findall("require"), number, ext_name)
            spec_name = None
            spec_value = None
            str_name = None
            str_value = None
            for req in ext.findall("require"):
                if not api_matches(req.get("api")):
                    continue
                for value_node in req.findall("enum"):
                    n = value_node.get("name", "")
                    raw = value_node.get("value")
                    if raw is None:
                        continue
                    if n.endswith("_SPEC_VERSION"):
                        parsed = parse_constant(raw)
                        if isinstance(parsed, int):
                            spec_name, spec_value = n, parsed
                    elif n.endswith("_EXTENSION_NAME"):
                        parsed = parse_constant(raw)
                        if isinstance(parsed, str):
                            str_name, str_value = n, parsed
            extensions[ext_name] = Extension(ext_name, number, spec_name, spec_value, str_name, str_value)

        # Dedupe enum names while retaining first declaration order.  Aliases
        # from later promoted extensions are still emitted as separate values.
        for enum in enums.values():
            seen: set[str] = set()
            enum.values = [v for v in enum.values if not (v.name in seen or seen.add(v.name))]

        commands_unclassified: dict[str, Command] = {}
        aliases: list[ET.Element] = []
        for node in root.findall("./commands/command"):
            if not api_matches(node.get("api")):
                continue
            if node.get("alias"):
                aliases.append(node)
                continue
            proto = node.find("proto")
            if proto is None:
                continue
            result = parse_member(proto, result=True)
            name = proto.findtext("name")
            if not name:
                continue
            commands_unclassified[name] = Command(
                name=name,
                result=result,
                params=tuple(parse_member(p) for p in node.findall("param") if api_matches(p.get("api"))),
                successcodes=_csv(node.get("successcodes")),
                errorcodes=_csv(node.get("errorcodes")),
            )
        for node in aliases:
            name = node.get("name")
            target = node.get("alias")
            if not name or not target or target not in commands_unclassified:
                continue
            base = commands_unclassified[target]
            commands_unclassified[name] = Command(
                name=name, result=base.result, params=base.params,
                successcodes=base.successcodes, errorcodes=base.errorcodes,
                alias=target,
            )

        commands = {
            name: Command(
                name=c.name, result=c.result, params=c.params,
                successcodes=c.successcodes, errorcodes=c.errorcodes,
                alias=c.alias, level=classify_command(c, handles),
            )
            for name, c in commands_unclassified.items()
        }

        return cls(
            platforms=platforms, tags=tags, basetypes=basetypes, defines=defines,
            bitmasks=bitmasks, handles=handles, enums=enums,
            composites=composites, funcpointers=funcpointers,
            commands=commands, constants=constants, extensions=extensions,
        )


def _csv(value: str | None) -> tuple[str, ...]:
    return tuple(x.strip() for x in (value or "").split(",") if x.strip())


def parse_member(node: ET.Element, *, result: bool = False) -> Member:
    type_node = node.find("type")
    name_node = node.find("name")
    if type_node is None or not (type_node.text or "").strip():
        raise ValueError(f"declaration has no C type: {declaration(node)!r}")
    ctype = (type_node.text or "").strip()
    name = (name_node.text or "").strip() if name_node is not None else "result"
    decl = declaration(node)

    # Stars before the identifier belong to this declarator.  This also deals
    # with spellings such as "char* const*".
    before_name = decl.rsplit(name, 1)[0] if name and name in decl else decl
    pointer_depth = before_name.count("*")
    const = bool(re.search(r"\bconst\b", before_name))

    arrays: list[str] = []
    if name_node is not None:
        suffix = name_node.tail or ""
        # Array dimensions can contain an <enum> element following <name>.
        for child in list(node):
            if child.tag == "enum" and child.text:
                suffix += child.text
            if child.tag == "enum" and child.tail:
                suffix += child.tail
        arrays = re.findall(r"\[\s*([^\]]+)\s*\]", suffix)
    bitfield = None
    match = re.search(r":\s*(\d+)", decl)
    if match:
        bitfield = int(match.group(1))

    optional_raw = _csv(node.get("optional"))
    optional = tuple(x == "true" for x in optional_raw)
    return Member(
        name=name,
        ctype=ctype,
        pointer_depth=pointer_depth,
        const=const,
        arrays=tuple(arrays),
        bitfield=bitfield,
        length=node.get("len"),
        altlen=node.get("altlen"),
        optional=optional,
        values=node.get("values"),
        selector=node.get("selector"),
        selection=node.get("selection"),
        declaration=decl,
    )


def parse_constant(raw: str) -> int | float | str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return ast.literal_eval(value)
    value = value.replace(" ", "")
    # All-bits constants are intentionally represented as negative OCaml ints.
    match = re.fullmatch(r"\(?~(\d+)U(?:LL)?(?:-(\d+))?\)?", value)
    if match:
        return ~int(match.group(1)) - int(match.group(2) or 0)
    if re.fullmatch(r"[+-]?(?:\d+\.\d*|\d*\.\d+)(?:[eE][+-]?\d+)?[fF]?", value):
        return float(value.rstrip("fF"))
    cleaned = re.sub(r"(?<=[0-9A-Fa-f])[uUlL]+$", "", value)
    try:
        return int(cleaned, 0)
    except ValueError as exc:
        raise ValueError(f"unsupported Vulkan constant expression: {raw!r}") from exc


def parse_enum_value(node: ET.Element, *, source: str | None = None,
                     extension_number: int | None = None) -> EnumValue | None:
    name = node.get("name")
    if not name or name.endswith("_MAX_ENUM"):
        return None
    alias = node.get("alias")
    if alias:
        return EnumValue(name, alias=alias, source=source)
    if node.get("bitpos") is not None:
        bitpos = int(node.get("bitpos", "0"))
        return EnumValue(name, value=1 << bitpos, bitpos=bitpos, source=source)
    if node.get("value") is not None:
        return EnumValue(name, value=parse_constant(node.get("value", "0")), source=source)
    if node.get("offset") is not None:
        extnumber = int(node.get("extnumber") or extension_number or "0")
        if not extnumber:
            raise ValueError(f"extension enum {name} has offset but no extension number")
        value = 1_000_000_000 + (extnumber - 1) * 1000 + int(node.get("offset", "0"))
        if node.get("dir") == "-":
            value = -value
        return EnumValue(name, value=value, source=source)
    return None


def _add_required_enums(enums: dict[str, Enum], requires: Iterable[ET.Element],
                        extension_number: int | None, source: str | None) -> None:
    for req in requires:
        if not api_matches(req.get("api")):
            continue
        for node in req.findall("enum"):
            if not api_matches(node.get("api")):
                continue
            target = node.get("extends")
            if not target:
                continue
            if target not in enums:
                # Disabled/SC-only enum blocks can still be mentioned by old
                # registry metadata; they are intentionally outside our model.
                continue
            value = parse_enum_value(node, source=source, extension_number=extension_number)
            if value is not None:
                enums[target].values.append(value)


def classify_command(command: Command, handles: dict[str, Handle]) -> str:
    if command.name in {"vkGetInstanceProcAddr", "vkGetDeviceProcAddr"}:
        return "global" if command.name == "vkGetInstanceProcAddr" else "instance"
    if not command.params:
        return "global"
    first = command.params[0].ctype
    if first not in handles:
        return "global"

    def has_device_parent(name: str, seen: set[str]) -> bool:
        if name == "VkDevice":
            return True
        if name in seen or name not in handles:
            return False
        seen.add(name)
        return any(has_device_parent(parent, seen) for parent in handles[name].parent)

    return "device" if has_device_parent(first, set()) else "instance"
