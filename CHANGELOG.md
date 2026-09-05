# Changelog

All notable changes to this project are documented here. Not released to
opam yet, so there are no version numbers, only dates and areas of the
repository. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Added — documentation & examples

- `examples/compute.ml` — headless compute end to end: instance → device →
  a 1,048,576-element (2^20, "1M") `uint32` storage buffer → descriptor set
  layout/pool/set → compute pipeline running `shaders/double.comp` →
  `vkCmdDispatch` → fence wait → read back and verify every element was
  doubled → print timing. `dune exec examples/compute.exe`.
- `examples/triangle_offscreen.ml` — headless graphics end to end: instance
  → device → a 512×512 `R8G8B8A8_UNORM` image → render pass + graphics
  pipeline (fixed viewport/scissor, `shaders/triangle.{vert,frag}`) → draw
  → transition to `TRANSFER_SRC` → copy to a host buffer → write
  `triangle.ppm` (binary PPM, P6), checking the centre pixel is non-black
  and the corner pixel matches the (pure black) clear colour.
  `dune exec examples/triangle_offscreen.exe`.
- `examples/debug_utils.ml` — `VK_EXT_debug_utils` with an OCaml
  `PfnDebugUtilsMessengerCallbackEXT` callback, both `pNext`-chained onto
  instance creation and as a standalone messenger (proven to actually fire,
  with no validation layer installed on this machine, by calling
  `vkSubmitDebugUtilsMessageEXT` directly), plus `pNext`-chaining
  `VkPhysicalDeviceFeatures2` with a chained `VkPhysicalDeviceVulkan12Features`.
  `dune exec examples/debug_utils.exe`.
- `docs/GUIDE.md` — a practical, section-by-section guide to the generated
  API (loading/versions, handles, enums/flags, structs/unions/bitfields,
  memory & lifetime incl. `Bigarray` mapping, commands incl. error handling,
  extensions & function loading, an explicitly-untested `tsdl`/SDL2 interop
  sketch, a threading note, the 64-bit integer caveat, the regeneration
  workflow, and the struct-layout/enum-value golden checks).
- `README.md` rewritten against the real generated API: an accurate feature
  list with real counts (see below), corrected install instructions, a
  60-line quick start, an examples table, and a "Status and limitations"
  section.
- `.gitignore`: ignore `*.ppm` (`triangle_offscreen`'s output).

### Fixed — generator, tests, examples & docs reconciled

Every generator issue listed in this file's previous "Known issues" entry
is now fixed (`gen/vkgen/emit_types.py`, `gen/vkgen/emit_api.py`), and the
examples/docs/README have been reconciled with the fixed API:

- Struct `make` constructors derive a shared count (`descriptorCount`,
  `colorAttachmentCount`, `swapchainCount`, ...) from the *longest* of the
  array arguments that share it, instead of silently picking whichever one
  happened to be recorded last (`Invalid_argument` if two disagree on a
  non-zero length). Where every array sharing a count is independently
  optional (e.g. `VkDescriptorSetLayoutBinding.pImmutableSamplers`), `make`
  also accepts the count directly as a plain `?xxx_count:int`
  (`Vk.DescriptorSetLayoutBinding.make ~descriptor_count:1 ...`).
- `Vk.create_graphics_pipelines`/`Vk.create_compute_pipelines` now return
  `Result.t * Pipeline.t list`; `Vk.allocate_command_buffers` returns
  `CommandBuffer.t list`; `Vk.allocate_descriptor_sets` returns
  `DescriptorSet.t list` — no more caller-allocated output pointers.
- `test/test_compute.ml`, `test/test_graphics.ml` and `test/test_structs.ml`
  compile and pass again; `test/layout/*.txt` is now actually mounted into
  the `runtest` sandbox, so `test_layout.ml` compares instead of silently
  skipping. `dune build @runtest` is green: **1360** struct/union layouts
  and **4455** enum/bitmask constants verified against the real C headers
  (0 mismatches on both), plus the enum/flag round-trip, struct/keep-alive,
  instance, compute and offscreen-graphics suites (`DESIGN.md` §12; see
  [`docs/GUIDE.md`'s "Golden checks"](docs/GUIDE.md#golden-checks-struct-layout-and-enum-values)).
- `dune-project`'s `(license ...)` field now reads `GPL-3.0-only`, matching
  the committed `LICENSE` file (previously `MIT`) — the mismatch flagged in
  this file's previous entry is resolved.
- `examples/compute.ml`/`examples/triangle_offscreen.ml`: every
  `WORKAROUND`/`Ctypes.allocate_n` block removed in favour of the fixed API
  used directly; `examples/debug_utils.ml`, `docs/GUIDE.md` and `README.md`
  reconciled with the fixed API (stale "known generator issues" prose
  removed; snippets re-checked against `lib/generated/`).

One genuine, non-blocking discrepancy remains (not a generator bug, just a
naming/threading detail — see
[`docs/GUIDE.md`](docs/GUIDE.md#extensions-and-function-loading)):
`DebugUtilsMessengerCreateInfoEXT.make`'s callback/user-data arguments keep
the `~pfn_`/`~p_` prefix instead of the prefix-stripped form `DESIGN.md` §3
describes as the general rule, and its `Foreign.funptr_opt` binding doesn't
pass `~runtime_lock:true` as `DESIGN.md` §8 describes.

## Initial project skeleton

Predates this changelog; see `git log` for the commit-by-commit history
(registry vendoring, generator, hand-written runtime, tests, shaders, CI,
and the first README/DESIGN drafts).
