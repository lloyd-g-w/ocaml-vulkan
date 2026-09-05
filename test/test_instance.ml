(* test_instance.ml -- instance -> physical devices -> properties/queue
   families/memory props -> device -> buffer + memory bind + map/unmap. Runs
   headless against lavapipe (VK_ICD_FILENAMES, see DESIGN.md §12 / README).

   TODO(integration lane) -- cannot compile yet (no lib/vk.ml content).
   Written directly against DESIGN.md §7/§9/§10 and its worked example.
   Assumptions (please double check against the real generated API):
   - Commands whose only "special" input is a single create-info struct take
     it positionally with `?allocator` available but unused here, e.g.
     `Vk.create_buffer device buffer_create_info : Buffer.t`,
     `Vk.allocate_memory device alloc_info : DeviceMemory.t` -- mirrors
     DESIGN §10's `Vk.create_instance ci` / `Vk.create_device pd dci`.
   - Plain-int/handle/enum parameters with no struct/count involved stay
     positional in raw parameter order, e.g.
     `Vk.bind_buffer_memory device buffer memory offset`,
     `Vk.map_memory device memory offset size flags : unit Ctypes.ptr`,
     `Vk.get_device_queue device queue_family_index queue_index : Queue.t`
     -- mirrors DESIGN §10's `Vk.cmd_bind_vertex_buffers cb 0 [vbuf] [0]`.
   - `Vk.get_physical_device_memory_properties pd` returns the struct
     directly (trailing output pointer, allocated+returned) because
     VkPhysicalDeviceMemoryProperties has no sType (not part of a pNext
     chain), unlike the sType-bearing structs DESIGN §10 carves out as an
     exception ("Output structs that have sType are instead taken as an
     argument").
   - Fixed-size struct-array members (`VkMemoryType memoryTypes[..]`) are
     reachable as an `X.t Ctypes.structure Ctypes.CArray.t` through the raw
     field accessor, standard ctypes behaviour for embedded array fields
     (DESIGN §7 guarantees the raw field exists; it doesn't special-case
     arrays of structs beyond the `make`-argument table, which is about
     input construction, not reading a returned struct).
   - `Vk.destroy_*` / `Vk.free_memory` take `?allocator` + the handle,
     returning `unit`, per DESIGN §10's `Vk.destroy_device device ()`. *)

module V = Vk

let create_test_instance () =
  let app_info =
    V.ApplicationInfo.make ~application_name:"vk-lanes-harness"
      ~api_version:V.api_version_1_3 ()
  in
  let ci = V.InstanceCreateInfo.make ~application_info:app_info () in
  V.create_instance ci

(* vkPhysicalDeviceMemoryProperties.memoryTypes/memoryHeaps are fixed-size C
   arrays; only the first memory_type_count/memory_heap_count entries are
   meaningful (DESIGN §4/§7 raw field access). *)
let memory_types props =
  let count = Ctypes.getf props V.PhysicalDeviceMemoryProperties.memory_type_count in
  let arr = Ctypes.getf props V.PhysicalDeviceMemoryProperties.memory_types in
  List.init count (fun i -> Ctypes.CArray.get arr i)

let find_memory_type props ~type_bits ~required_properties =
  memory_types props
  |> List.mapi (fun i mt -> (i, mt))
  |> List.find_opt (fun (i, mt) ->
         let bit_set = type_bits land (1 lsl i) <> 0 in
         let flags = Ctypes.getf mt V.MemoryType.property_flags in
         bit_set && V.MemoryPropertyFlags.(mem flags required_properties))
  |> Option.map fst

let test_instance_device_buffer_lifecycle () =
  let instance = create_test_instance () in
  let physical_devices = V.enumerate_physical_devices instance in
  Alcotest.(check bool) "at least one physical device (lavapipe)" true
    (physical_devices <> []);
  let pd = List.hd physical_devices in

  let props = V.get_physical_device_properties pd in
  Alcotest.(check bool) "device name is non-empty" true
    (String.length (V.PhysicalDeviceProperties.get_device_name props) > 0);
  Alcotest.(check bool) "apiVersion is set" true
    (Ctypes.getf props V.PhysicalDeviceProperties.api_version > 0);

  let queue_families = V.get_physical_device_queue_family_properties pd in
  Alcotest.(check bool) "at least one queue family" true (queue_families <> []);
  let queue_family_index =
    match
      List.mapi (fun i qf -> (i, qf)) queue_families
      |> List.find_opt (fun (_, qf) ->
             let flags = Ctypes.getf qf V.QueueFamilyProperties.queue_flags in
             V.QueueFlags.(mem flags graphics || mem flags compute))
    with
    | Some (i, _) -> i
    | None -> Alcotest.fail "no graphics/compute queue family"
  in

  let mem_props = V.get_physical_device_memory_properties pd in

  let device =
    let queue_ci =
      V.DeviceQueueCreateInfo.make ~queue_family_index ~queue_priorities:[ 1.0 ] ()
    in
    V.create_device pd (V.DeviceCreateInfo.make ~queue_create_infos:[ queue_ci ] ())
  in
  let queue = V.get_device_queue device queue_family_index 0 in
  ignore queue;

  let buffer_size = 256 in
  let buffer =
    V.create_buffer device
      (V.BufferCreateInfo.make ~size:buffer_size
         ~usage:V.BufferUsageFlags.(transfer_src lor transfer_dst)
         ~sharing_mode:V.SharingMode.exclusive ())
  in
  let reqs = V.get_buffer_memory_requirements device buffer in
  let type_bits = Ctypes.getf reqs V.MemoryRequirements.memory_type_bits in
  let alloc_size = Ctypes.getf reqs V.MemoryRequirements.size in
  let memory_type_index =
    match
      find_memory_type mem_props ~type_bits
        ~required_properties:V.MemoryPropertyFlags.(host_visible lor host_coherent)
    with
    | Some i -> i
    | None -> Alcotest.fail "no host-visible+host-coherent memory type fits this buffer"
  in
  let memory =
    V.allocate_memory device
      (V.MemoryAllocateInfo.make ~allocation_size:alloc_size ~memory_type_index ())
  in
  V.bind_buffer_memory device buffer memory 0;

  let p = V.map_memory device memory 0 buffer_size V.MemoryMapFlags.empty in
  let words = Ctypes.(coerce (ptr void) (ptr uint32_t) p) in
  for i = 0 to (buffer_size / 4) - 1 do
    Ctypes.(words +@ i <-@ Unsigned.UInt32.of_int (i * 7))
  done;
  for i = 0 to (buffer_size / 4) - 1 do
    Alcotest.(check int32) "mapped memory round-trips"
      (Int32.of_int (i * 7))
      (Unsigned.UInt32.to_int32 Ctypes.(!@(words +@ i)))
  done;
  V.unmap_memory device memory;

  V.destroy_buffer device buffer ();
  V.free_memory device memory ();
  V.destroy_device device ();
  V.destroy_instance instance ()

let suite : unit Alcotest.test_case list =
  [ Alcotest.test_case
      "instance -> physical device -> properties/queues/memory -> device -> buffer+memory"
      `Quick test_instance_device_buffer_lifecycle ]
