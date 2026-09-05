let get = Ctypes.getf

let collect () = Gc.full_major ()

let find_queue_family physical_device =
  Vk.get_physical_device_queue_family_properties physical_device
  |> List.mapi (fun index properties -> index, properties)
  |> List.find_map (fun (index, properties) ->
         if get properties Vk.QueueFamilyProperties.queue_count > 0 then Some index
         else None)
  |> Option.get

let find_memory_type physical_device type_bits =
  let memory = Vk.get_physical_device_memory_properties physical_device in
  let count = get memory Vk.PhysicalDeviceMemoryProperties.memory_type_count in
  let types = get memory Vk.PhysicalDeviceMemoryProperties.memory_types in
  let rec find coherent i =
    if i = count then None
    else
      let memory_type = Ctypes.CArray.get types i in
      let flags = get memory_type Vk.MemoryType.property_flags in
      let allowed = type_bits land (1 lsl i) <> 0 in
      let visible = Vk.MemoryPropertyFlags.mem flags Vk.MemoryPropertyFlags.host_visible in
      let has_coherency = Vk.MemoryPropertyFlags.mem flags Vk.MemoryPropertyFlags.host_coherent in
      if allowed && visible && (not coherent || has_coherency) then Some i
      else find coherent (i + 1)
  in
  match find true 0 with Some index -> index | None -> Option.get (find false 0)

let () =
  let application =
    Vk.ApplicationInfo.make ~application_name:"ocaml-vulkan smoke"
      ~api_version:Vk.api_version_1_4 ()
  in
  let instance_info = Vk.InstanceCreateInfo.make ~application_info:application () in
  collect ();
  let instance = Vk.create_instance instance_info in
  collect ();
  let physical_device = List.hd (Vk.enumerate_physical_devices instance) in
  let queue_family_index = find_queue_family physical_device in
  let queue_info =
    Vk.DeviceQueueCreateInfo.make ~queue_family_index ~queue_priorities:[ 1.0 ] ()
  in
  let device_info = Vk.DeviceCreateInfo.make ~queue_create_infos:[ queue_info ] () in
  collect ();
  let device = Vk.create_device physical_device device_info in
  collect ();
  let queue = Vk.get_device_queue device queue_family_index 0 in
  if Vk.Queue.is_null queue then failwith "vkGetDeviceQueue returned NULL";
  let buffer_info =
    Vk.BufferCreateInfo.make ~size:4096
      ~usage:Vk.BufferUsageFlags.transfer_src
      ~sharing_mode:Vk.SharingMode.exclusive ()
  in
  collect ();
  let buffer = Vk.create_buffer device buffer_info in
  collect ();
  let requirements = Vk.get_buffer_memory_requirements device buffer in
  let allocation_size = get requirements Vk.MemoryRequirements.size in
  let type_bits = get requirements Vk.MemoryRequirements.memory_type_bits in
  let memory_type_index = find_memory_type physical_device type_bits in
  let allocation_info =
    Vk.MemoryAllocateInfo.make ~allocation_size ~memory_type_index ()
  in
  collect ();
  let memory = Vk.allocate_memory device allocation_info in
  collect ();
  Vk.bind_buffer_memory device buffer memory 0;
  collect ();
  let mapped = Vk.map_memory device memory 0 allocation_size Vk.MemoryMapFlags.empty in
  collect ();
  Ctypes.(from_voidp char mapped <-@ '\x2a');
  Vk.unmap_memory device memory;
  collect ();
  Vk.destroy_buffer device buffer ();
  Vk.free_memory device memory ();
  Vk.destroy_device device ();
  Vk.destroy_instance instance ();
  collect ();
  Printf.printf "smoke: buffer allocation and map succeeded (queue %d)\n"
    queue_family_index
