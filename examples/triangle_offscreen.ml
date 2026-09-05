(* examples/triangle_offscreen.ml -- headless graphics on lavapipe.

   Instance -> device -> a 512x512 R8G8B8A8_UNORM colour image -> a render
   pass + graphics pipeline (fixed viewport/scissor, no vertex buffers --
   shaders/triangle.vert hard-codes 3 vertices) -> draw -> transition the
   image to TRANSFER_SRC -> copy to a host-visible buffer -> write
   triangle.ppm (binary PPM, P6).

   Run with:  dune exec examples/triangle_offscreen.exe
   Then:      head -c 20 triangle.ppm | xxd | head -2

   This file works around one generator bug (Vk.SubpassDescription.make
   silently zeroes colorAttachmentCount unless you also pass
   ~resolve_attachments) and reuses the create_*_pipelines output-pointer
   workaround from examples/compute.ml. See the handoff report for the
   precise bug reports (file, symptom, minimal repro). *)

let get = Ctypes.getf

let width = 512
let height = 512
let format = Vk.Format.r8g8b8a8_unorm
let clear_color = (0.0, 0.0, 0.0, 1.0) (* pure black, so "non-black" checks below are meaningful *)
let output_file = "triangle.ppm"

let find_queue_family physical_device flags_wanted =
  Vk.get_physical_device_queue_family_properties physical_device
  |> List.mapi (fun i qf -> (i, qf))
  |> List.find_map (fun (i, qf) ->
         if Vk.QueueFlags.mem (get qf Vk.QueueFamilyProperties.queue_flags) flags_wanted then
           Some i
         else None)
  |> function
  | Some i -> i
  | None -> failwith "no queue family supports VK_QUEUE_GRAPHICS_BIT"

let find_memory_type physical_device ~type_bits ~required_properties =
  let props = Vk.get_physical_device_memory_properties physical_device in
  let count = get props Vk.PhysicalDeviceMemoryProperties.memory_type_count in
  let types = get props Vk.PhysicalDeviceMemoryProperties.memory_types in
  let rec go i =
    if i >= count then failwith "no suitable memory type"
    else
      let memory_type = Ctypes.CArray.get types i in
      let flags = get memory_type Vk.MemoryType.property_flags in
      if type_bits land (1 lsl i) <> 0 && Vk.MemoryPropertyFlags.mem flags required_properties then
        i
      else go (i + 1)
  in
  go 0

let () =
  let application =
    Vk.ApplicationInfo.make ~application_name:"ocaml-vulkan triangle_offscreen"
      ~api_version:Vk.api_version_1_4 ()
  in
  let instance = Vk.create_instance (Vk.InstanceCreateInfo.make ~application_info:application ()) in
  let physical_device = List.hd (Vk.enumerate_physical_devices instance) in
  let queue_family_index = find_queue_family physical_device Vk.QueueFlags.graphics in
  let device =
    Vk.create_device physical_device
      (Vk.DeviceCreateInfo.make
         ~queue_create_infos:
           [ Vk.DeviceQueueCreateInfo.make ~queue_family_index ~queue_priorities:[ 1.0 ] () ]
         ())
  in
  let queue = Vk.get_device_queue device queue_family_index 0 in

  (* -- colour attachment image -- *)
  let image =
    Vk.create_image device
      (Vk.ImageCreateInfo.make ~image_type:Vk.ImageType._2d ~format
         ~extent:(Vk.Extent3D.make ~width ~height ~depth:1 ())
         ~mip_levels:1 ~array_layers:1 ~samples:Vk.SampleCountFlags._1 ~tiling:Vk.ImageTiling.optimal
         ~usage:Vk.ImageUsageFlags.(color_attachment lor transfer_src)
         ~sharing_mode:Vk.SharingMode.exclusive ~initial_layout:Vk.ImageLayout.undefined ())
  in
  let image_requirements = Vk.get_image_memory_requirements device image in
  let image_memory =
    Vk.allocate_memory device
      (Vk.MemoryAllocateInfo.make
         ~allocation_size:(get image_requirements Vk.MemoryRequirements.size)
         ~memory_type_index:
           (find_memory_type physical_device
              ~type_bits:(get image_requirements Vk.MemoryRequirements.memory_type_bits)
              ~required_properties:Vk.MemoryPropertyFlags.device_local)
         ())
  in
  Vk.bind_image_memory device image image_memory 0;
  let subresource_range =
    Vk.ImageSubresourceRange.make ~aspect_mask:Vk.ImageAspectFlags.color ~base_mip_level:0
      ~level_count:1 ~base_array_layer:0 ~layer_count:1 ()
  in
  let image_view =
    Vk.create_image_view device
      (Vk.ImageViewCreateInfo.make ~image ~view_type:Vk.ImageViewType._2d ~format
         ~components:(Vk.ComponentMapping.make ()) ~subresource_range ())
  in

  (* -- render pass: one colour attachment, one subpass -- *)
  let color_attachments = [ Vk.AttachmentReference.make ~attachment:0 ~layout:Vk.ImageLayout.color_attachment_optimal () ] in
  let subpass =
    let s =
      Vk.SubpassDescription.make ~pipeline_bind_point:Vk.PipelineBindPoint.graphics ~color_attachments ()
    in
    (* WORKAROUND (library bug -- see handoff report): Vk.SubpassDescription.make
       sets colorAttachmentCount from List.length ~resolve_attachments, not
       ~color_attachments -- VkSubpassDescription has *two* pointer members
       (pColorAttachments, pResolveAttachments) that both declare
       len="colorAttachmentCount" in vk.xml, and the generator's
       "count field <- List.length of the array that names it" rule only
       keeps the mapping from the last member it processes. Since this
       example (like almost every render pass without MSAA) has no resolve
       attachments, ~resolve_attachments defaults to [] and
       colorAttachmentCount would silently come out as 0 -- meaning the
       fragment shader would be rendering to no attachments at all. Patch
       the field by hand to the real ~color_attachments length. *)
    Ctypes.setf s Vk.SubpassDescription.color_attachment_count (List.length color_attachments);
    s
  in
  let render_pass =
    Vk.create_render_pass device
      (Vk.RenderPassCreateInfo.make
         ~attachments:
           [ Vk.AttachmentDescription.make ~format ~samples:Vk.SampleCountFlags._1
               ~load_op:Vk.AttachmentLoadOp.clear ~store_op:Vk.AttachmentStoreOp.store
               ~stencil_load_op:Vk.AttachmentLoadOp.dont_care
               ~stencil_store_op:Vk.AttachmentStoreOp.dont_care ~initial_layout:Vk.ImageLayout.undefined
               ~final_layout:Vk.ImageLayout.color_attachment_optimal ()
           ]
         ~subpasses:[ subpass ] ())
  in
  let framebuffer =
    Vk.create_framebuffer device
      (Vk.FramebufferCreateInfo.make ~render_pass ~attachments:[ image_view ] ~width ~height ~layers:1 ())
  in

  (* -- graphics pipeline: triangle.vert/frag (3 hard-coded vertices, no
     vertex buffers), fixed 512x512 viewport/scissor, no blending -- *)
  let vert_module =
    Vk.create_shader_module device (Vk.ShaderModuleCreateInfo.make ~code:Vk_test_shaders.triangle_vert ())
  in
  let frag_module =
    Vk.create_shader_module device (Vk.ShaderModuleCreateInfo.make ~code:Vk_test_shaders.triangle_frag ())
  in
  let pipeline_layout = Vk.create_pipeline_layout device (Vk.PipelineLayoutCreateInfo.make ()) in
  let stages =
    [ Vk.PipelineShaderStageCreateInfo.make ~stage:Vk.ShaderStageFlags.vertex ~module_:vert_module
        ~name:"main" ();
      Vk.PipelineShaderStageCreateInfo.make ~stage:Vk.ShaderStageFlags.fragment ~module_:frag_module
        ~name:"main" ()
    ]
  in
  let vertex_input_state = Vk.PipelineVertexInputStateCreateInfo.make () in
  let input_assembly_state =
    Vk.PipelineInputAssemblyStateCreateInfo.make ~topology:Vk.PrimitiveTopology.triangle_list ()
  in
  let viewport_state =
    Vk.PipelineViewportStateCreateInfo.make
      ~viewports:
        [ Vk.Viewport.make ~x:0. ~y:0. ~width:(float_of_int width) ~height:(float_of_int height)
            ~min_depth:0. ~max_depth:1. ()
        ]
      ~scissors:
        [ Vk.Rect2D.make ~offset:(Vk.Offset2D.make ~x:0 ~y:0 ()) ~extent:(Vk.Extent2D.make ~width ~height ()) () ]
      ()
  in
  let rasterization_state =
    Vk.PipelineRasterizationStateCreateInfo.make ~polygon_mode:Vk.PolygonMode.fill
      ~cull_mode:Vk.CullModeFlags.none ~front_face:Vk.FrontFace.counter_clockwise ~line_width:1.0 ()
  in
  let multisample_state =
    Vk.PipelineMultisampleStateCreateInfo.make ~rasterization_samples:Vk.SampleCountFlags._1 ()
  in
  let color_blend_state =
    Vk.PipelineColorBlendStateCreateInfo.make
      ~attachments:
        [ Vk.PipelineColorBlendAttachmentState.make
            ~color_write_mask:Vk.ColorComponentFlags.(r lor g lor b lor a) ()
        ]
      ()
  in
  (* Same create_*_pipelines output-pointer shape as examples/compute.ml. *)
  let pipelines = Ctypes.allocate_n Vk.Pipeline.t ~count:1 in
  let (_ : Vk.Result.t) =
    Vk.create_graphics_pipelines device Vk.PipelineCache.null
      [ Vk.GraphicsPipelineCreateInfo.make ~stages ~vertex_input_state ~input_assembly_state ~viewport_state
          ~rasterization_state ~multisample_state ~color_blend_state ~layout:pipeline_layout ~render_pass
          ~subpass:0 ()
      ]
      pipelines
  in
  let pipeline = Ctypes.( !@ ) pipelines in

  (* -- host-visible readback buffer (tightly packed RGBA8) -- *)
  let readback_size = width * height * 4 in
  let readback_buffer =
    Vk.create_buffer device
      (Vk.BufferCreateInfo.make ~size:readback_size ~usage:Vk.BufferUsageFlags.transfer_dst
         ~sharing_mode:Vk.SharingMode.exclusive ())
  in
  let readback_requirements = Vk.get_buffer_memory_requirements device readback_buffer in
  let readback_memory =
    Vk.allocate_memory device
      (Vk.MemoryAllocateInfo.make
         ~allocation_size:(get readback_requirements Vk.MemoryRequirements.size)
         ~memory_type_index:
           (find_memory_type physical_device
              ~type_bits:(get readback_requirements Vk.MemoryRequirements.memory_type_bits)
              ~required_properties:Vk.MemoryPropertyFlags.(host_visible lor host_coherent))
         ())
  in
  Vk.bind_buffer_memory device readback_buffer readback_memory 0;

  let command_pool = Vk.create_command_pool device (Vk.CommandPoolCreateInfo.make ~queue_family_index ()) in
  let command_buffers = Ctypes.allocate_n Vk.CommandBuffer.t ~count:1 in
  Vk.allocate_command_buffers device
    (Vk.CommandBufferAllocateInfo.make ~command_pool ~level:Vk.CommandBufferLevel.primary
       ~command_buffer_count:1 ())
    command_buffers;
  let cb = Ctypes.( !@ ) command_buffers in

  Vk.begin_command_buffer cb (Vk.CommandBufferBeginInfo.make ());
  let cr, cg, cb_, ca = clear_color in
  Vk.cmd_begin_render_pass cb
    (Vk.RenderPassBeginInfo.make ~render_pass ~framebuffer
       ~render_area:
         (Vk.Rect2D.make ~offset:(Vk.Offset2D.make ~x:0 ~y:0 ()) ~extent:(Vk.Extent2D.make ~width ~height ()) ())
       ~clear_values:[ Vk.ClearValue.color (Vk.ClearColorValue.float32 [ cr; cg; cb_; ca ]) ]
       ())
    Vk.SubpassContents.inline;
  Vk.cmd_bind_pipeline cb Vk.PipelineBindPoint.graphics pipeline;
  Vk.cmd_draw cb 3 1 0 0;
  Vk.cmd_end_render_pass cb;
  Vk.cmd_pipeline_barrier cb Vk.PipelineStageFlags.color_attachment_output Vk.PipelineStageFlags.transfer
    Vk.DependencyFlags.empty [] []
    [ Vk.ImageMemoryBarrier.make ~src_access_mask:Vk.AccessFlags.color_attachment_write
        ~dst_access_mask:Vk.AccessFlags.transfer_read ~old_layout:Vk.ImageLayout.color_attachment_optimal
        ~new_layout:Vk.ImageLayout.transfer_src_optimal ~src_queue_family_index:Vk.queue_family_ignored
        ~dst_queue_family_index:Vk.queue_family_ignored ~image ~subresource_range ()
    ];
  Vk.cmd_copy_image_to_buffer cb image Vk.ImageLayout.transfer_src_optimal readback_buffer
    [ Vk.BufferImageCopy.make ~buffer_offset:0 ~buffer_row_length:0 ~buffer_image_height:0
        ~image_subresource:
          (Vk.ImageSubresourceLayers.make ~aspect_mask:Vk.ImageAspectFlags.color ~mip_level:0
             ~base_array_layer:0 ~layer_count:1 ())
        ~image_offset:(Vk.Offset3D.make ~x:0 ~y:0 ~z:0 ())
        ~image_extent:(Vk.Extent3D.make ~width ~height ~depth:1 ())
        ()
    ];
  Vk.end_command_buffer cb;

  let fence = Vk.create_fence device (Vk.FenceCreateInfo.make ()) in
  Vk.queue_submit queue [ Vk.SubmitInfo.make ~command_buffers:[ cb ] () ] fence;
  let wait_result = Vk.wait_for_fences device [ fence ] true 30_000_000_000 (* 30s, in ns *) in
  if not (Vk.Result.equal wait_result Vk.Result.success) then
    failwith (Printf.sprintf "vkWaitForFences: %s" (Vk.Result.to_string wait_result));

  (* -- read back, sanity-check, and write the PPM -- *)
  let pixels_ptr = Vk.map_memory device readback_memory 0 readback_size Vk.MemoryMapFlags.empty in
  let bytes = Ctypes.(coerce (ptr void) (ptr uint8_t)) pixels_ptr in
  let pixel_at x y =
    let o = ((y * width) + x) * 4 in
    let byte k = Unsigned.UInt8.to_int Ctypes.(!@(bytes +@ (o + k))) in
    (byte 0, byte 1, byte 2, byte 3)
  in
  let center_r, center_g, center_b, _ = pixel_at (width / 2) (height / 2) in
  let corner_r, corner_g, corner_b, _ = pixel_at 0 0 in
  if not (center_r > 0 || center_g > 0 || center_b > 0) then
    failwith "centre pixel is black -- the triangle did not render";
  Printf.printf "triangle_offscreen: %dx%d, centre pixel = (%d,%d,%d), corner pixel = (%d,%d,%d)\n" width
    height center_r center_g center_b corner_r corner_g corner_b;

  let out = open_out_bin output_file in
  let header = Printf.sprintf "P6\n%d %d\n255\n" width height in
  output_string out header;
  let row = Bytes.create (width * 3) in
  for y = 0 to height - 1 do
    for x = 0 to width - 1 do
      let r, g, b, _ = pixel_at x y in
      Bytes.set row (x * 3) (Char.chr r);
      Bytes.set row ((x * 3) + 1) (Char.chr g);
      Bytes.set row ((x * 3) + 2) (Char.chr b)
    done;
    output_bytes out row
  done;
  close_out out;
  Vk.unmap_memory device readback_memory;

  Vk.destroy_fence device fence ();
  Vk.destroy_command_pool device command_pool ();
  Vk.destroy_pipeline device pipeline ();
  Vk.destroy_pipeline_layout device pipeline_layout ();
  Vk.destroy_shader_module device frag_module ();
  Vk.destroy_shader_module device vert_module ();
  Vk.destroy_framebuffer device framebuffer ();
  Vk.destroy_render_pass device render_pass ();
  Vk.destroy_image_view device image_view ();
  Vk.free_memory device image_memory ();
  Vk.destroy_image device image ();
  Vk.free_memory device readback_memory ();
  Vk.destroy_buffer device readback_buffer ();
  Vk.destroy_device device ();
  Vk.destroy_instance instance ();

  Printf.printf "wrote %s (%d bytes)\n" output_file (String.length header + (width * height * 3))
