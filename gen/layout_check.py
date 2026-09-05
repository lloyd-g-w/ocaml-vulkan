#!/usr/bin/env python3
"""Emit a C11 program that prints sizeof/offsetof for every Vulkan struct and
union that is actually declared by <vulkan/vulkan.h> when:

  * VK_ENABLE_BETA_EXTENSIONS is defined before the include (provisional
    extensions), and
  * no VK_USE_PLATFORM_* macro is defined (headless build, no window system
    headers available).

The printed program is meant to be compiled with the *real* Vulkan-Headers
(gcc -Wall) so that its stdout becomes the golden layout file compared
against the generated `Vk.Layout.all` in test/test_layout.ml (see DESIGN.md
sections 7 and 12). This script never computes sizes itself: the C compiler
is the ground truth, we only decide *which* struct/union names and members
are safe to reference for a given registry + macro combination.

Output format (deterministic, one program per invocation):

    VkSomeStruct <sizeof>
      memberName <offsetof>
      otherMember <offsetof>
    VkOtherStruct <sizeof>
      ...

Struct/union entries are sorted by name. Members are kept in registry
(declaration) order. Bitfield members are skipped (offsetof is undefined for
bitfields) but the struct/union header line is always printed.

Usage:
    python3 gen/layout_check.py --registry registry/vk.xml --out /tmp/layout_check.c
    python3 gen/layout_check.py --registry registry/vk.xml \
        --exclude-type VkSomeStruct --exclude-member VkOther.someField

--exclude-type/--exclude-member let scripts/gen_layout.sh route around a
struct or member that the pinned headers turn out not to declare (registry
and installed Vulkan-Headers version drift) without failing the whole
build; see scripts/gen_layout.sh for the compile-detect-retry loop that
supplies them automatically.
"""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional, Set, Tuple

# Macros the generated probe program defines. We intentionally never define
# any VK_USE_PLATFORM_* macro: this box is headless (no X11/Wayland/Win32/...
# headers installed), so window-system-specific structs must stay excluded.
DEFINED_MACROS = {"VK_ENABLE_BETA_EXTENSIONS"}

# A bitfield member's <name> tail looks like ":24" (e.g. `<name>mask</name>:8`).
_BITFIELD_TAIL_RE = re.compile(r"^\s*:\s*\d+")


class StructInfo:
    __slots__ = ("name", "category", "members")

    def __init__(self, name: str, category: str) -> None:
        self.name = name
        self.category = category  # "struct" | "union"
        # (member_name, is_bitfield), in registry declaration order.
        self.members: List[Tuple[str, bool]] = []


def _api_tokens(value: Optional[str]) -> Set[str]:
    """Split a comma-separated `api`/`supported` attribute into tokens."""
    if not value:
        return set()
    return {tok.strip() for tok in value.split(",") if tok.strip()}


def parse_registry(registry_path: str) -> Tuple[Dict[str, StructInfo], List[str]]:
    """Parse vk.xml and return (structs_by_name, sorted_declared_names).

    `structs_by_name` covers every non-alias struct/union type in the
    registry. `sorted_declared_names` is the subset that is reachable from a
    <feature>/<extension> that is (a) part of the "vulkan" API (not
    vulkansc-only, not disabled) and (b) not gated by a VK_USE_PLATFORM_*
    macro we don't define -- i.e. exactly what a TU that does
    `#define VK_ENABLE_BETA_EXTENSIONS` + `#include <vulkan/vulkan.h>` with no
    platform macros will actually declare.
    """
    root = ET.parse(registry_path).getroot()

    # platform name -> guarding macro, e.g. "xlib" -> "VK_USE_PLATFORM_XLIB_KHR",
    # "provisional" -> "VK_ENABLE_BETA_EXTENSIONS" (see vulkan.h: every
    # platform header, including vulkan_beta.h, is behind exactly one such
    # macro, so this table is all we need to decide what's declared).
    platform_protect: Dict[str, str] = {}
    for plat in root.findall("./platforms/platform"):
        name, protect = plat.get("name"), plat.get("protect")
        if name and protect:
            platform_protect[name] = protect

    structs: Dict[str, StructInfo] = {}
    aliases: Dict[str, str] = {}

    for ty in root.findall("./types/type"):
        if ty.get("category") not in ("struct", "union"):
            continue
        name = ty.get("name")
        if not name:
            continue
        alias = ty.get("alias")
        if alias:
            aliases[name] = alias
            continue
        info = StructInfo(name, ty.get("category"))
        for member in ty.findall("member"):
            m_api = _api_tokens(member.get("api"))
            if m_api and "vulkan" not in m_api:
                continue  # a vulkansc-only variant of this field
            name_elem = member.find("name")
            if name_elem is None or not (name_elem.text or "").strip():
                continue
            member_name = name_elem.text.strip()
            is_bitfield = bool(_BITFIELD_TAIL_RE.match(name_elem.tail or ""))
            info.members.append((member_name, is_bitfield))
        structs[name] = info

    def resolve_alias(name: str) -> str:
        seen: Set[str] = set()
        while name in aliases and name not in seen:
            seen.add(name)
            name = aliases[name]
        return name

    def declared_under_our_macros(platform_attr: Optional[str]) -> bool:
        if not platform_attr:
            return True
        protect = platform_protect.get(platform_attr)
        # Unknown platform name (registry addition we don't recognise): be
        # conservative and treat it as gated (excluded); the gen_layout.sh
        # retry loop will pull in anything we wrongly excluded only if the
        # headers actually declare it, which they won't for a real platform.
        return protect in DEFINED_MACROS

    required: Set[str] = set()

    def collect(container: ET.Element, platform_attr: Optional[str]) -> None:
        if not declared_under_our_macros(platform_attr):
            return
        for req in container.findall("require"):
            # A handful of <require> blocks (inside otherwise-"vulkan"
            # extensions) carry their own api="vulkansc" restricting just
            # that block to Vulkan SC, e.g. VK_KHR_performance_query's
            # VkPerformanceQueryReservationInfoKHR. Honour it the same way
            # as the top-level api/supported filters above.
            req_api = _api_tokens(req.get("api"))
            if req_api and "vulkan" not in req_api:
                continue
            for ty in req.findall("type"):
                tname = ty.get("name")
                if not tname:
                    continue
                resolved = resolve_alias(tname)
                if resolved in structs:
                    required.add(resolved)

    for feat in root.findall("./feature"):
        if "vulkan" not in _api_tokens(feat.get("api")):
            continue  # vulkansc-only feature (VKSC_VERSION_1_0)
        collect(feat, feat.get("platform"))

    for ext in root.findall("./extensions/extension"):
        if "vulkan" not in _api_tokens(ext.get("supported")):
            continue  # supported="disabled" or supported="vulkansc"
        collect(ext, ext.get("platform"))

    return structs, sorted(required)


def emit_c(
    structs: Dict[str, StructInfo],
    names: List[str],
    exclude_types: Set[str],
    exclude_members: Set[Tuple[str, str]],
) -> str:
    lines = [
        "/* Generated by gen/layout_check.py from registry/vk.xml -- do not edit.",
        " * Prints `Name sizeof` then `  member offsetof` for every struct/union",
        " * declared under VK_ENABLE_BETA_EXTENSIONS with no VK_USE_PLATFORM_*",
        " * macro defined. See scripts/gen_layout.sh and DESIGN.md sections 7/12. */",
        "#define VK_ENABLE_BETA_EXTENSIONS",
        "#include <vulkan/vulkan.h>",
        "#include <stddef.h>",
        "#include <stdio.h>",
        "",
        "int main(void) {",
    ]
    for name in names:
        if name in exclude_types:
            continue
        info = structs[name]
        lines.append(f'    printf("{name} %zu\\n", sizeof({name}));')
        for member_name, is_bitfield in info.members:
            if is_bitfield or (name, member_name) in exclude_members:
                continue
            lines.append(
                f'    printf("  {member_name} %zu\\n", offsetof({name}, {member_name}));'
            )
    lines.append("    return 0;")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def parse_member_exclusion(spec: str) -> Tuple[str, str]:
    if "." not in spec:
        raise argparse.ArgumentTypeError(
            f"--exclude-member expects 'VkStruct.member', got {spec!r}"
        )
    struct_name, member_name = spec.split(".", 1)
    return struct_name, member_name


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--registry", default="registry/vk.xml", help="path to vk.xml"
    )
    parser.add_argument(
        "--out", default="-", help="output C file path ('-' for stdout, the default)"
    )
    parser.add_argument(
        "--exclude-type",
        action="append",
        default=[],
        metavar="VkName",
        help="skip this struct/union entirely (repeatable)",
    )
    parser.add_argument(
        "--exclude-member",
        action="append",
        default=[],
        metavar="VkName.member",
        help="skip a single member line (repeatable)",
    )
    args = parser.parse_args(argv)

    structs, names = parse_registry(args.registry)

    exclude_types = set(args.exclude_type)
    unknown_excludes = exclude_types - set(structs)
    if unknown_excludes:
        print(
            "gen/layout_check.py: warning: --exclude-type for unknown struct(s): "
            + ", ".join(sorted(unknown_excludes)),
            file=sys.stderr,
        )
    exclude_members = {parse_member_exclusion(s) for s in args.exclude_member}

    source = emit_c(structs, names, exclude_types, exclude_members)

    if args.out == "-":
        sys.stdout.write(source)
    else:
        with open(args.out, "w") as f:
            f.write(source)

    kept = sum(1 for n in names if n not in exclude_types)
    print(
        f"gen/layout_check.py: {kept} struct/union entries "
        f"({len(names) - kept} excluded) -> {args.out}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
