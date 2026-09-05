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
  memory & lifetime incl. `Bigarray` mapping, commands incl. error handling
  and the two array-output-command gotchas below, extensions & function
  loading, an explicitly-untested `tsdl`/SDL2 interop sketch, a threading
  note, the 64-bit integer caveat, and the regeneration workflow), plus a
  consolidated "Known generator issues" section.
- `README.md` rewritten against the real generated API: an accurate feature
  list with real counts (see below), corrected install instructions, a
  60-line quick start, an examples table, and a "Status and limitations"
  section.
- `.gitignore`: ignore `*.ppm` (`triangle_offscreen`'s output).

### Known issues (as of this entry)

Found and worked around (in the three new examples) while writing the
above; not fixed here since `gen/`/`lib/generated/` belong to a different
part of this project. Full detail, exact symptoms and workarounds are in
[`docs/GUIDE.md`'s "Known generator issues"](docs/GUIDE.md#known-generator-issues-as-of-this-writing).

- `Vk.DescriptorSetLayoutBinding.make` has no `~descriptor_count` argument
  (always derived from `~immutable_samplers`'s length, so it's `0` for
  almost every real binding).
- `Vk.WriteDescriptorSet.make`'s `descriptorCount` is always derived from
  `~texel_buffer_view`'s length, never `~image_info`/`~buffer_info`'s.
- `Vk.SubpassDescription.make`'s `colorAttachmentCount` is always derived
  from `~resolve_attachments`'s length, never `~color_attachments`'s —
  breaks any render pass without MSAA resolve attachments.
- The same "two array members share one `len=` count, only one of them
  actually drives it" shape also affects (at least) `VkPresentInfoKHR`,
  `VkSubmitInfo`, `VkIndirectCommandsLayoutNV`, `VkSemaphoreWaitInfo`,
  `VkWin32KeyedMutexAcquireReleaseInfoKHR`/`NV` and a few more; none of
  these happened to be tripped by this repository's examples.
- `Vk.create_graphics_pipelines`/`Vk.create_compute_pipelines`/
  `Vk.allocate_descriptor_sets`/`Vk.allocate_command_buffers` require the
  caller to pre-allocate the output handle array (`Ctypes.allocate_n`)
  rather than returning it as a list.
- As of this entry, `test/test_compute.ml`, `test/test_graphics.ml` and
  `test/test_structs.ml` (owned by another part of this project, not
  touched here) do not compile; the first two fail on exactly the first
  two generator issues above, independently confirming them.
- `DESIGN.md` §3's "ergonomic labels drop the p/pp/pfn prefix" rule doesn't
  hold for `DebugUtilsMessengerCreateInfoEXT.make` (`~pfn_user_callback`/
  `~p_user_data` keep it), and §8's claim that `PfnDebugUtilsMessengerCallbackEXT.opt`
  passes `~runtime_lock:true` to `Foreign.funptr_opt` doesn't match the
  generated code (no `~runtime_lock` argument is passed at all).
- Pre-existing, not found by this work but re-confirmed while writing
  `README.md`: `dune-project` declares `(license MIT)` while the committed
  `LICENSE` file is GPLv3.

## Initial project skeleton

Predates this changelog; see `git log` for the commit-by-commit history
(registry vendoring, generator, hand-written runtime, tests, shaders, CI,
and the first README/DESIGN drafts).
