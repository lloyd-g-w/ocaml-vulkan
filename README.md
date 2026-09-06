# ocaml-vulkan

Generated OCaml bindings to the [Vulkan](https://www.vulkan.org/) graphics
and compute API, built on [`ctypes`](https://github.com/ocamllabs/ocaml-ctypes)
with **no C stubs and no Vulkan headers or SDK needed at build time**.
Everything — core 1.0 through 1.4 plus every extension in the Khronos
registry — is generated from the vendored `registry/vk.xml` by
`gen/gen.py` (Python 3, standard library only) and committed under
`lib/generated/`, so consuming this library only requires OCaml, `ctypes`
and `ctypes-foreign`. `libvulkan.so.1` (or the platform equivalent) is
loaded at runtime with `Dl.dlopen`; every entry point, including extension
commands, is resolved through `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr`
(volk-style), so nothing needs to be relinked when a new extension or
Vulkan version shows up.

> **This project was written entirely by AI.** Every file in this
> repository — the code generator, the runtime, the generated bindings, the
> tests, the examples, the CI workflows, the documentation and this notice —
> was produced by AI agents with no hand-written human code. See
> [Authorship](#authorship) for what that means before you depend on it.

`DESIGN.md` at the repository root is the binding contract between the
generator, the hand-written runtime, the tests and the examples — read it
if you're modifying any of those. This file is user-facing documentation,
checked against the actual generated code as of this writing; see
[`docs/GUIDE.md`](docs/GUIDE.md) for a much more detailed, example-driven
walkthrough of the API (including the struct-layout/enum-value golden
checks and a couple of naming notes this README doesn't get into).

## Status

Under active development; **not released to the public opam repository**.
The registry is pinned, the generator is functional, and the full API
surface below is generated and builds; `examples/vkinfo.ml`,
`examples/smoke.ml`, `examples/compute.ml`, `examples/triangle_offscreen.ml`
and `examples/debug_utils.ml` all run against a real Vulkan implementation
(Mesa's `lavapipe` software rasterizer, headless), and the alcotest suite
(`dune build @runtest`) is green, including golden struct-layout/enum-value
checks against the real C headers (see [Testing](#testing-lavapipe)). See
[Status and limitations](#status-and-limitations) below for the known
rough edges. Until a tagged release exists, use this repository via an
opam pin (below) rather than a version constraint.

## Feature list

Generated from `registry/vk.xml` (Vulkan-Headers tag `vulkan-sdk-1.4.357.0`,
see `registry/VERSION`), covering core Vulkan 1.0–1.4 and every extension in
the registry reachable from an enabled feature/extension, except the
`vulkansc` API and `supported="disabled"` extensions — **provisional
extensions are included fully** (`DESIGN.md` §1/§13). Counted directly from
the committed `lib/generated/` sources (`grep`; see the exact commands in
[Regeneration](#regeneration) below — these will drift if the registry is
ever upgraded without updating this paragraph):

| | count |
|---|---:|
| structs & unions | 1713 |
| commands (including deprecated/promoted aliases) | 841 |
| extensions | 471 |
| enum & flag types | 487 |
| handle types | 62 |
| generated OCaml, total | ~85,300 lines |

Both API layers described in [`docs/GUIDE.md`](docs/GUIDE.md) are generated:
a faithful **raw layer** (`Vk.Fn`, one function per Vulkan command with the
literal C signature) and an **ergonomic layer** (`Vk.*`: labelled struct
constructors, lists instead of count+pointer pairs, exceptions instead of
manually-checked `VkResult`, two-call enumerations collapsed into one call
returning a list).

## Install

Not on the public opam repository yet. Pin it directly from GitHub, or
from a local clone — both work today because `vulkan.opam` (normally
dune-generated from `dune-project`) is committed at the repository root
specifically so `opam pin` doesn't need an extra generation step first:

```sh
opam pin add vulkan git+https://github.com/lloyd-g-w/ocaml-vulkan.git
# or, from a local clone:
opam pin add vulkan .
```

Build-time dependencies are OCaml (>= 4.14; developed against 5.2.0),
`ctypes` (>= 0.20; developed against 0.24), `ctypes-foreign` (same) and
`integers` — no Vulkan SDK, no system Vulkan headers, and this package
itself generates no C stubs of its own. `alcotest` (tests) and `odoc`
(docs) are optional, opam-filtered (`--with-test` / `--with-doc`).

**`ctypes-foreign` itself needs a working native toolchain to build**,
independent of anything Vulkan-specific: a C compiler, `libffi`'s headers,
and `pkg-config` to find them (it links against `libffi` to implement
`Foreign.foreign`/`Foreign.funptr`). On Debian/Ubuntu:

```sh
sudo apt install build-essential libffi-dev pkg-config
```

(other distributions: whatever package provides `ffi.h`/`libffi.pc`, e.g.
`libffi-devel` on Fedora, plus a C compiler and `pkgconf`/`pkg-config`.) If
`opam install` fails while building `ctypes-foreign`/`conf-libffi`, this is
almost always the missing piece.

## Runtime requirements

- `libffi` itself (the shared library, not just the headers above) — the
  same one `ctypes-foreign` links against at build time; normally already
  present as a transitive dependency of the rest of the system, but called
  out here since it's easy to have the `-dev`/headers package at build time
  on a builder image and only the runtime package (or neither) on a
  deployment image.
- A Vulkan loader shared library on the dynamic linker path:
  `libvulkan.so.1` on Linux, `libvulkan.1.dylib` on macOS, `vulkan-1.dll` on
  Windows (`libvulkan1` on Debian/Ubuntu; `libvulkan-dev` also works and
  additionally provides the unversioned dev symlink). It's loaded lazily
  with `Dl.dlopen` the first time your program actually calls into Vulkan
  (see "Function loading" in [`docs/GUIDE.md`](docs/GUIDE.md#extensions-and-function-loading)),
  so it does not need to be present at build time.
- At least one installed Vulkan **ICD** (Installable Client Driver) that
  the loader can discover, normally via `/usr/share/vulkan/icd.d/*.json` or
  the `VK_ICD_FILENAMES` environment variable. For headless/CI use, Mesa's
  `lavapipe` (`llvmpipe`) software rasterizer works fully offscreen with no
  GPU — see [Testing](#testing-lavapipe) below; this is what every example
  in this repository is written and tested against.
- 64-bit platforms only (`x86_64`/`aarch64`; Linux is what's actually
  tested here, macOS/Windows should work but are untested — `DESIGN.md` §1).

## Quick start

Instance → device → buffer, end to end (adapted from
[`examples/smoke.ml`](examples/smoke.ml), which additionally maps and
writes the buffer's memory). Every function here is used, unmodified, in
one of the files under `examples/`.

```ocaml
let () =
  (* 1. instance *)
  let application =
    Vk.ApplicationInfo.make ~application_name:"quick-start" ~api_version:Vk.api_version_1_4 ()
  in
  let instance = Vk.create_instance (Vk.InstanceCreateInfo.make ~application_info:application ()) in

  (* 2. the first physical device, and a queue family that supports compute *)
  let physical_device = List.hd (Vk.enumerate_physical_devices instance) in
  let queue_family_index =
    Vk.get_physical_device_queue_family_properties physical_device
    |> List.mapi (fun i qf -> (i, qf))
    |> List.find_map (fun (i, qf) ->
           let flags = Ctypes.getf qf Vk.QueueFamilyProperties.queue_flags in
           if Vk.QueueFlags.mem flags Vk.QueueFlags.compute then Some i else None)
    |> Option.get
  in

  (* 3. device, with one queue from that family *)
  let device =
    Vk.create_device physical_device
      (Vk.DeviceCreateInfo.make
         ~queue_create_infos:
           [ Vk.DeviceQueueCreateInfo.make ~queue_family_index ~queue_priorities:[ 1.0 ] () ]
         ())
  in

  (* 4. a 4 KiB buffer, backed by host-visible + host-coherent memory *)
  let buffer =
    Vk.create_buffer device
      (Vk.BufferCreateInfo.make ~size:4096 ~usage:Vk.BufferUsageFlags.storage_buffer
         ~sharing_mode:Vk.SharingMode.exclusive ())
  in
  let requirements = Vk.get_buffer_memory_requirements device buffer in
  let memory_properties = Vk.get_physical_device_memory_properties physical_device in
  let type_bits = Ctypes.getf requirements Vk.MemoryRequirements.memory_type_bits in
  let types = Ctypes.getf memory_properties Vk.PhysicalDeviceMemoryProperties.memory_types in
  let rec memory_type_index i =
    let flags = Ctypes.getf (Ctypes.CArray.get types i) Vk.MemoryType.property_flags in
    if type_bits land (1 lsl i) <> 0
       && Vk.MemoryPropertyFlags.mem flags Vk.MemoryPropertyFlags.(host_visible lor host_coherent)
    then i
    else memory_type_index (i + 1)
  in
  let memory =
    Vk.allocate_memory device
      (Vk.MemoryAllocateInfo.make
         ~allocation_size:(Ctypes.getf requirements Vk.MemoryRequirements.size)
         ~memory_type_index:(memory_type_index 0) ())
  in
  Vk.bind_buffer_memory device buffer memory 0;
  Printf.printf "created a %d-byte buffer on %s\n"
    (Ctypes.getf requirements Vk.MemoryRequirements.size)
    (Vk.PhysicalDeviceProperties.get_device_name (Vk.get_physical_device_properties physical_device));

  (* 5. clean up (reverse creation order) *)
  Vk.free_memory device memory ();
  Vk.destroy_buffer device buffer ();
  Vk.destroy_device device ();
  Vk.destroy_instance instance ()
```

Don't `open Vk` in real code (some modules — `Format`, `Result`, `Buffer`,
`Queue`, `Semaphore`, `Event` — intentionally shadow Stdlib modules because
they follow Vulkan's own naming); qualify (`Vk.Format.r8g8b8a8_unorm`) or
bind a short local alias (`module V = Vk`) instead, as the files under
`test/` do.

## Examples

All five run headlessly against lavapipe (see [Testing](#testing-lavapipe)
for environment setup) and double as documentation:

| file | what it shows |
|---|---|
| [`examples/vkinfo.ml`](examples/vkinfo.ml) | instance/layer/extension/device enumeration and properties |
| [`examples/smoke.ml`](examples/smoke.ml) | instance → device → buffer → memory allocate/bind/map |
| [`examples/compute.ml`](examples/compute.ml) | a full headless compute dispatch: descriptor sets, a compute pipeline, `vkCmdDispatch` over a 1M-element buffer, verified and timed |
| [`examples/triangle_offscreen.ml`](examples/triangle_offscreen.ml) | a full offscreen graphics render pass: a triangle rendered into a 512×512 image and written out as `triangle.ppm` |
| [`examples/debug_utils.ml`](examples/debug_utils.ml) | `VK_EXT_debug_utils` with an OCaml callback, plus `pNext`-chaining `VkPhysicalDeviceFeatures2`/`VkPhysicalDeviceVulkan12Features` |

```sh
source /path/to/env-with-VULKAN_HEADERS-and-VK_ICD_FILENAMES.sh   # see Testing below
dune build -j 2
dune exec examples/vkinfo.exe
dune exec examples/compute.exe
dune exec examples/triangle_offscreen.exe && head -c 20 triangle.ppm | xxd | head -2
dune exec examples/debug_utils.exe
```

`docs/GUIDE.md` walks through the same ground in prose, with more, smaller
snippets, plus a section on the struct-layout/enum-value golden checks and
the one remaining naming quirk found while writing `compute.ml`/
`triangle_offscreen.ml`/`debug_utils.ml` (see
[Status and limitations](#status-and-limitations)).

## Testing (lavapipe)

All tests (`test/`, `alcotest`) and all examples are written against a
real Vulkan implementation — Mesa's `lavapipe` (`llvmpipe`) software
rasterizer — so no GPU is required, including in CI. The suite is green
(18 test cases across 8 suites, `DESIGN.md` §12):

| suite | what it checks |
|---|---|
| `test_enums.ml` | enum/flag `of_int`/`to_string` round trips, flag ops, `Result` printing |
| `test_layout.ml` | every generated struct's `sizeof`/member offsets against **1360** golden values compiled from the real C headers — 0 mismatches; plus: no struct with a resolved `structure_type` silently defaults its `sType` to 0 |
| `test_enum_values.ml` | every generated enum/bitmask constant against **4486** golden values compiled from the real C headers — 0 mismatches |
| `test_structs.ml` | `make` sets `sType`/counts/arrays correctly; keep-alive survives `Gc.full_major` |
| `test_instance.ml` | instance → physical device properties/queue families → device → buffer + memory → map |
| `test_compute.ml` | a compute pipeline doubles a 1024-element buffer end to end |
| `test_graphics.ml` | an offscreen render pass draws a triangle; read-back pixels are checked |
| `test_gc_safety.ml` | two independent-review P0 generator keep-alive bugs (a struct/union embedded by value; `Vk.queue_submit`'s `SubmitInfo.t list` argument) plus a P1 callback-lifetime bug, each regression-tested under `Gc.full_major` + heap-spraying pressure |

```sh
opam install . --deps-only --with-test
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json  # path varies by distro; see below
dune build -j 2 @runtest
```

If you don't already have a lavapipe ICD manifest installed, on
Debian/Ubuntu:

```sh
sudo apt-get install mesa-vulkan-drivers vulkan-tools   # vulkan-tools is optional, for vulkaninfo
find /usr/share/vulkan/icd.d -iname 'lvp_icd*.json'      # confirm the exact filename for your release
```

`test_layout.ml`/`test_enum_values.ml` additionally need golden files for
your platform under `test/layout/`/`test/enum_values/` (see
[Regeneration](#regeneration) below, and
[`docs/GUIDE.md`'s "Golden checks"](docs/GUIDE.md#golden-checks-struct-layout-and-enum-values)
for how they're produced); both are skipped with a message, not failed,
when the golden file for the current target isn't available.

### Windows layouts without Windows

`scripts/check_layout_win64.sh` (also a CI job) emits a C file of
`_Static_assert`s from `Vk.Layout.all` and compiles it with
`x86_64-w64-mingw32-gcc -fsyntax-only` against the real headers with
`VK_USE_PLATFORM_WIN32_KHR` defined, so the sizes and offsets this binding
assumes are proven for 64-bit Windows even though the test suite only runs
on Linux. It needs `gcc-mingw-w64-x86-64` and headers matching
`registry/VERSION` in `$VULKAN_HEADERS/include`.

## Regeneration

`lib/generated/` is **committed** (so consumers only need `ctypes`/
`ctypes-foreign`, not Python or the registry), but must always match
`registry/vk.xml` exactly. After changing the registry or the generator
itself, regenerate and commit the result in the same change:

```sh
./scripts/regen.sh                      # wraps: python3 gen/gen.py --registry registry/vk.xml --out lib/generated
git diff --stat lib/generated           # review, then commit
```

`python3 gen/gen.py` is deterministic (sorted iteration), depends on
nothing beyond the Python 3 standard library, and fails loudly on any
unrecognised C type rather than silently emitting `void*`. CI verifies
`scripts/regen.sh` leaves the tree clean, i.e. that nobody hand-edited a
generated file or forgot to regenerate after a registry/generator change.
(The [feature list](#feature-list) table above was produced by grepping the
committed output rather than by running the generator, so that gathering
these numbers never risks a stray write to `lib/generated/` — see the exact
`grep` invocations in this repository's change history if you want to
reproduce them yourself.)

The struct-layout and enum-value golden file(s) under `test/layout/` and
`test/enum_values/` are produced separately, from the real platform C
headers rather than the XML registry (so they can catch generator/registry
mistakes instead of just reproducing them — see
[`docs/GUIDE.md`'s "Golden checks"](docs/GUIDE.md#golden-checks-struct-layout-and-enum-values)):

```sh
source /path/to/env-with-VULKAN_HEADERS.sh   # needs $VULKAN_HEADERS/include/vulkan/vulkan.h
./scripts/gen_layout.sh                       # writes test/layout/<target-triple>.txt
./scripts/gen_enum_values.sh                  # writes test/enum_values/<target-triple>.txt
```

## Project layout

```
dune-project           (lang dune 3.x) package "vulkan"; vulkan.opam is committed (see Install)
DESIGN.md              the generator/runtime/tests/examples contract -- read this before changing code
registry/vk.xml        vendored Khronos registry (see registry/VERSION)
gen/gen.py             generator entry point (python3 gen/gen.py)
gen/vkgen/*.py         generator package (parse / naming / emit modules)
gen/layout_check.py    emits a C program printing sizeof/offsetof of all structs
gen/enum_check.py      emits a C program printing every enum/bitmask constant's value
lib/dune               (library (name vk) (public_name vulkan))
lib/vk.ml              hand-written main module: includes everything below
lib/vk_base.ml         hand-written runtime support (views, keep-alive, loader)
lib/generated/*.ml     generator output -- do not hand-edit
test/                  alcotest tests (headless, lavapipe)
test/layout/*.txt      golden struct layouts produced from real C headers
test/enum_values/*.txt golden enum/bitmask constant values produced from real C headers
shaders/               GLSL sources + committed SPIR-V, embedded as vk_test_shaders for test/
examples/              vkinfo, smoke, compute, triangle_offscreen, debug_utils (this document)
docs/GUIDE.md          practical API guide (this lane)
scripts/regen.sh       regenerate lib/generated from registry/vk.xml
scripts/gen_layout.sh  regenerate test/layout/<target-triple>.txt from real headers
scripts/gen_enum_values.sh  regenerate test/enum_values/<target-triple>.txt from real headers
scripts/embed_spv.ml   embed a compiled .spv file as an OCaml string constant
```

## Status and limitations

What is covered and verified is listed under [Status](#status) and
[Testing](#testing-lavapipe). The known rough edges and deliberate design
limits — please read these before shipping something on top of the library:

- **No display/windowing example has been run.** Every example renders
  offscreen (the development machine is headless). `docs/GUIDE.md` has an
  SDL2/`tsdl` interop sketch (handle ⇄ `nativeint` conversions,
  `VkSurfaceKHR`/swapchain creation, `acquire_next_image_khr` /
  `queue_present_khr` result handling) that type-checks conceptually but is
  explicitly marked untested — see
  [Interop with SDL2](docs/GUIDE.md#interop-with-sdl2-tsdl).
- **Memory and lifetimes.** Structures built with `X.make` keep everything
  they point to alive for as long as the structure itself (strings, arrays,
  nested structures, `pNext` chains via `Vk.next`); wrappers keep their list
  arguments alive across the C call. If you fill pointer fields yourself
  with `Ctypes.setf`, or build `CArray`s of structs by hand, *you* own those
  lifetimes. Memory mapped with `map_memory` is a raw `unit ptr`
  (use `Ctypes.bigarray_of_ptr`). See
  [Memory and lifetime](docs/GUIDE.md#memory-and-lifetime).
- **Callbacks** (`VK_EXT_debug_utils`, `VkAllocationCallbacks`, …) are
  supported only when the driver/layer invokes them synchronously on the
  thread that made the Vulkan call (validation layers do this). Vulkan calls
  hold the OCaml runtime lock for their duration, and callbacks do not try to
  reacquire it, so a driver that calls back from its own thread is
  unsupported. Callbacks registered through struct constructors are retained
  for the life of the process (never freed). See
  [Threading](docs/GUIDE.md#threading).
- **Dispatch tables are process-global (volk style).** `Vk.create_instance`
  (re)binds every instance- and device-level command through
  `vkGetInstanceProcAddr` for the newest instance; `Vk.Loader.load_device`
  is optional and only valid for single-device applications, which is why
  `Vk.create_device` does not call it. Applications juggling several live
  instances must call `Vk.Loader.load_instance` before using objects of a
  different instance. Loader state is mutex-protected across OCaml 5
  domains, but the runtime lock still serialises actual Vulkan calls. See
  [Extensions and function loading](docs/GUIDE.md#extensions-and-function-loading).
- **Extension commands that the loader/driver does not provide** are left
  unbound: calling one raises `Vk.Not_loaded "vkFooEXT"`. Check the enabled
  extensions (or the exception) rather than assuming availability.
- **64-bit integers above `2^62` collide** through the `int`-based views:
  `2^63-1` and `2^64-1` both read back as `-1`. This is inert for real
  Vulkan values (the only ones in that range are `UINT64_MAX`-style
  sentinels such as `Vk.whole_size = -1`, which round-trip correctly) but
  matters if you store your own data in `uint64` fields. See
  [The 64-bit integer caveat](docs/GUIDE.md#the-64-bit-integer-caveat).
- **Registry scope.** Everything with `api="vulkan"` in the registry is
  generated, including provisional/beta extensions (e.g.
  `VK_KHR_portability_subset`, needed on macOS/MoltenVK) and the platform
  window-system extensions (whose foreign handles are plain pointers/ints).
  Vulkan SC and `supported="disabled"` items are excluded.
- **Platforms.** 64-bit only (`x86_64`/`aarch64`). Linux is the only
  platform where the test suite and examples have actually been *run*.
  Windows (`vulkan-1.dll`) and macOS (`libvulkan.1.dylib`) are supported by
  design — the loader picks the right library name, the Win32/Metal
  window-system extensions are generated, and CI verifies every struct size
  and member offset (all platform-independent structs plus the Win32-only
  ones) against the headers with a **Win64 cross compiler**
  (`scripts/check_layout_win64.sh`, 8,441 compile-time assertions) — but
  nobody has yet built or run the library on either. On Windows you need an
  OCaml toolchain with `ctypes-foreign`/`libffi` (opam ≥ 2.2 with mingw-w64
  works) and the Vulkan runtime; reports welcome. The library name can be
  overridden with `Vk.Loader.load ~library` or `$OCAML_VULKAN_LIBRARY`.
- **Don't `open Vk`.** Module names follow Vulkan, so `Vk.Format`,
  `Vk.Result`, `Vk.Buffer`, `Vk.Queue`, `Vk.Semaphore`, `Vk.Event` shadow
  their `Stdlib` namesakes; use `Vk.` qualified names or `module V = Vk`.
- **Naming exception.** `DebugUtilsMessengerCreateInfoEXT.make` takes
  `~pfn_user_callback`/`~p_user_data` (the general rule strips those
  prefixes for other structs).
- Vulkan calls go through `libffi` (`ctypes-foreign`), roughly a few hundred
  nanoseconds of overhead per call — fine for command recording, but keep it
  in mind for very hot loops.

`CHANGELOG.md` lists what changed in each area.

## Authorship

**The entire project is AI-written.** No line of code, test, shader, script
or documentation in this repository was written by a human.

- The human owner set the goal ("complete OCaml bindings for Vulkan"),
  provided the machine and the repository, and made a few policy decisions
  (license, commit attribution, which models to use). They did not write
  or line-by-line review the code.
- The work was orchestrated by a Claude session using the
  [pi-subagents](https://github.com/nicobailon/pi-subagents) framework and
  carried out by autonomous agent lanes: the registry parser, generator
  core and runtime were written by **GPT‑5.6 Sol**; the verification harness,
  tests, examples, documentation, an independent adversarial review and the
  fixes that followed were written by **Claude Sonnet 5**. Commits are
  attributed to `caduc-ai <ai@caduc.co>`.
- Correctness was established mechanically rather than by human review:
  every generated struct layout (1,360) and enum constant (4,486) is checked
  against the real C headers, and the test suite creates real devices,
  runs a compute shader and renders a triangle on Mesa's lavapipe in CI. An
  independent AI review pass found and fixed two memory-safety bugs before
  the first release of this README.

Treat it accordingly: the automated evidence is strong for what it covers
(layouts, values, the tested code paths) and absent for what it does not
(windowed swapchain use, macOS/Windows, multi-threaded drivers). Read
[Status and limitations](#status-and-limitations), keep validation layers
on during development, and please report anything surprising in the
[issue tracker](https://github.com/lloyd-g-w/ocaml-vulkan/issues).

## License

This project is licensed under the GNU General Public License v3
(GPLv3) — see the [`LICENSE`](./LICENSE) file. `dune-project`'s `(license
GPL-3.0-only)` field (and the generated `vulkan.opam`) agree with it.
