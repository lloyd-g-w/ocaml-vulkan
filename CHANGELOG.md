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

### Fixed — independent-review findings (P0 keep-alive bugs, P1 registry/callback/loader, P2 docs)

An independent review of the generator and hand-written runtime found two
P0 GC-safety bugs, a P1 registry-reachability bug, callback-lifetime and
loader-documentation gaps, and three doc-precision items. All are fixed in
this entry, each with a regression test where the finding called for one:

- **P0 (`gen/vkgen/emit_types.py`):** a struct/union member embedded **by
  value** (e.g. `ComputePipelineCreateInfo.make ~stage:(PipelineShaderStageCreateInfo.make ...)`)
  was byte-copied into the parent but never retained, so the embedded
  value's own allocations (its `pName`, `pNext` chain, arrays) could be
  collected while the parent struct was still live and pointing at them.
  Fixed by retaining the embedded value in the parent's `keep` list, same as
  the existing pointer-to-struct branch. Regression: `test_gc_safety.ml`'s
  by-value-embedding test.
- **P0 (`gen/vkgen/emit_api.py`):** every ergonomic wrapper taking a `T
  list` (`Vk.queue_submit`, `Vk.create_graphics_pipelines`,
  `Vk.update_descriptor_sets`, `Vk.cmd_pipeline_barrier`, ~75 element types
  in total) copied the caller's structures into a temporary `CArray` for the
  raw call but never kept the *original* list (or its per-element `keep`
  lists, protecting things like `pCommandBuffers`) reachable past that copy
  — OCaml's precise GC could free them between the copy and the raw call
  finishing, or during the call if a reentrant callback (e.g. a debug
  messenger) triggered a GC. Fixed by keeping every wrapper argument (and
  any temporary array/pointer derived from it) reachable past the raw call
  with `ignore (Sys.opaque_identity (...))`, applied uniformly to all ~839
  generated wrapper functions (including the single-struct `addr arg` case,
  which turns out to already be protected by ctypes' own call machinery —
  kept anyway, cheaply, per "never omit"). Regression: `test_gc_safety.ml`'s
  `Vk.queue_submit` test (instance + device + real lavapipe submission, 20
  iterations under `Gc.full_major` + heap-spraying pressure with a debug
  messenger active).
- **P1 (`gen/vkgen/registry.py`):** composites/handles/enums/bitmasks/
  funcpointers/commands reachable only from `vulkansc`-only features or
  `disabled` extensions were still fully generated (only their *enum
  values* were correctly excluded), so 41 such structs — plus a further 13
  reachable only from a *provisional* extension, whose values were
  separately, unconditionally skipped — silently got `sType =
  StructureType.of_int 0` (`VK_STRUCTURE_TYPE_APPLICATION_INFO`) instead of
  an error. Fixed with a real reachability computation (roots from
  `<require>` blocks of enabled features/extensions, transitively closed
  over member/param types, mirroring what `gen/layout_check.py`/
  `gen/enum_check.py`'s real-headers probes already did) plus a fail-loud
  check in `Context.validate_types`. **Decision:** provisional extensions
  (`VK_KHR_portability_subset`, the AMDX/NV ones) are now included fully —
  see `DESIGN.md` §1/§13. `Vk.Enum_values.all` now matches **100%** of the
  golden `test/enum_values/x86_64-linux-gnu.txt` (4486/4486, up from
  4455/4589 before this fix); `Vk.Layout.all` is unaffected in size of
  overlap (struct *layout* was never wrong, only `sType` *values*) but 41
  vulkansc/disabled structs are no longer generated at all. Regression:
  `test_layout.ml`'s new `Vk.Layout.structure_types` check.
- **P1 (`gen/vkgen/emit_types.py`, `lib/vk_base.ml`):** a `PFN_*` struct
  member's OCaml closure was only retained by its (often short-lived)
  create-info struct, while the Vulkan object built from it (a debug
  messenger, say) and the driver's raw pointer to its C trampoline outlive
  that struct. Fixed with `Vk_base.retain_forever`, a process-wide list that
  is never cleared (documented, deliberate, negligible leak). Regression:
  `test_gc_safety.ml`'s debug-messenger-callback test.
- **P1 (`DESIGN.md` §8, `docs/GUIDE.md`):** `DESIGN.md` claimed
  `Foreign.funptr_opt ~runtime_lock:true`; the code (correctly, since no
  `Vk.Fn.*` call ever releases the runtime lock) has always used the
  default `~runtime_lock:false`. Fixed the design text to match the code
  and spell out the resulting limitation precisely: a callback is only safe
  when invoked synchronously on the calling thread.
- **P1 (`DESIGN.md` §9, `docs/GUIDE.md`, `lib/vk_base.ml`):** documented
  that `Vk_fn`'s dispatch tables are process-global (volk style) —
  `Vk.create_instance` rebinds every instance-/device-level command to the
  newest instance, so a multi-instance app must call
  `Vk.Loader.load_instance` before using a different instance's objects —
  and added a small re-entrant mutex around `Vk_base.Loader`'s `load`/
  `ensure` and hook invocations (cheap; guards against two OCaml 5 domains
  tearing the shared dispatch table, not against the semantic
  multi-instance hazard itself, which is an application-level concern).
- **P2 (`DESIGN.md` §4, `docs/GUIDE.md`, `lib/vk_base.ml`):** precised the
  `uint64` view's documented limitation: it is a genuine **collision** above
  `2^63` (e.g. `2^63-1` and `2^64-1` both read back as `-1`), not merely a
  sign/positivity quirk below it. No behaviour change.
- **P2 (`README.md`):** documented `ctypes-foreign`'s real build
  prerequisites (a C compiler, `libffi` headers, `pkg-config` —
  `apt install build-essential libffi-dev pkg-config` on Debian/Ubuntu) and
  the runtime requirement of `libffi` alongside `libvulkan`/an ICD.
- **P2 (`docs/GUIDE.md`):** added a "Push constants" section
  (`Ctypes.CArray.t` + `Ctypes.to_voidp (CArray.start arr)` + byte-size
  computation) and a note that two-call enumeration's struct elements are
  allocated with a plain `X.make ()`, so per-element `pNext` chaining isn't
  possible through the wrapper (use `Vk.Fn` directly for that).

## Initial project skeleton

Predates this changelog; see `git log` for the commit-by-commit history
(registry vendoring, generator, hand-written runtime, tests, shaders, CI,
and the first README/DESIGN drafts).
