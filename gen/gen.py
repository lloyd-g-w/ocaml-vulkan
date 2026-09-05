#!/usr/bin/env python3
"""Generate OCaml ctypes bindings from the Vulkan XML registry."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

from vkgen.registry import Registry
from vkgen.emit_common import Context
from vkgen import emit_api, emit_consts, emit_enums, emit_fn, emit_handles, emit_types


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=Path("registry/vk.xml"),
                        help="path to Khronos vk.xml")
    parser.add_argument("--out", type=Path, default=Path("lib/generated"),
                        help="generated OCaml output directory")
    parser.add_argument("--chunk-size", type=int, default=120,
                        help="maximum composite/callback modules per type chunk")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.chunk_size < 1:
        raise SystemExit("--chunk-size must be positive")
    registry = Registry.parse(args.registry)
    context = Context.make(registry)
    args.out.mkdir(parents=True, exist_ok=True)
    emit_consts.emit(context, args.out)
    emit_enums.emit(context, args.out)
    emit_handles.emit(context, args.out)
    chunks = emit_types.emit(context, args.out, chunk_size=args.chunk_size)
    emit_fn.emit(context, args.out, chunks)
    emit_api.emit(context, args.out, chunks)
    print(
        f"generated {len(registry.commands)} commands, "
        f"{len(registry.composites)} composites, and {len(chunks)} type chunks"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, KeyError) as error:
        print(f"vkgen: error: {error}", file=sys.stderr)
        raise SystemExit(1)
