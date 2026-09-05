(* test_compute.ml -- double.comp on a 1024-element buffer: descriptor set
   layout, pipeline layout, compute pipeline, descriptor pool/set, command
   pool/buffer, dispatch 16 workgroups (1024 / local_size_x=64), fence wait,
   read back and check every element doubled. See DESIGN.md §12 and
   shaders/double.comp.

   Verified against the real generated API (integration lane):
   - `VkPipelineShaderStageCreateInfo.module`/`VkDescriptorPoolSize.type` do
     collide with the OCaml keywords `module`/`type` and are escaped exactly
     like enum values (DESIGN §3): raw fields/labels `module_`/`type_`.
   - `vkCreateComputePipelines`/`vkAllocateDescriptorSets`/
     `vkAllocateCommandBuffers` are the "output array length derived from
     inputs" wrapper shape (DESIGN §10): `create_compute_pipelines device
     cache infos : Result.t * Pipeline.t list` (the result is kept because
     VK_PIPELINE_COMPILE_REQUIRED_EXT is a success code);
     `allocate_descriptor_sets`/`allocate_command_buffers device info`
     return a plain `list` (no extra success codes, so no `Result.t`).
   - `Vk.wait_for_fences device fences wait_all timeout` positional, matching
     DESIGN §10's "successcodes contains anything other than VK_SUCCESS"
     rule (VK_TIMEOUT is a successcode) by returning `Result.t`. *)

module V = Vk

let n_elements = 1024
let buffer_bytes = n_elements * 4 (* uint32 *)
let local_size_x = 64
let workgroups = n_elements / local_size_x (* 16, matches DESIGN's dispatch *)

let find_queue_family pd flags_wanted =
  V.get_physical_device_queue_family_properties pd
  |> List.mapi (fun i qf -> (i, qf))
  |> List.find_opt (fun (_, qf) ->
         V.QueueFlags.mem (Ctypes.getf qf V.QueueFamilyProperties.queue_flags) flags_wanted)
  |> function
  | Some (i, _) -> i
  | None -> Alcotest.fail "no queue family supports the flags this test needs"

let find_memory_type mem_props ~type_bits ~required_properties =
  let count = Ctypes.getf mem_props V.PhysicalDeviceMemoryProperties.memory_type_count in
  let types = Ctypes.getf mem_props V.PhysicalDeviceMemoryProperties.memory_types in
  let rec go i =
    if i >= count then Alcotest.fail "no suitable memory type"
    else
      let mt = Ctypes.CArray.get types i in
      let flags = Ctypes.getf mt V.MemoryType.property_flags in
      if type_bits land (1 lsl i) <> 0 && V.MemoryPropertyFlags.mem flags required_properties then i
      else go (i + 1)
  in
  go 0

let test_compute_doubles_buffer () =
  let instance = V.create_instance (V.InstanceCreateInfo.make ()) in
  let pd = List.hd (V.enumerate_physical_devices instance) in
  let qfi = find_queue_family pd V.QueueFlags.compute in
  let device =
    V.create_device pd
      (V.DeviceCreateInfo.make
         ~queue_create_infos:
           [ V.DeviceQueueCreateInfo.make ~queue_family_index:qfi ~queue_priorities:[ 1.0 ] () ]
         ())
  in
  let queue = V.get_device_queue device qfi 0 in

  (* -- storage buffer + host-visible memory, filled with 0..1023 -- *)
  let buffer =
    V.create_buffer device
      (V.BufferCreateInfo.make ~size:buffer_bytes
         ~usage:V.BufferUsageFlags.storage_buffer ~sharing_mode:V.SharingMode.exclusive ())
  in
  let reqs = V.get_buffer_memory_requirements device buffer in
  let mem_props = V.get_physical_device_memory_properties pd in
  let memory_type_index =
    find_memory_type mem_props
      ~type_bits:(Ctypes.getf reqs V.MemoryRequirements.memory_type_bits)
      ~required_properties:V.MemoryPropertyFlags.(host_visible lor host_coherent)
  in
  let memory =
    V.allocate_memory device
      (V.MemoryAllocateInfo.make
         ~allocation_size:(Ctypes.getf reqs V.MemoryRequirements.size)
         ~memory_type_index ())
  in
  V.bind_buffer_memory device buffer memory 0;
  let mapped = V.map_memory device memory 0 buffer_bytes V.MemoryMapFlags.empty in
  let words = Ctypes.(coerce (ptr void) (ptr uint32_t) mapped) in
  for i = 0 to n_elements - 1 do
    Ctypes.(words +@ i <-@ Unsigned.UInt32.of_int i)
  done;

  (* -- descriptor set layout: binding 0 = storage buffer, compute stage -- *)
  let dsl =
    V.create_descriptor_set_layout device
      (V.DescriptorSetLayoutCreateInfo.make
         ~bindings:
           [ V.DescriptorSetLayoutBinding.make ~binding:0
               ~descriptor_type:V.DescriptorType.storage_buffer ~descriptor_count:1
               ~stage_flags:V.ShaderStageFlags.compute ()
           ]
         ())
  in
  let pipeline_layout =
    V.create_pipeline_layout device (V.PipelineLayoutCreateInfo.make ~set_layouts:[ dsl ] ())
  in
  let shader_module =
    V.create_shader_module device
      (V.ShaderModuleCreateInfo.make ~code:Vk_test_shaders.double_comp ())
  in
  let pipeline =
    let stage =
      V.PipelineShaderStageCreateInfo.make ~stage:V.ShaderStageFlags.compute
        ~module_:shader_module ~name:"main" ()
    in
    (* create_compute_pipelines returns (Result.t * Pipeline.t list): the
       result is kept because VK_PIPELINE_COMPILE_REQUIRED_EXT is a success
       code (DESIGN.md §10). *)
    let _, pipelines =
      V.create_compute_pipelines device V.PipelineCache.null
        [ V.ComputePipelineCreateInfo.make ~stage ~layout:pipeline_layout () ]
    in
    List.hd pipelines
  in

  (* -- descriptor pool/set, bound to the buffer -- *)
  let pool =
    V.create_descriptor_pool device
      (V.DescriptorPoolCreateInfo.make ~max_sets:1
         ~pool_sizes:
           [ V.DescriptorPoolSize.make ~type_:V.DescriptorType.storage_buffer ~descriptor_count:1 () ]
         ())
  in
  let descriptor_set =
    List.hd
      (V.allocate_descriptor_sets device
         (V.DescriptorSetAllocateInfo.make ~descriptor_pool:pool ~set_layouts:[ dsl ] ()))
  in
  V.update_descriptor_sets device
    [ V.WriteDescriptorSet.make ~dst_set:descriptor_set ~dst_binding:0 ~dst_array_element:0
        ~descriptor_type:V.DescriptorType.storage_buffer
        ~buffer_info:
          [ V.DescriptorBufferInfo.make ~buffer ~offset:0 ~range:V.whole_size () ]
        ()
    ]
    [];

  (* -- command buffer: bind, dispatch 16 workgroups -- *)
  let command_pool =
    V.create_command_pool device (V.CommandPoolCreateInfo.make ~queue_family_index:qfi ())
  in
  let cb =
    List.hd
      (V.allocate_command_buffers device
         (V.CommandBufferAllocateInfo.make ~command_pool ~level:V.CommandBufferLevel.primary
            ~command_buffer_count:1 ()))
  in
  V.begin_command_buffer cb (V.CommandBufferBeginInfo.make ());
  V.cmd_bind_pipeline cb V.PipelineBindPoint.compute pipeline;
  V.cmd_bind_descriptor_sets cb V.PipelineBindPoint.compute pipeline_layout 0 [ descriptor_set ] [];
  V.cmd_dispatch cb workgroups 1 1;
  V.end_command_buffer cb;

  let fence = V.create_fence device (V.FenceCreateInfo.make ()) in
  V.queue_submit queue [ V.SubmitInfo.make ~command_buffers:[ cb ] () ] fence;
  let wait_result = V.wait_for_fences device [ fence ] true 5_000_000_000 (* 5s, in ns *) in
  Alcotest.(check bool) "fence signalled before the 5s timeout" true
    (V.Result.equal wait_result V.Result.success);

  for i = 0 to n_elements - 1 do
    let got = Unsigned.UInt32.to_int (Ctypes.(!@(words +@ i))) in
    if got <> i * 2 then Alcotest.failf "element %d: expected %d, got %d" i (i * 2) got
  done;

  V.destroy_fence device fence ();
  V.destroy_command_pool device command_pool ();
  V.destroy_descriptor_pool device pool ();
  V.destroy_pipeline device pipeline ();
  V.destroy_pipeline_layout device pipeline_layout ();
  V.destroy_descriptor_set_layout device dsl ();
  V.destroy_shader_module device shader_module ();
  V.unmap_memory device memory;
  V.free_memory device memory ();
  V.destroy_buffer device buffer ();
  V.destroy_device device ();
  V.destroy_instance instance ()

let suite : unit Alcotest.test_case list =
  [ Alcotest.test_case "double.comp doubles a 1024-element buffer" `Quick
      test_compute_doubles_buffer ]
