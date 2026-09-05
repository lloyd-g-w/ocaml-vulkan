"""OCaml naming rules for Vulkan identifiers."""
from __future__ import annotations

import re
from collections.abc import Iterable

# Keywords plus pervasive syntax words that are awkward as generated labels.
OCAML_KEYWORDS = {
    "and", "as", "assert", "asr", "begin", "class", "constraint", "do",
    "done", "downto", "else", "end", "exception", "external", "false",
    "for", "fun", "function", "functor", "if", "in", "include", "inherit",
    "initializer", "land", "lazy", "let", "lor", "lsl", "lsr", "lxor",
    "match", "method", "mod", "module", "mutable", "new", "nonrec",
    "object", "of", "open", "or", "private", "rec", "sig", "struct",
    "then", "to", "true", "try", "type", "val", "virtual", "when",
    "while", "with",
}

_TOKEN_RE = re.compile(
    r"[A-Z]+(?=[A-Z][a-z]|[0-9]|$)|[A-Z]?[a-z]+|[0-9]+D(?=$|[A-Z])|[0-9]+"
)


def words(name: str) -> list[str]:
    """Split CamelCase while keeping Vulkan digit forms such as 2D together."""
    name = name.replace("-", "_")
    out: list[str] = []
    for part in name.split("_"):
        if not part:
            continue
        tokens = _TOKEN_RE.findall(part)
        out.extend(tokens or [part])
    return out


def escape(identifier: str) -> str:
    if not identifier:
        identifier = "value"
    identifier = re.sub(r"[^a-zA-Z0-9_]", "_", identifier)
    if identifier[0].isdigit():
        identifier = "_" + identifier
    if identifier in OCAML_KEYWORDS:
        identifier += "_"
    return identifier


def snake(name: str) -> str:
    return escape("_".join(w.lower() for w in words(name)))


def module_name(c_name: str) -> str:
    if c_name.startswith("PFN_vk"):
        return "Pfn" + c_name[len("PFN_vk"):]
    if c_name.startswith("PFN_"):
        return "Pfn" + c_name[len("PFN_"):]
    if c_name.startswith("Vk"):
        return c_name[2:]
    # External names only appear in diagnostics, but keep this total.
    return "".join(w[:1].upper() + w[1:] for w in words(c_name))


def command_name(c_name: str) -> str:
    return snake(c_name[2:] if c_name.startswith("vk") else c_name)


def member_name(c_name: str) -> str:
    # Vulkan uses these spellings as scalar/array member names, not as a
    # trailing numeric generation marker (ClearColorValue.float32, etc.).
    if re.fullmatch(r"(?:u?int|float)\d+", c_name):
        return escape(c_name.lower())
    return snake(c_name)


def argument_name(c_name: str, pointer_depth: int = 0) -> str:
    """Ergonomic labels drop p/pp/pfn Hungarian pointer prefixes."""
    value = c_name
    if pointer_depth:
        if value.startswith("pfn") and len(value) > 3 and value[3].isupper():
            value = value[3:]
        elif value.startswith("pp") and len(value) > 2 and value[2].isupper():
            value = value[2:]
        elif value.startswith("p") and len(value) > 1 and value[1].isupper():
            value = value[1:]
    return member_name(value)


def _strip_vendor_suffix(type_body: str, tags: Iterable[str]) -> str:
    for tag in sorted(tags, key=len, reverse=True):
        if type_body.endswith(tag):
            return type_body[:-len(tag)]
    return type_body


def enum_prefix(type_name: str, tags: Iterable[str]) -> str:
    body = type_name[2:] if type_name.startswith("Vk") else type_name
    body = _strip_vendor_suffix(body, tags)
    # FlagBits2 and Flags2 put the width-generation digit before the value
    # name: VkAccessFlagBits2 -> VK_ACCESS_2_*.
    match = re.fullmatch(r"(.*?)(?:FlagBits|Flags)(\d*)", body)
    if match:
        body = match.group(1) + match.group(2)
    return "VK_" + "_".join(w.upper() for w in words(body)) + "_"


def enum_value_name(type_name: str, c_value: str, tags: Iterable[str]) -> str:
    value = c_value
    prefix = enum_prefix(type_name, tags)
    if value.startswith(prefix):
        value = value[len(prefix):]
    else:
        value = value.removeprefix("VK_")
        # Registry naming has a few historical exceptions.  Strip the longest
        # common token prefix rather than hard-coding each one.
        type_tokens = prefix.removeprefix("VK_").strip("_").split("_")
        value_tokens = value.split("_")
        i = 0
        while i < min(len(type_tokens), len(value_tokens)) and type_tokens[i] == value_tokens[i]:
            i += 1
        if i:
            value = "_".join(value_tokens[i:])
    tokens = [x for x in value.split("_") if x and x != "BIT"]
    return escape("_".join(x.lower() for x in tokens))


def constant_name(c_name: str) -> str:
    return escape(c_name.removeprefix("VK_").lower())


def extension_name(c_name: str) -> str:
    return escape(c_name.removeprefix("VK_").lower())


def flag_module_name(flags_type: str) -> str:
    """The public module is always named after the Flags typedef."""
    return module_name(flags_type)
