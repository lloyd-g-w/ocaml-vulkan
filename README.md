# ocaml-vulkan

Complete, generated OCaml bindings to the [Vulkan](https://www.vulkan.org/)
graphics and compute API — core 1.0 through 1.4 plus every extension in the
Khronos registry (excluding the `vulkansc` API and provisional/beta-only
types, unless noted) — built on [`ctypes`](https://github.com/ocamllabs/ocaml-ctypes)
with no C stubs and no Vulkan headers required at build time.

This document is a draft written against [`DESIGN.md`](./DESIGN.md), the
binding contract between the generator, the hand-written runtime, the tests
and the examples. If the two ever disagree, `DESIGN.md` is authoritative —
please open an issue/PR rather than relying on this file.

## Status

Under active development; **not released yet**. The Khronos registry
(`registry/vk.xml`, pinned in `registry/VERSION`) and the generator design
are in place; the generator (`gen/gen.py`) and the generated bindings
(`lib/generated/`) are being built out. Until a tagged release exists, use
this repository via an opam pin (below) rather than a version constraint.

## Install

Not on the public opam repository yet. Pin it directly from a checkout or a
Git URL:

```sh
opam pin add vulkan git+https://github.com/lloyd-g-w/ocaml-vulkan.git
# or, from a local clone:
opam pin add vulkan .
```

Build-time dependencies are just OCaml (>= 4.14), `ctypes`, `ctypes-foreign`
and `integers` — no Vulkan SDK, no system Vulkan headers, no C compiler
plugin. `alcotest` (tests) and `odoc` (docs) are optional, opam-filtered
(`--with-test` / `--with-doc`).

## Runtime requirements

- A Vulkan loader shared library on the dynamic linker path:
  `libvulkan.so.1` on Linux, `libvulkan.1.dylib` on macOS, `vulkan-1.dll` on
  Windows. On Debian/Ubuntu this is the `libvulkan1` package
  (`libvulkan-dev` also works and additionally provides the unversioned dev
  symlink). The library is loaded lazily with `Dl.dlopen` the first time it's
  needed — see "Function loading" under [Design summary](#design-summary)
  below — so it does not need to be present at build time, only when your
  program actually calls into Vulkan.
- At least one installed Vulkan **ICD** (Installable Client Driver) that
  `libvulkan.so.1`'s loader can discover, normally via
  `/usr/share/vulkan/icd.d/*.json` or the `VK_ICD_FILENAMES` environment
  variable. For headless/CI use, Mesa's `lavapipe` (`llvmpipe`) software
  rasterizer works fully offscreen with no GPU: see
  [Testing](#testing-lavapipe) below.

## Design summary

See `DESIGN.md` for the full contract; the highlights:

- **Two generated layers.** `Vk.Fn` is a faithful **raw layer**: one OCaml
  function per Vulkan command with the C signature (handles/enums/ints
  typed, but still count+pointer pairs, output parameters, etc., exactly as
  in the C API). `Vk.*` (top-level, generated into `vk_api.ml`) is an
  **ergonomic layer** on top: struct constructors with labelled, optional
  arguments; `list`s instead of count+pointer pairs; two-call enumeration
  turned into a single function returning a list; `VkResult` errors raised
  as an OCaml exception instead of returned and checked by hand.
- **Function loading.** There are no link-time bindings to Vulkan commands
  at all — everything is resolved at runtime through
  `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr` (the same approach as
  [volk](https://github.com/zeux/volk)), so extensions and future core
  versions work without recompiling or relinking. `Vk.Loader.load` dlopens
  the platform loader library (default name, overridable via `?library` or
  `$OCAML_VULKAN_LIBRARY`); `Vk.create_instance` calls
  `Vk.Loader.load_instance` for you on success, which resolves every
  instance- and device-level command reachable through that instance.
  `Vk.Loader.load_device` is available if you want device-level commands
  resolved directly through `vkGetDeviceProcAddr` instead (only safe for
  single-device applications).
- **Memory and keep-alive rules.** `X.make` for a struct/union allocates
  zero-filled `ctypes` memory and fills in every field explicitly (`sType`
  set automatically from the struct's `structure_type`). Any OCaml-side
  allocation a struct's pointers need to stay valid — a `CArray` backing a
  `T*`+count list argument, a copied `string`, a nested structure, a
  `Foreign.funptr_opt` closure — is pushed onto a private `keep` list
  captured by that struct's GC finaliser, so the struct's own reachability
  keeps all of it alive; a full major GC will not free memory Vulkan still
  has a pointer to. This only covers what `make` itself allocated: if you
  `Ctypes.setf` a raw pointer field yourself after construction, you are
  responsible for keeping the pointee alive as long as the struct is live.
- **64-bit integer caveat.** All C integers (including `uint64_t`/
  `VkDeviceSize`/handles-as-integers) are exposed as plain OCaml `int` via
  two's-complement views, so e.g. `VK_WHOLE_SIZE` (`UINT64_MAX`) round-trips
  as `-1`. On 64-bit platforms OCaml's `int` has only 63 usable bits, so
  **bits 62–63 of an unsigned 64-bit value are not representable** as a
  positive `int`; Vulkan itself never produces values that use those bits
  (they'd represent sizes/counts far beyond any real device's limits), so
  this is a documented, inert limitation rather than a practical one.
- **Do not `open Vk`.** Several generated modules intentionally shadow
  Stdlib modules because they follow Vulkan's own naming
  (`Vk.Format`, `Vk.Result`, `Vk.Buffer`, `Vk.Queue`, `Vk.Semaphore`,
  `Vk.Event`). Always qualify (`Vk.Format.r8g8b8a8_unorm`,
  `Vk.create_instance`, ...), or bind a short local alias instead, e.g.
  `module V = Vk`.

## Usage example

Adapted from `DESIGN.md` §10:

```ocaml
let app =
  Vk.ApplicationInfo.make ~application_name:"demo" ~api_version:Vk.api_version_1_3 ()
in
let ci =
  Vk.InstanceCreateInfo.make ~application_info:app
    ~enabled_extension_names:[ "VK_KHR_surface" ] ()
in
let instance = Vk.create_instance ci in
let pds = Vk.enumerate_physical_devices instance in
let pd = List.hd pds in
let props = Vk.get_physical_device_properties pd in
print_endline (Vk.PhysicalDeviceProperties.get_device_name props);
let qf = Vk.get_physical_device_queue_family_properties pd in
ignore qf;
let device =
  Vk.create_device pd
    (Vk.DeviceCreateInfo.make
       ~queue_create_infos:
         [ Vk.DeviceQueueCreateInfo.make ~queue_family_index:0 ~queue_priorities:[ 1.0 ] () ]
       ())
in
(* ... record a command buffer cb, a vertex buffer vbuf, a queue and fence ... *)
Vk.cmd_bind_vertex_buffers cb 0 [ vbuf ] [ 0 ];
Vk.queue_submit queue [ Vk.SubmitInfo.make ~command_buffers:[ cb ] () ] fence;
Vk.destroy_device device () (* ?allocator omitted *)
```

## Regeneration

Generated code under `lib/generated/` is **committed** (so consumers only
need `ctypes`/`ctypes-foreign`, not Python or the registry), but it must
match `registry/vk.xml` exactly. After changing the registry or the
generator itself, regenerate and commit the result:

```sh
./scripts/regen.sh
git diff --stat lib/generated   # review, then commit
```

`scripts/regen.sh` is a thin wrapper around
`python3 gen/gen.py --registry registry/vk.xml --out lib/generated` (Python
3, standard library only — no dependencies to install). CI verifies this
script leaves the tree clean, i.e. that nobody hand-edited a generated file
or forgot to regenerate after a registry/generator change.

The C struct-layout golden file(s) under `test/layout/` are produced
separately, from the real platform C headers rather than the XML registry
(so they can catch generator/registry mistakes instead of just reproducing
them):

```sh
source /path/to/env-with-VULKAN_HEADERS.sh   # needs $VULKAN_HEADERS/include/vulkan/vulkan.h
./scripts/gen_layout.sh                       # writes test/layout/<target-triple>.txt
```

## Testing (lavapipe)

All tests are headless `alcotest` tests (`test/`) and run against a real
Vulkan implementation — Mesa's `lavapipe` (`llvmpipe`) software rasterizer —
so no GPU is required, including in CI:

```sh
opam install . --deps-only --with-test
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json  # path varies by distro; see below
dune build @runtest
```

If you don't already have a lavapipe ICD manifest installed, on
Debian/Ubuntu:

```sh
sudo apt-get install mesa-vulkan-drivers vulkan-tools   # vulkan-tools is optional, for vulkaninfo
find /usr/share/vulkan/icd.d -iname 'lvp_icd*.json'      # confirm the exact filename for your release
```

`test_layout.ml` additionally needs a golden file for your platform under
`test/layout/` (see [Regeneration](#regeneration) above); it is skipped
with a message, not failed, when one isn't available for the current
target.

## License

The [`LICENSE`](./LICENSE) file in this repository is the GNU General
Public License v3 (GPLv3). **Note:** `dune-project` currently declares
`(license MIT)`, which disagrees with `LICENSE` and will show up as `MIT`
in the generated `vulkan.opam`/opam metadata; this is a pre-existing
inconsistency in the repository skeleton (present before this document was
written), not a decision made here — it should be reconciled by whoever
owns `dune-project`/`LICENSE` before the first release. Until then, treat
the `LICENSE` file as authoritative.
