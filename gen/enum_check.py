#!/usr/bin/env python3
"""Emit a C11 program that prints `NAME <value>` for every enum constant and
bitmask bit that <vulkan/vulkan.h> actually declares when:

  * VK_ENABLE_BETA_EXTENSIONS is defined before the include (provisional
    extensions), and
  * no VK_USE_PLATFORM_* macro is defined (headless build, no window system
    headers available).

This is the enum-value sibling of gen/layout_check.py (same rationale: the
real C compiler is the ground truth for what a plain `#include
<vulkan/vulkan.h>` actually makes visible, so the golden file it produces is
compared against the generated `Vk.Enum_values.all` in test/test_enum_values.ml
-- see DESIGN.md sections 5, 10 and 12). Unlike layout_check.py this script
never needs to compute a value itself: every name it prints is a plain C
identifier (an enumerator or a `#define`d extension/feature addition), so we
let the compiler evaluate `(long long)NAME` and report the true value --
we only decide *which* names are safe to reference for a given registry +
macro combination:

  * A name added to an *existing* enum by a <feature>/<extension> via
    `<enum extends=... offset=.../>` (or `bitpos=`/`value=`/`alias=`) is
    always emitted, as long as the owning <feature>/<extension> is part of
    the "vulkan" api and not disabled -- Vulkan-Headers puts these plain
    integer constants in vulkan_core.h unconditionally; only the
    struct/command declarations that need a real platform type (HWND,
    xcb_connection_t*, ...) move into a separate per-platform header.
  * A name that lives in a *standalone* `<enums name="X">` block (X's own
    "spec 1.0" values, not an extension addition) is only emitted when the
    enum/bitmask type X itself is reachable: required by a <feature>, or by
    an <extension> whose `platform` is unguarded (no `platform` attribute)
    or guarded by exactly the macro we define (VK_ENABLE_BETA_EXTENSIONS,
    i.e. `platform="provisional"`). This excludes the handful of enums that
    only exist behind a real platform macro we don't define, e.g.
    VkFullScreenExclusiveEXT (win32), VkExportMetalObjectTypeFlagBitsEXT
    (metal), VkImageConstraintsInfoFlagBitsFUCHSIA (fuchsia).

--exclude-value lets scripts/gen_enum_values.sh route around any further
mismatch between the pinned registry and the installed Vulkan-Headers
without failing the whole build, exactly like gen_layout.sh's
--exclude-type/--exclude-member; see that script for the compile-detect-retry
loop that supplies it automatically.

Usage:
    python3 gen/enum_check.py --registry registry/vk.xml --out /tmp/enum_check.c
    python3 gen/enum_check.py --registry registry/vk.xml --exclude-value VK_SOME_CONSTANT
"""
from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional, Set

# The probe program defines only this; we intentionally never define any
# VK_USE_PLATFORM_* macro (this box is headless).
DEFINED_MACROS = {"VK_ENABLE_BETA_EXTENSIONS"}


def _api_tokens(value: Optional[str]) -> Set[str]:
    if not value:
        return set()
    return {tok.strip() for tok in value.split(",") if tok.strip()}


def parse_registry(registry_path: str) -> List[str]:
    """Return the sorted list of constant names the real headers declare
    under our macro set (see the module docstring for the exact rule)."""
    root = ET.parse(registry_path).getroot()

    platform_protect: Dict[str, str] = {}
    for plat in root.findall("./platforms/platform"):
        name, protect = plat.get("name"), plat.get("protect")
        if name and protect:
            platform_protect[name] = protect

    def declared_under_our_macros(platform_attr: Optional[str]) -> bool:
        if not platform_attr:
            return True
        return platform_protect.get(platform_attr) in DEFINED_MACROS

    # Which category="enum"/"bitmask" *types* are reachable at all -- decides
    # whether a standalone <enums name=X> block's own values are declared.
    enum_type_names = {
        t.get("name")
        for t in root.findall("./types/type")
        if t.get("category") in ("enum", "bitmask") and t.get("name")
    }
    reachable_types: Set[str] = set()

    def note_types(container: ET.Element, platform_attr: Optional[str]) -> None:
        if not declared_under_our_macros(platform_attr):
            return
        for req in container.findall("require"):
            if not api_matches(req.get("api")):
                continue
            for ty in req.findall("type"):
                name = ty.get("name")
                if name:
                    reachable_types.add(name)

    for feat in root.findall("./feature"):
        if "vulkan" not in _api_tokens(feat.get("api")):
            continue
        note_types(feat, feat.get("platform"))
    for ext in root.findall("./extensions/extension"):
        if "vulkan" not in _api_tokens(ext.get("supported")):
            continue
        note_types(ext, ext.get("platform"))

    names: List[str] = []
    seen: Set[str] = set()

    def add(name: Optional[str]) -> None:
        if name and not name.endswith("_MAX_ENUM") and name not in seen:
            seen.add(name)
            names.append(name)

    # 1. Standalone <enums type="enum"|"bitmask"> blocks: a type's own base
    #    values (vk.xml keeps "spec 1.0" values here, not just extension
    #    additions -- e.g. VkResult, VkStructureType, VkImageLayout).
    for block in root.findall("./enums"):
        kind = block.get("type")
        block_name = block.get("name")
        if kind not in ("enum", "bitmask") or not block_name:
            continue
        if block_name in enum_type_names and block_name not in reachable_types:
            continue  # only reachable behind a platform macro we don't define
        for value_node in block.findall("enum"):
            if api_matches(value_node.get("api")):
                add(value_node.get("name"))

    # 2. <feature>/<extension> additions to an existing enum (`extends=`).
    def collect_added(container: ET.Element, platform_attr: Optional[str]) -> None:
        if not declared_under_our_macros(platform_attr):
            return
        for req in container.findall("require"):
            if not api_matches(req.get("api")):
                continue
            for value_node in req.findall("enum"):
                if not value_node.get("extends"):
                    continue  # e.g. *_SPEC_VERSION / *_EXTENSION_NAME, not a value
                if api_matches(value_node.get("api")):
                    add(value_node.get("name"))

    for feat in root.findall("./feature"):
        if "vulkan" not in _api_tokens(feat.get("api")):
            continue
        collect_added(feat, feat.get("platform"))
    for ext in root.findall("./extensions/extension"):
        if "vulkan" not in _api_tokens(ext.get("supported")):
            continue
        collect_added(ext, ext.get("platform"))

    return sorted(names)


def api_matches(value: Optional[str]) -> bool:
    if value is None:
        return True
    return "vulkan" in _api_tokens(value)


def emit_c(names: List[str], exclude: Set[str]) -> str:
    lines = [
        "/* Generated by gen/enum_check.py from registry/vk.xml -- do not edit.",
        " * Prints `NAME <value>` for every enum constant and bitmask bit",
        " * declared under VK_ENABLE_BETA_EXTENSIONS with no VK_USE_PLATFORM_*",
        " * macro defined. See scripts/gen_enum_values.sh and DESIGN.md",
        " * sections 5, 10, 12, 13. */",
        "#define VK_ENABLE_BETA_EXTENSIONS",
        "#include <vulkan/vulkan.h>",
        "#include <stdio.h>",
        "",
        "int main(void) {",
    ]
    for name in names:
        if name in exclude:
            continue
        # Every value is printed through a signed 64-bit cast: OCaml ints are
        # 63-bit and VkResult error codes are negative, so the comparison on
        # the OCaml side needs a signed representation wide enough for both
        # 64-bit flag bits and negative results (see test_enum_values.ml).
        lines.append(f'    printf("{name} %lld\\n", (long long)({name}));')
    lines.append("    return 0;")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", default="registry/vk.xml", help="path to vk.xml")
    parser.add_argument("--out", default="-", help="output C file path ('-' for stdout, the default)")
    parser.add_argument(
        "--exclude-value",
        action="append",
        default=[],
        metavar="VK_NAME",
        help="skip this constant entirely (repeatable)",
    )
    args = parser.parse_args(argv)

    names = parse_registry(args.registry)

    exclude = set(args.exclude_value)
    unknown = exclude - set(names)
    if unknown:
        print(
            "gen/enum_check.py: warning: --exclude-value for unknown constant(s): "
            + ", ".join(sorted(unknown)),
            file=sys.stderr,
        )

    source = emit_c(names, exclude)

    if args.out == "-":
        sys.stdout.write(source)
    else:
        with open(args.out, "w") as f:
            f.write(source)

    kept = sum(1 for n in names if n not in exclude)
    print(
        f"gen/enum_check.py: {kept} constants ({len(names) - kept} excluded) -> {args.out}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
