(* examples/compute.ml -- headless compute on lavapipe.

   Instance -> device -> a 1M-uint32 storage buffer -> a compute pipeline
   running shaders/double.comp (embedded via the vk_test_shaders library,
   see shaders/dune) -> dispatch -> fence wait -> read back and verify every
   element was doubled -> print timing.

   Run with:  dune exec examples/compute.exe *)

let get = Ctypes.getf

(* "1M" uint32 elements = 2^20 = 1,048,576 (4 MiB buffer); a round number
   that also divides evenly into shaders/double.comp's local_size_x=64. *)
let n_elements = 1 lsl 20
let local_size_x = 64 (* must match shaders/double.comp *)
let workgroups = (n_elements + local_size_x - 1) / local_size_x

let find_queue_family physical_device flags_wanted =
  Vk.get_physical_device_queue_family_properties physical_device
  |> List.mapi (fun i qf -> (i, qf))
  |> List.find_map (fun (i, qf) ->
         if Vk.QueueFlags.mem (get qf Vk.QueueFamilyProperties.queue_flags) flags_wanted then
           Some i
         else None)
  |> function
  | Some i -> i
  | None -> failwith "no queue family supports VK_QUEUE_COMPUTE_BIT"

let find_memory_type physical_device ~type_bits ~required_properties =
  let props = Vk.get_physical_device_memory_properties physical_device in
  let count = get props Vk.PhysicalDeviceMemoryProperties.memory_type_count in
  let types = get props Vk.PhysicalDeviceMemoryProperties.memory_types in
  let rec go i =
    if i >= count then failwith "no memory type has both HOST_VISIBLE and HOST_COHERENT"
    else
      let memory_type = Ctypes.CArray.get types i in
      let flags = get memory_type Vk.MemoryType.property_flags in
      if type_bits land (1 lsl i) <> 0 && Vk.MemoryPropertyFlags.mem flags required_properties then
        i
      else go (i + 1)
  in
  go 0

let () =
  let t_start = Unix.gettimeofday () in
  let application =
    Vk.ApplicationInfo.make ~application_name:"ocaml-vulkan compute" ~api_version:Vk.api_version_1_4 ()
  in
  let instance = Vk.create_instance (Vk.InstanceCreateInfo.make ~application_info:application ()) in
  let physical_device = List.hd (Vk.enumerate_physical_devices instance) in
  let device_name = Vk.PhysicalDeviceProperties.get_device_name (Vk.get_physical_device_properties physical_device) in
  let queue_family_index = find_queue_family physical_device Vk.QueueFlags.compute in
  let device =
    Vk.create_device physical_device
      (Vk.DeviceCreateInfo.make
         ~queue_create_infos:
           [ Vk.DeviceQueueCreateInfo.make ~queue_family_index ~queue_priorities:[ 1.0 ] () ]
         ())
  in
  let queue = Vk.get_device_queue device queue_family_index 0 in

  (* -- storage buffer: n_elements uint32s, host-visible so this example can
     fill/read it directly without a staging buffer. -- *)
  let buffer_bytes = n_elements * 4 in
  let buffer =
    Vk.create_buffer device
      (Vk.BufferCreateInfo.make ~size:buffer_bytes ~usage:Vk.BufferUsageFlags.storage_buffer
         ~sharing_mode:Vk.SharingMode.exclusive ())
  in
  let requirements = Vk.get_buffer_memory_requirements device buffer in
  let memory_type_index =
    find_memory_type physical_device
      ~type_bits:(get requirements Vk.MemoryRequirements.memory_type_bits)
      ~required_properties:Vk.MemoryPropertyFlags.(host_visible lor host_coherent)
  in
  let memory =
    Vk.allocate_memory device
      (Vk.MemoryAllocateInfo.make ~allocation_size:(get requirements Vk.MemoryRequirements.size)
         ~memory_type_index ())
  in
  Vk.bind_buffer_memory device buffer memory 0;
  let mapped = Vk.map_memory device memory 0 buffer_bytes Vk.MemoryMapFlags.empty in
  let words = Ctypes.(coerce (ptr void) (ptr uint32_t) mapped) in
  for i = 0 to n_elements - 1 do
    Ctypes.(words +@ i <-@ Unsigned.UInt32.of_int i)
  done;

  (* -- descriptor set layout: binding 0 = one storage buffer, compute
     stage. descriptor_count is independent of ~immutable_samplers (which
     we don't use here), so it's passed explicitly. -- *)
  let binding =
    Vk.DescriptorSetLayoutBinding.make ~binding:0 ~descriptor_type:Vk.DescriptorType.storage_buffer
      ~descriptor_count:1 ~stage_flags:Vk.ShaderStageFlags.compute ()
  in
  let descriptor_set_layout =
    Vk.create_descriptor_set_layout device (Vk.DescriptorSetLayoutCreateInfo.make ~bindings:[ binding ] ())
  in
  let pipeline_layout =
    Vk.create_pipeline_layout device (Vk.PipelineLayoutCreateInfo.make ~set_layouts:[ descriptor_set_layout ] ())
  in
  let shader_module =
    Vk.create_shader_module device (Vk.ShaderModuleCreateInfo.make ~code:Vk_test_shaders.double_comp ())
  in
  let stage =
    Vk.PipelineShaderStageCreateInfo.make ~stage:Vk.ShaderStageFlags.compute ~module_:shader_module
      ~name:"main" ()
  in

  (* create_compute_pipelines : Result.t * Pipeline.t list -- the Result.t
     is kept because VK_PIPELINE_COMPILE_REQUIRED_EXT is a success code
     (DESIGN.md §10); this example only asked for one pipeline, so take the
     head of the returned list. *)
  let _, pipelines =
    Vk.create_compute_pipelines device Vk.PipelineCache.null
      [ Vk.ComputePipelineCreateInfo.make ~stage ~layout:pipeline_layout () ]
  in
  let pipeline = List.hd pipelines in

  (* -- descriptor pool + set, bound to the buffer -- *)
  let pool =
    Vk.create_descriptor_pool device
      (Vk.DescriptorPoolCreateInfo.make ~max_sets:1
         ~pool_sizes:
           [ Vk.DescriptorPoolSize.make ~type_:Vk.DescriptorType.storage_buffer ~descriptor_count:1 () ]
         ())
  in
  let descriptor_set =
    List.hd
      (Vk.allocate_descriptor_sets device
         (Vk.DescriptorSetAllocateInfo.make ~descriptor_pool:pool ~set_layouts:[ descriptor_set_layout ] ()))
  in

  (* descriptor_count is derived automatically from the longest of
     ~image_info/~buffer_info/~texel_buffer_view -- here that's
     ~buffer_info, length 1. *)
  let write =
    Vk.WriteDescriptorSet.make ~dst_set:descriptor_set ~dst_binding:0 ~dst_array_element:0
      ~descriptor_type:Vk.DescriptorType.storage_buffer
      ~buffer_info:[ Vk.DescriptorBufferInfo.make ~buffer ~offset:0 ~range:Vk.whole_size () ]
      ()
  in
  Vk.update_descriptor_sets device [ write ] [];

  (* -- command buffer: bind, dispatch -- *)
  let command_pool = Vk.create_command_pool device (Vk.CommandPoolCreateInfo.make ~queue_family_index ()) in
  let cb =
    List.hd
      (Vk.allocate_command_buffers device
         (Vk.CommandBufferAllocateInfo.make ~command_pool ~level:Vk.CommandBufferLevel.primary
            ~command_buffer_count:1 ()))
  in
  Vk.begin_command_buffer cb (Vk.CommandBufferBeginInfo.make ());
  Vk.cmd_bind_pipeline cb Vk.PipelineBindPoint.compute pipeline;
  Vk.cmd_bind_descriptor_sets cb Vk.PipelineBindPoint.compute pipeline_layout 0 [ descriptor_set ] [];
  Vk.cmd_dispatch cb workgroups 1 1;
  Vk.end_command_buffer cb;

  let fence = Vk.create_fence device (Vk.FenceCreateInfo.make ()) in
  let t_dispatch = Unix.gettimeofday () in
  Vk.queue_submit queue [ Vk.SubmitInfo.make ~command_buffers:[ cb ] () ] fence;
  let wait_result = Vk.wait_for_fences device [ fence ] true 30_000_000_000 (* 30s, in ns *) in
  if not (Vk.Result.equal wait_result Vk.Result.success) then
    failwith (Printf.sprintf "vkWaitForFences: %s" (Vk.Result.to_string wait_result));
  let t_done = Unix.gettimeofday () in

  (* -- verify every element was doubled -- *)
  for i = 0 to n_elements - 1 do
    let got = Unsigned.UInt32.to_int Ctypes.(!@(words +@ i)) in
    if got <> i * 2 then failwith (Printf.sprintf "element %d: expected %d, got %d" i (i * 2) got)
  done;
  Vk.unmap_memory device memory;

  Vk.destroy_fence device fence ();
  Vk.destroy_command_pool device command_pool ();
  Vk.destroy_descriptor_pool device pool ();
  Vk.destroy_pipeline device pipeline ();
  Vk.destroy_pipeline_layout device pipeline_layout ();
  Vk.destroy_shader_module device shader_module ();
  Vk.destroy_descriptor_set_layout device descriptor_set_layout ();
  Vk.free_memory device memory ();
  Vk.destroy_buffer device buffer ();
  Vk.destroy_device device ();
  Vk.destroy_instance instance ();

  Printf.printf "compute: doubled %d uint32 elements on %s\n" n_elements device_name;
  Printf.printf "  dispatch: %d workgroups x %d threads = %d invocations\n" workgroups local_size_x
    (workgroups * local_size_x);
  Printf.printf "  GPU time (submit -> fence signalled): %.3f ms\n" ((t_done -. t_dispatch) *. 1000.);
  Printf.printf "  total wall time (incl. instance/device/buffer setup): %.3f ms\n"
    ((t_done -. t_start) *. 1000.)
