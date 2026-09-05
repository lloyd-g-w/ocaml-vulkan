let get = Ctypes.getf

let print_layer layer =
  Printf.printf "  %s (spec %s, impl %s)\n"
    (Vk.LayerProperties.get_layer_name layer)
    (Vk.string_of_version (get layer Vk.LayerProperties.spec_version))
    (Vk.string_of_version (get layer Vk.LayerProperties.implementation_version))

let print_extension extension =
  Printf.printf "  %s (spec %d)\n"
    (Vk.ExtensionProperties.get_extension_name extension)
    (get extension Vk.ExtensionProperties.spec_version)

let print_memory memory =
  let heap_count = get memory Vk.PhysicalDeviceMemoryProperties.memory_heap_count in
  let heaps = get memory Vk.PhysicalDeviceMemoryProperties.memory_heaps in
  Printf.printf "  memory heaps: %d\n" heap_count;
  for i = 0 to heap_count - 1 do
    let heap = Ctypes.CArray.get heaps i in
    Printf.printf "    heap %d: %d bytes, %s\n" i
      (get heap Vk.MemoryHeap.size)
      (Vk.MemoryHeapFlags.to_string (get heap Vk.MemoryHeap.flags))
  done;
  let type_count = get memory Vk.PhysicalDeviceMemoryProperties.memory_type_count in
  let types = get memory Vk.PhysicalDeviceMemoryProperties.memory_types in
  Printf.printf "  memory types: %d\n" type_count;
  for i = 0 to type_count - 1 do
    let memory_type = Ctypes.CArray.get types i in
    Printf.printf "    type %d: heap %d, %s\n" i
      (get memory_type Vk.MemoryType.heap_index)
      (Vk.MemoryPropertyFlags.to_string
         (get memory_type Vk.MemoryType.property_flags))
  done

let print_device physical_device =
  let properties = Vk.get_physical_device_properties physical_device in
  let limits = get properties Vk.PhysicalDeviceProperties.limits in
  Printf.printf "\n%s\n" (Vk.PhysicalDeviceProperties.get_device_name properties);
  Printf.printf "  type: %s\n"
    (Vk.PhysicalDeviceType.to_string
       (get properties Vk.PhysicalDeviceProperties.device_type));
  Printf.printf "  API: %s; driver: %s\n"
    (Vk.string_of_version (get properties Vk.PhysicalDeviceProperties.api_version))
    (Vk.string_of_version (get properties Vk.PhysicalDeviceProperties.driver_version));
  Printf.printf "  limits: image2D=%d, uniform-buffer=%d, push-constants=%d\n"
    (get limits Vk.PhysicalDeviceLimits.max_image_dimension_2d)
    (get limits Vk.PhysicalDeviceLimits.max_uniform_buffer_range)
    (get limits Vk.PhysicalDeviceLimits.max_push_constants_size);
  print_memory (Vk.get_physical_device_memory_properties physical_device);
  let queues = Vk.get_physical_device_queue_family_properties physical_device in
  Printf.printf "  queue families: %d\n" (List.length queues);
  List.iteri
    (fun i queue ->
      Printf.printf "    queue %d: count=%d, %s\n" i
        (get queue Vk.QueueFamilyProperties.queue_count)
        (Vk.QueueFlags.to_string (get queue Vk.QueueFamilyProperties.queue_flags)))
    queues;
  let extensions = Vk.enumerate_device_extension_properties physical_device in
  Printf.printf "  device extensions: %d\n" (List.length extensions)

let () =
  let version = Vk.enumerate_instance_version () in
  Printf.printf "Vulkan instance version: %s\n" (Vk.string_of_version version);
  let layers = Vk.enumerate_instance_layer_properties () in
  Printf.printf "Instance layers: %d\n" (List.length layers);
  List.iter print_layer layers;
  let extensions = Vk.enumerate_instance_extension_properties () in
  Printf.printf "Instance extensions: %d\n" (List.length extensions);
  List.iter print_extension extensions;
  let application =
    Vk.ApplicationInfo.make ~application_name:"ocaml-vulkan vkinfo"
      ~api_version:Vk.api_version_1_4 ()
  in
  let create_info = Vk.InstanceCreateInfo.make ~application_info:application () in
  let instance = Vk.create_instance create_info in
  Fun.protect
    ~finally:(fun () -> Vk.destroy_instance instance ())
    (fun () -> List.iter print_device (Vk.enumerate_physical_devices instance))
