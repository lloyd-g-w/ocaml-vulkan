# ocaml-vulkan guide

A practical, example-driven tour of the generated bindings. `DESIGN.md` at
the repository root is the authoritative *contract*; this guide is a
reader-friendly walkthrough of the same material with real code, written
against and checked against the actual generated sources in
`lib/generated/` (not just the prose in `DESIGN.md` — the two occasionally
disagree; every such case is called out below with **Gotcha** boxes).

Runnable, more complete versions of most of the patterns below live in
[`examples/`](../examples/): [`vkinfo.ml`](../examples/vkinfo.ml) (query
instance/device properties), [`smoke.ml`](../examples/smoke.ml) (buffer +
memory basics), [`compute.ml`](../examples/compute.ml) (a full compute
dispatch), [`triangle_offscreen.ml`](../examples/triangle_offscreen.ml) (a
full graphics render pass) and [`debug_utils.ml`](../examples/debug_utils.ml)
(VK_EXT_debug_utils + `pNext` chaining). See the top-level
[`README.md`](../README.md) for how to build and run them.

Every snippet on this page was checked against `lib/generated/*.ml` (by
`grep`, or by compiling it) as it was written; none of it is invented. Where
that process turned up a discrepancy between `DESIGN.md` and the generated
code, or an outright bug, it's flagged inline and summarised in
[Known generator issues](#known-generator-issues-as-of-this-writing) at the
end.

## Contents

1. [Loading and versions](#loading-and-versions)
2. [Handles](#handles)
3. [Enums and flags](#enums-and-flags)
4. [Structs and unions](#structs-and-unions)
5. [Memory and lifetime](#memory-and-lifetime)
6. [Commands](#commands)
7. [Extensions and function loading](#extensions-and-function-loading)
8. [Interop with SDL2 (tsdl)](#interop-with-sdl2-tsdl)
9. [Threading](#threading)
10. [The 64-bit integer caveat](#the-64-bit-integer-caveat)
11. [Regeneration workflow](#regeneration-workflow)
12. [Known generator issues (as of this writing)](#known-generator-issues-as-of-this-writing)

## Loading and versions

Nothing needs to be linked at build time. The first Vulkan call you make
(directly, or indirectly through `Vk.create_instance`) triggers
`Vk.Loader.load`, which `Dl.dlopen`s `libvulkan.so.1` (Linux; see
`Vk_base.Loader.default_library` for the other platforms and the
`$OCAML_VULKAN_LIBRARY`/`?library` override) and resolves
`vkGetInstanceProcAddr`/`vkGetDeviceProcAddr` through it:

```ocaml
Vk.Loader.load ();                    (* optional: happens lazily anyway *)
Vk.Loader.load ~library:"libvulkan.so.1" ();  (* idempotent, explicit path *)
```

Version numbers are packed 32-bit integers (`VkPhysicalDeviceProperties`'s
`apiVersion`/`driverVersion`, `VkApplicationInfo`'s `apiVersion`, ...); use
the helpers rather than bit-twiddling by hand:

```ocaml
Vk.api_version_1_0, Vk.api_version_1_1, Vk.api_version_1_2,
Vk.api_version_1_3, Vk.api_version_1_4                  (* : int *)
Vk.make_api_version ~variant:0 1 3 275                  (* build one *)
Vk.string_of_version (Vk.enumerate_instance_version ()) (* "1.3.275" *)
```

`Vk.enumerate_instance_version` is itself a global command and loads the
library on first use, so you can call it before creating anything else (see
`examples/vkinfo.ml`).

## Handles

Every Vulkan handle type is a module implementing the `HANDLE` signature
(`DESIGN.md` §6): `VkInstance`/`VkDevice`/`VkQueue`/`VkCommandBuffer` are
*dispatchable* (backed by `unit Ctypes.ptr`); everything else (`VkBuffer`,
`VkImage`, `VkPipeline`, `VkDescriptorSet`, ...) is *non-dispatchable*
(backed by a `uint64` view). Both kinds expose the same operations:

```ocaml
Vk.Buffer.null : Vk.Buffer.t
Vk.Buffer.is_null buf : bool
Vk.Buffer.equal a b : bool
Vk.Buffer.to_string buf : string        (* "0x7f..." / "0x1234" *)
Vk.Buffer.to_int64 / of_int64           (* stable, e.g. for hashing/logging *)
Vk.Buffer.to_nativeint / of_nativeint   (* interop, e.g. with tsdl -- see below *)
```

`smoke.ml` checks a queue for null this way:
`if Vk.Queue.is_null queue then failwith "vkGetDeviceQueue returned NULL"`.
Aliased handles (`VkDescriptorUpdateTemplateKHR` etc.) are plain module
aliases (`module DescriptorUpdateTemplateKHR = DescriptorUpdateTemplate`),
so both names always refer to the same type — no coercion needed.

## Enums and flags

Every `VkFoo`/`VkFooFlagBits`+`VkFooFlags` pair becomes one module with an
abstract, private `int`:

```ocaml
type t = private int
val of_int : int -> t
val to_int : t -> int
val to_string : t -> string   (* "VK_IMAGE_LAYOUT_GENERAL", or "ImageLayout(1234)"/"Flags(0x..)" for unknown values *)
val pp : Format.formatter -> t -> unit
val equal : t -> t -> bool
val compare : t -> t -> int
```

Plain enums (`Vk.ImageLayout`, `Vk.Format`, `Vk.PhysicalDeviceType`, ...)
have one named value per enumerant:

```ocaml
Vk.ImageLayout.general : Vk.ImageLayout.t
Vk.PhysicalDeviceType.to_string (Ctypes.getf props Vk.PhysicalDeviceProperties.device_type)
(* -> "VK_PHYSICAL_DEVICE_TYPE_CPU" on lavapipe *)
```

Flag modules (`Vk.ImageUsageFlags`, `Vk.QueueFlags`, `Vk.MemoryPropertyFlags`,
...) additionally provide bitwise operations and pretty-print as
`"A_BIT | B_BIT"`:

```ocaml
val empty : t
val ( lor ) : t -> t -> t   (* union *)
val ( land ) : t -> t -> t  (* intersection *)
val union / inter / diff : t -> t -> t
val mem : t -> t -> bool    (* mem flags bit -- note the argument order *)
val of_list / to_list : t list -> t / t -> t list
```

`vkinfo.ml` combines several of these:

```ocaml
Vk.QueueFlags.to_string (Ctypes.getf queue Vk.QueueFamilyProperties.queue_flags)
(* -> "VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT | ..." *)
```

and `find_queue_family`-style helpers in every example test `mem`:

```ocaml
let is_compute_capable qf =
  Vk.QueueFlags.mem (Ctypes.getf qf Vk.QueueFamilyProperties.queue_flags) Vk.QueueFlags.compute
```

`Vk.Result` is generated exactly like any other enum (`Vk.Result.success`,
`Vk.Result.error_device_lost`, `Vk.Result.to_string`, ...); see
[Commands](#commands) for how it's used for error handling.

## Structs and unions

### `make` vs. raw fields

Every struct module exposes both the raw `Ctypes` fields (matching the C
member names, snake_cased: `s_type`, `p_next`, `queue_family_index`, ...) and
a `make` that takes labelled, optional arguments, fills in `sType`
automatically from `structure_type`, and zero-fills everything else
(`DESIGN.md` §7). You almost always want `make`:

```ocaml
let info =
  Vk.BufferCreateInfo.make ~size:4096 ~usage:Vk.BufferUsageFlags.transfer_src
    ~sharing_mode:Vk.SharingMode.exclusive ()
in
Ctypes.getf info Vk.BufferCreateInfo.size          (* read a field back: 4096 *)
```

The raw fields are still useful for reading results back (there's no
`get`-style wrapper — everything goes through `Ctypes.getf`/`setf`), and,
as shown further down, for working around a couple of generator bugs in
specific `make` functions.

### Lists instead of count + pointer

Any C `count` + `const T*` pair becomes one `?xs:elem list` argument;
`make` allocates a `CArray`, sets the count for you, and keeps the array
(and, for structs, each element) alive (see
[Memory and lifetime](#memory-and-lifetime)):

```ocaml
Vk.InstanceCreateInfo.make
  ~enabled_extension_names:[ "VK_KHR_surface"; "VK_EXT_debug_utils" ]  (* -> ppEnabledExtensionNames + enabledExtensionCount *)
  ~application_info:app  (* single struct pointer, not a list: `const T* p` with no count *)
  ()
```

> **Gotcha — shared counts.** A handful of structs have *two or three*
> pointer members that all declare the same C member as their `len` (e.g.
> `VkWriteDescriptorSet`'s `pImageInfo`/`pBufferInfo`/`pTexelBufferView` all
> share `descriptorCount`; `VkSubpassDescription`'s `pColorAttachments`/
> `pResolveAttachments` share `colorAttachmentCount`). The generator's `make`
> only derives the shared count field from *one* of them (the last one it
> emits, not necessarily the one you actually populate), so the count can
> silently come out as `0` or otherwise wrong. See
> [Known generator issues](#known-generator-issues-as-of-this-writing) for
> the full list and the `Ctypes.setf ... ()` workaround used in
> `examples/compute.ml` and `examples/triangle_offscreen.ml`.

### Strings

`const char*` struct members (`len="null-terminated"`, e.g.
`pApplicationName`) take a plain `string option` argument (`?x:string`,
`None` -> `NULL`); `const char* const*` + count members (e.g.
`ppEnabledExtensionNames`) take a `string list`. Reading a string back out of
a struct uses one of the two helpers in `Vk_base.Public` depending on
whether the field is a fixed `char[N]` array or a `char*` pointer:

```ocaml
Vk.PhysicalDeviceProperties.get_device_name props  (* char deviceName[256] -> generated get_<name> helper, uses string_of_char_array *)
Vk.string_of_char_ptr (Ctypes.getf data Vk.DebugUtilsMessengerCallbackDataEXT.p_message)  (* char* pMessage, "" if NULL *)
```

(`examples/debug_utils.ml`'s callback uses the second form; every `X[N]`
member that the generator turns into a fixed `char CArray.t` gets its own
`get_<field>` helper using the first form, as seen in `vkinfo.ml` and
`smoke.ml` for `deviceName`/layer and extension names.)

### `pNext` chains

`Vk.next : 'a Ctypes.structure -> Vk_base.next` wraps *any* structure (it's
a GADT hiding the type parameter) so it can be threaded through a `?next`
argument; the outer struct's `make` stores the address and keeps the inner
structure alive via its own `keep` list:

```ocaml
let vulkan_12_features = Vk.PhysicalDeviceVulkan12Features.make () in
let features2 = Vk.PhysicalDeviceFeatures2.make ~next:(Vk.next vulkan_12_features) () in
Vk.get_physical_device_features_2 physical_device features2;
Ctypes.getf vulkan_12_features Vk.PhysicalDeviceVulkan12Features.timeline_semaphore  (* : bool, filled in by the driver *)
```

This works because `features2` and `vulkan_12_features` are two ordinary,
separately-addressable `Ctypes` structures: the driver writes into
`vulkan_12_features`'s memory through the pointer stored in `features2`'s
`pNext`, and you read it back through the *same* OCaml binding you passed
in — you don't need any accessor on `features2` itself to reach the chained
struct. `examples/debug_utils.ml` runs exactly this snippet end to end
(against real lavapipe/llvmpipe values) and additionally chains a
`Vk.DebugUtilsMessengerCreateInfoEXT` onto `Vk.InstanceCreateInfo.make`'s
`?next`, so `vkCreateInstance`/`vkDestroyInstance` themselves are covered by
the debug messenger, not just calls made after the instance exists.

Multiple links in a chain just nest: `Vk.next` only wraps one structure at a
time, so build the chain from the innermost struct outward (each struct's
own `?next` is where the *next* link goes, exactly as in C).

### Unions

`VkClearValue`/`VkClearColorValue` are typical unions: one constructor
function per member, no `make`/labelled-argument story since a union has no
"all fields" to default:

```ocaml
Vk.ClearValue.color (Vk.ClearColorValue.float32 [ 0.0; 0.0; 0.0; 1.0 ])  (* used in triangle_offscreen.ml's clear colour *)
Vk.ClearColorValue.int32 [ 0; 0; 0; 0 ]     (* also available: int32/uint32 variants *)
Vk.ClearValue.depth_stencil (Vk.ClearDepthStencilValue.make ~depth:1.0 ~stencil:0 ())
```

(`ClearColorValue`'s three constructors — `float32`/`int32`/`uint32` — each
take up to 4 elements and pad with zeros, mirroring the `T x[N]` rule for
struct members.)

### Bitfields

C bitfields (`:24`, `:8`, ...) are merged into one raw field per contiguous
group, and `make` takes each sub-field as its own labelled argument and
packs them LSB-first. `VkAccelerationStructureInstanceKHR` has two such
groups (`instanceCustomIndex:24 | mask:8` and
`instanceShaderBindingTableRecordOffset:24 | flags:8`):

```ocaml
let instance =
  Vk.AccelerationStructureInstanceKHR.make ~instance_custom_index:0x00abcdef (* 24 bits *)
    ~mask:0xa5 (* 8 bits *)
    ~instance_shader_binding_table_record_offset:0x00123456 (* 24 bits *)
    ~flags:Vk.GeometryInstanceFlagsKHR.triangle_facing_cull_disable_khr
    ~acceleration_structure_reference:device_address ()
in
Ctypes.getf instance Vk.AccelerationStructureInstanceKHR.instance_custom_index_bits
(* = 0x00abcdef lor (0xa5 lsl 24), i.e. the packed 32-bit raw field *)
```

Note that a bitfield sub-member typed as an enum/flags in the XML (`flags`
above is a `VkGeometryInstanceFlagsKHR`) still takes that module's `t`, not
a raw `int` — `make` calls `to_int` on it internally before packing.

## Memory and lifetime

`make` allocates with `Ctypes.make ~finalise:(fun _ -> ignore (Sys.opaque_identity !keep)) t`
and pushes every OCaml-side allocation the struct's pointers need — `CArray`s
backing list arguments, copied strings, nested structs passed by pointer,
`Foreign.funptr_opt` closures for callbacks — onto that struct's private
`keep : Obj.t list ref`. As long as *the struct itself* is reachable, the GC
won't collect anything it points to; a `Gc.full_major ()` right after
building a struct (as `smoke.ml` does after every `make`/create call) is
therefore safe and won't corrupt anything Vulkan still holds a pointer to.

What this **does not** cover:

- Anything you write into a struct's raw fields yourself with `Ctypes.setf`
  after `make` returns (used deliberately for the workarounds in
  [Known generator issues](#known-generator-issues-as-of-this-writing) below
  — those only ever write plain integers, never pointers, so there's nothing
  extra to keep alive). If you `setf` a *pointer* field by hand, you are
  responsible for the pointee's lifetime.
- The struct value itself once nothing references it — e.g. don't build a
  `Vk.SubmitInfo.t` inline in an expression whose result you discard before
  the driver has actually read it; bind it to a variable that stays in scope
  across the call that uses it (all the examples do this).
- Anything on the *Vulkan* side: destroying a `VkDevice` while buffers/images
  allocated from it are still live, or `vkFreeMemory`-ing memory a buffer is
  still bound to, is a Vulkan-level use-after-free that this binding cannot
  detect (there's no validation layer on this machine — see
  [Extensions and function loading](#extensions-and-function-loading)).

### Mapping memory

`Vk.map_memory` returns a raw `unit Ctypes.ptr`; there's no wrapper that
turns it into a typed view for you, so coerce it yourself. Two idioms, both
used across the examples:

```ocaml
(* Ctypes pointer arithmetic (examples/compute.ml, examples/smoke.ml) *)
let mapped = Vk.map_memory device memory 0 buffer_bytes Vk.MemoryMapFlags.empty in
let words = Ctypes.(coerce (ptr void) (ptr uint32_t)) mapped in
Ctypes.(words +@ i <-@ Unsigned.UInt32.of_int i);           (* write element i *)
Unsigned.UInt32.to_int Ctypes.(!@(words +@ i))              (* read it back *)

(* Bigarray, zero-copy over the same memory (Ctypes.bigarray_of_ptr) *)
let words : (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t =
  Ctypes.bigarray_of_ptr Ctypes.array1 n_elements Bigarray.int32
    (Ctypes.from_voidp Ctypes.int32_t mapped)
in
Bigarray.Array1.set words 0 42l
```

Prefer the `Bigarray` form when you want to hand the mapped range to code
that already speaks `Bigarray` (image codecs, `Stb_image`-style libraries,
NumPy-via-`pyml`, etc.); both forms read/write the exact same underlying
bytes with no copy. Either way: only `Vk.MemoryPropertyFlags.host_coherent`
memory (as found by the `find_memory_type` helper duplicated in every
example) is safe to read/write without explicit
`vkFlushMappedMemoryRanges`/`vkInvalidateMappedMemoryRanges` calls, and you
must `Vk.unmap_memory` before `Vk.free_memory`-ing (or destroying the
device).

## Commands

### `Vk.*` wrappers vs. `Vk.Fn` raw

`Vk.Fn.<name>` is the literal C signature (handles/enums/ints typed, but
still count+pointer pairs and output parameters exactly as in C); `Vk.<name>`
(same name, no `Fn.`) is the ergonomic wrapper described throughout this
guide. Reach for `Vk.Fn` only when you need the exact C shape (rare — mostly
useful for probing whether/how an extension command got loaded, as in
[Extensions and function loading](#extensions-and-function-loading) below).

### Errors

Any command whose `VkResult` can be negative raises:

```ocaml
exception Vk.Error of Vk.Result.t   (* prints as "Vk.Error(VK_ERROR_...)" *)
```

registered with `Printexc.register_printer`, so an uncaught one at the top
of a program prints legibly rather than as an opaque `Fatal error:
exception _`. `Vk.check : Vk.Result.t -> unit` (used internally by every
wrapper) is also exposed directly if you're calling into `Vk.Fn` yourself:

```ocaml
try Vk.create_instance bad_info with
| Vk.Error Vk.Result.error_layer_not_present -> (* handle: retry without layers *) ()
| Vk.Error result -> failwith ("vkCreateInstance failed: " ^ Vk.Result.to_string result)
```

### Success-code tuples

When a command's `successcodes` includes more than `VK_SUCCESS`, the wrapper
*also* returns the `Result.t` (not just raising on failure), as the first
element of a tuple when there's an output value too:

```ocaml
val acquire_next_image_khr :
  Vk.Device.t -> Vk.SwapchainKHR.t -> int -> Vk.Semaphore.t -> Vk.Fence.t -> Vk.Result.t * int
(* VK_SUBOPTIMAL_KHR is a successcode: check for it explicitly, it isn't an exception *)
let result, image_index = Vk.acquire_next_image_khr device swapchain timeout semaphore Vk.Fence.null in
if Vk.Result.equal result Vk.Result.suboptimal_khr then (* recreate the swapchain soon *) ();
```

`Vk.wait_for_fences` is the no-output-value version of the same rule
(`VK_TIMEOUT` is a successcode): it returns `Vk.Result.t` alone, which every
example checks explicitly with `Vk.Result.equal ... Vk.Result.success` rather
than assuming success (see `examples/compute.ml`).

### Two-call enumeration

`uint32_t* pCount` + `T* pItems` (`len="pCount"`) becomes a single call
returning a plain list, retrying internally on `VK_INCOMPLETE`:

```ocaml
val enumerate_physical_devices : Vk.Instance.t -> Vk.PhysicalDevice.t list
val get_swapchain_images_khr : Vk.Device.t -> Vk.SwapchainKHR.t -> Vk.Image.t list
val get_physical_device_surface_formats_khr :
  Vk.PhysicalDevice.t -> Vk.SurfaceKHR.t -> Vk.SurfaceFormatKHR.t Ctypes.structure list
```

Struct results have `sType` filled in when the struct has one; handles/ints
just come back as their plain OCaml type. There's no special ceremony on the
caller's side — `List.hd`, `List.iter`, `List.length`, etc. all just work, as
in every example's `find_queue_family`/`enumerate_physical_devices` calls.

### Output-array commands (and where the pattern breaks down)

A *single* trailing output pointer (`VkInstance* pInstance`,
`VkMemoryRequirements* pMemoryRequirements`) is allocated by the wrapper and
returned directly — no ceremony needed there either:

```ocaml
val create_instance : Vk.InstanceCreateInfo.t Ctypes.structure -> Vk.Instance.t
val get_buffer_memory_requirements : Vk.Device.t -> Vk.Buffer.t -> Vk.MemoryRequirements.t Ctypes.structure
```

> **Gotcha — batch-create/-allocate commands.** `vkCreateGraphicsPipelines`,
> `vkCreateComputePipelines`, `vkAllocateDescriptorSets` and
> `vkAllocateCommandBuffers` all have an output array whose length is
> already implied by an *input* (the `createInfoCount` you're passing in, or
> a struct field like `descriptorSetCount` that was itself derived from a
> `~set_layouts` list) rather than a separate `pCount` you get back — that
> shape isn't the two-call pattern above, and it isn't a single output value
> either, so the generator's fallback leaves the output pointer raw. You
> allocate it yourself and dereference it after the call:
>
> ```ocaml
> let pipelines = Ctypes.allocate_n Vk.Pipeline.t ~count:1 in
> let (_ : Vk.Result.t) =
>   Vk.create_compute_pipelines device Vk.PipelineCache.null [ pipeline_create_info ] pipelines
> in
> let pipeline = Ctypes.( !@ ) pipelines
> ```
>
> (exactly as done in `examples/compute.ml` and
> `examples/triangle_offscreen.ml`, including the `allocate_descriptor_sets`/
> `allocate_command_buffers` variants). For more than one at a time, use
> `Ctypes.allocate_n ... ~count:n` and `Ctypes.CArray.from_ptr ptr n |>
> Ctypes.CArray.to_list` instead of a single `!@`.

## Extensions and function loading

`Vk.create_instance` calls `Vk.Loader.load_instance` for you on success,
which resolves *every* instance- and device-level command reachable through
that instance via `vkGetInstanceProcAddr` (missing entry points — extensions
you didn't enable, or the driver doesn't support — stay `None` internally).
`Vk.create_device` deliberately does **not** call `Vk.Loader.load_device`
(multi-device safety, per `DESIGN.md` §9); call it yourself if you only ever
have one `VkDevice` and want device-level commands resolved directly through
`vkGetDeviceProcAddr` instead of the instance-level trampoline:

```ocaml
let device = Vk.create_device physical_device device_create_info in
Vk.Loader.load_device device;   (* optional, single-device fast path *)
```

Calling a command whose function pointer was never resolved — extension not
enabled, or the loader/ICD simply doesn't implement it — raises
`Vk.Not_loaded : string -> exn` (the string is the C name, e.g.
`"vkCmdDrawMeshTasksEXT"`), rather than crashing:

```ocaml
match Vk.Fn.cmd_draw_mesh_tasks_ext command_buffer 1 1 1 with
| exception Vk.Not_loaded name -> Printf.printf "%s is not available here\n" name
| () -> ()
```

`examples/debug_utils.ml` demonstrates `VK_EXT_debug_utils` end to end:
enable it in `~enabled_extension_names`, install an OCaml callback
(`Vk.PfnDebugUtilsMessengerCallbackEXT.fn = DebugUtilsMessageSeverityFlagsEXT.t
-> DebugUtilsMessageTypeFlagsEXT.t -> DebugUtilsMessengerCallbackDataEXT.t
Ctypes.structure Ctypes.ptr -> unit Ctypes.ptr -> bool`) via
`Vk.DebugUtilsMessengerCreateInfoEXT.make ~pfn_user_callback`, both
pNext-chained onto instance creation and as a standalone
`Vk.create_debug_utils_messenger_ext`. This machine has no validation layer
installed, so the example proves the callback actually fires by calling
`Vk.submit_debug_utils_message_ext` directly (a loader-implemented function
that fans a message out to every registered messenger, independent of any
ICD/layer) — running it also happens to print a wall of genuine loader/
`VK_LAYER_MESA_device_select` diagnostic messages, since that implicit layer
is present on this machine and also uses `VK_EXT_debug_utils` for its own
logging.

> **Naming note.** `DESIGN.md` §3 says ergonomic argument labels drop the
> `p`/`pp`/`pfn` prefix (`~application_name`, not `~p_application_name`).
> The generated `DebugUtilsMessengerCreateInfoEXT.make` doesn't do this for
> its two `PFN_*`/`void*` members: the real labels are `~pfn_user_callback`
> and `~p_user_data`, not `~user_callback`/`~user_data`. Use the real names
> (as this guide and `examples/debug_utils.ml` do) — `grep lib/generated` if
> in doubt for any struct.

## Interop with SDL2 (tsdl)

This machine has no display and `tsdl` isn't installed here, so **the
snippet below is illustrative only: it has not been compiled or run**,
unlike everything else in this guide. It's a sketch of how the pieces fit
together, using `tsdl`'s real, documented `Sdl.Vulkan` API (`nativeint` for
`VkInstance`, `Unsigned.uint64` for `VkSurfaceKHR`) and `Vk.Instance`/
`Vk.SurfaceKHR`'s `HANDLE` conversions from [Handles](#handles) above —
double-check both APIs against your installed `tsdl` and `vulkan` versions
before relying on it.

```ocaml
(* let module Sdl = Tsdl.Sdl in *)

(* 1. ask SDL which instance extensions its Vulkan support needs *)
let sdl_extensions =
  match Sdl.Vulkan.get_instance_extensions window with
  | Some exts -> exts
  | None -> failwith (Sdl.get_error ())
in

(* 2. create the VkInstance as usual, with those extensions enabled *)
let instance =
  Vk.create_instance
    (Vk.InstanceCreateInfo.make ~application_info:app
       ~enabled_extension_names:(Vk.Ext.khr_surface :: sdl_extensions) ())
in

(* 3. hand the *same* instance to SDL (as a nativeint) to create the surface *)
let sdl_instance = Sdl.Vulkan.unsafe_instance_of_ptr (Vk.Instance.to_nativeint instance) in
let surface =
  match Sdl.Vulkan.create_surface window sdl_instance with
  | Some s -> Vk.SurfaceKHR.of_int64 (Unsigned.UInt64.to_int64 (Sdl.Vulkan.unsafe_uint64_of_surface s))
  | None -> failwith (Sdl.get_error ())
in

(* 4. ordinary swapchain setup from here on *)
let capabilities = Vk.get_physical_device_surface_capabilities_khr physical_device surface in
let formats = Vk.get_physical_device_surface_formats_khr physical_device surface in
let format = (List.hd formats) in (* pick a real one; this is a sketch *)
let extent = Ctypes.getf capabilities Vk.SurfaceCapabilitiesKHR.current_extent in
let swapchain =
  Vk.create_swapchain_khr device
    (Vk.SwapchainCreateInfoKHR.make ~surface
       ~min_image_count:(Ctypes.getf capabilities Vk.SurfaceCapabilitiesKHR.min_image_count)
       ~image_format:(Ctypes.getf format Vk.SurfaceFormatKHR.format)
       ~image_color_space:(Ctypes.getf format Vk.SurfaceFormatKHR.color_space)
       ~image_extent:extent ~image_array_layers:1
       ~image_usage:Vk.ImageUsageFlags.color_attachment
       ~image_sharing_mode:Vk.SharingMode.exclusive
       ~pre_transform:(Ctypes.getf capabilities Vk.SurfaceCapabilitiesKHR.current_transform)
       ~composite_alpha:Vk.CompositeAlphaFlagsKHR.opaque_khr ~present_mode:Vk.PresentModeKHR.fifo_khr
       ~clipped:true ())
in
let swapchain_images = Vk.get_swapchain_images_khr device swapchain in
let image_available = Vk.create_semaphore device (Vk.SemaphoreCreateInfo.make ()) in
let render_finished = Vk.create_semaphore device (Vk.SemaphoreCreateInfo.make ()) in

(* 5. the per-frame loop *)
let render_frame () =
  let _result, image_index =
    Vk.acquire_next_image_khr device swapchain Vk.whole_size (* no timeout *) image_available
      Vk.Fence.null
  in
  ignore (List.nth swapchain_images image_index);
  (* ... record/submit a command buffer that waits on image_available, renders
     into swapchain_images.(image_index), and signals render_finished ... *)
  Vk.queue_present_khr queue
    (Vk.PresentInfoKHR.make ~wait_semaphores:[ render_finished ] ~swapchains:[ swapchain ]
       ~image_indices:[ image_index ] ())
```

> **Gotcha (same family as above).** `VkPresentInfoKHR.swapchainCount` is
> the `len` target of *both* `pSwapchains` and `pImageIndices`; the
> generated `make` derives it from `~image_indices`'s length, not
> `~swapchains`'s. The snippet above happens to always pass matching
> one-element lists, so it's unaffected, but presenting to more than one
> swapchain at once (rare) would need the same `Ctypes.setf` workaround as
> `WriteDescriptorSet`/`SubpassDescription` above.

## Threading

Vulkan itself allows calling into most commands from multiple threads as
long as you don't mutate the same object concurrently (see the spec's
"Threading Behavior" appendix) — this binding doesn't add any additional
restriction on the *Vulkan-call* side. Two OCaml-specific notes:

- OCaml's runtime lock is a single global lock; two threads both calling
  into a `Vk.*`/`Vk.Fn.*` function at the same time serialise on it like any
  other OCaml code would, they don't get true concurrent execution inside
  this binding (the driver-side work Vulkan itself does on your behalf,
  e.g. inside a queue submission, is unaffected — that happens in the
  driver/kernel, outside OCaml entirely).
- User-supplied callbacks (right now, just `PfnDebugUtilsMessengerCallbackEXT`
  — see [Extensions and function loading](#extensions-and-function-loading))
  are wrapped with `Foreign.funptr_opt` with no `~runtime_lock` argument
  (i.e. the `ctypes-foreign` default), which is a **discrepancy** from
  `DESIGN.md` §8's claim that this uses `~runtime_lock:true`. In practice
  this hasn't caused a problem in `examples/debug_utils.ml` because every
  message observed there (both the loader's own diagnostics and our
  synthetic `vkSubmitDebugUtilsMessageEXT` one) is delivered synchronously,
  on the same thread that's already holding the runtime lock inside the
  triggering Vulkan/OCaml call. A driver or layer that invokes the callback
  from a separate, non-Vulkan-call thread (some validation layers' async
  logging paths do this) could behave differently; this hasn't been
  exercised on this machine (no validation layer installed) — see
  [Known generator issues](#known-generator-issues-as-of-this-writing).

## The 64-bit integer caveat

Every C integer type — including `uint64_t`, `VkDeviceSize`, and handles
that are represented as 64-bit integers on the wire — is exposed as a plain
OCaml `int` through a two's-complement view (`DESIGN.md` §4). This means:

- `Vk.whole_size = -1` *is* `VK_WHOLE_SIZE` (`UINT64_MAX`); pass it to
  `~range:Vk.whole_size` etc. exactly as the C API expects `VK_WHOLE_SIZE`
  (see `examples/compute.ml`'s `DescriptorBufferInfo.make ~range:Vk.whole_size`).
- OCaml's native `int` on 64-bit platforms only has 63 usable bits, so the
  top two bits (62–63) of a genuinely large unsigned 64-bit value are not
  representable as a positive `int`. Vulkan never actually produces values
  that use those bits in practice (no real device has e.g. a
  `VkDeviceSize`-typed limit anywhere near 2⁶²), so this is a real but inert
  limitation — it would only bite a program that tries to round-trip an
  arbitrary attacker-controlled or synthetic 64-bit value through this
  binding, not normal Vulkan usage.
- This library only supports 64-bit platforms in the first place (`x86_64`/
  `aarch64`; `DESIGN.md` §1), so there's no 32-bit-`int` version of this
  problem to worry about.

## Regeneration workflow

`lib/generated/` is committed (so consumers only need `ctypes`/
`ctypes-foreign`, not Python or the registry), but must always match
`registry/vk.xml` exactly. To regenerate after changing the registry or the
generator itself:

```sh
./scripts/regen.sh                    # wraps: python3 gen/gen.py --registry registry/vk.xml --out lib/generated
git diff --stat lib/generated         # review before committing
```

`gen/gen.py` is deterministic (sorted iteration) and Python-3-stdlib-only —
no dependencies to install, no network access needed (the registry is
already vendored at `registry/vk.xml`, pinned by `registry/VERSION`). CI
re-runs it and fails if the tree isn't clean afterwards, so a registry bump
or generator change and its regenerated output must land in the same
commit.

The C struct-layout golden file(s) under `test/layout/` are produced
separately, compiled against the *real* platform C headers rather than the
XML registry, specifically so they can catch a generator/registry mistake
instead of just reproducing it:

```sh
source /home/ubu3/projects/vk-env.sh   # sets $VULKAN_HEADERS
./scripts/gen_layout.sh                 # writes test/layout/<target-triple>.txt
```

## Known generator issues (as of this writing)

These were found while writing `examples/compute.ml`,
`examples/triangle_offscreen.ml` and `examples/debug_utils.ml`; each is
described in more depth, in context, above. This project's docs/examples
lane doesn't own `gen/`/`lib/generated/`, so these are workarounds, not
fixes — see the handoff report for the full precise write-up (root cause in
`gen/vkgen/emit_types.py`, minimal repros, severity).

1. **`Vk.DescriptorSetLayoutBinding.make` has no `~descriptor_count`
   argument** — it's always `List.length ~immutable_samplers`, so it's `0`
   for any binding without immutable samplers (almost all of them). Fix:
   `Ctypes.setf binding Vk.DescriptorSetLayoutBinding.descriptor_count n`
   after `make`, before using the binding.
2. **`Vk.WriteDescriptorSet.make`'s `descriptorCount` always comes from
   `~texel_buffer_view`**, never `~image_info`/`~buffer_info`, because all
   three share `len="descriptorCount"` in `vk.xml`. Fix: same `Ctypes.setf`
   pattern.
3. **`Vk.SubpassDescription.make`'s `colorAttachmentCount` always comes from
   `~resolve_attachments`**, never `~color_attachments`, for the same
   shared-`len` reason — breaks any render pass without MSAA resolve
   attachments (i.e. almost all of them). Fix: same `Ctypes.setf` pattern.
4. **The same shared-count shape affects at least
   `VkPresentInfoKHR.swapchainCount` (`pSwapchains`/`pImageIndices`),
   `VkSubmitInfo.waitSemaphoreCount` (`pWaitSemaphores`/`pWaitDstStageMask`)
   and a dozen more structs** — none of these happened to be tripped by the
   examples in this repository (their two lists always end up the same
   length in normal use), but they're latent; see the handoff report for
   the complete list.
5. **`Vk.create_graphics_pipelines`/`Vk.create_compute_pipelines`/
   `Vk.allocate_descriptor_sets`/`Vk.allocate_command_buffers` don't return
   the created handle(s) as a list.** Their output array's length is
   implied by an input rather than a separate `pCount` out-parameter, a
   shape `DESIGN.md` §10 doesn't specify a rule for; the generator's
   fallback leaves the output pointer raw. Allocate it yourself with
   `Ctypes.allocate_n` and dereference/`CArray.from_ptr` it after the call.
6. **Naming**: `DebugUtilsMessengerCreateInfoEXT.make`'s callback/user-data
   arguments are `~pfn_user_callback`/`~p_user_data`, not the
   prefix-stripped `~user_callback`/`~user_data` that `DESIGN.md` §3's
   general rule would suggest.
7. **`PfnDebugUtilsMessengerCallbackEXT.opt` doesn't pass
   `~runtime_lock:true`** to `Foreign.funptr_opt`, unlike what `DESIGN.md`
   §8 says it should — see [Threading](#threading).
