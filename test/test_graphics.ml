(* test_graphics.ml -- offscreen render: 64x64 R8G8B8A8_UNORM colour image +
   memory, image view, render pass, framebuffer, graphics pipeline from
   triangle.vert/frag with a fixed viewport/scissor, draw 3 vertices, layout
   transition to TRANSFER_SRC, copy image to a host buffer, check the centre
   pixel is non-black and a corner pixel equals the clear colour. See
   DESIGN.md §12 and shaders/triangle.{vert,frag}.

   TODO(integration lane) -- cannot compile yet (no lib/vk.ml content).
   Written directly against DESIGN.md; same batch-create-returns-a-list and
   `module`/`type` keyword-escape assumptions as test_compute.ml's TODO block
   (search FIXME below). Additional assumptions:
   - `Vk.cmd_pipeline_barrier cb src_stage dst_stage dependency_flags
      memory_barriers buffer_memory_barriers image_memory_barriers` -- three
     independent `count+array` groups become three positional list
     arguments, in the raw parameter order.
   - `Vk.queue_family_ignored` exists per DESIGN §3's constant-naming rule
     (`VK_QUEUE_FAMILY_IGNORED` -> `Vk.queue_family_ignored`), used for the
     image barrier's (unused, no ownership transfer) queue family indices.
   - triangle.vert's 3 hard-coded vertices (see shaders/triangle.vert) cover
     the centre of the 64x64 viewport but not the (0,0) corner, so a
     TRANSFER_SRC copy back to a host buffer should show the triangle colour
     at the centre texel and the untouched clear colour at the (0,0) corner
     texel -- this matches the task's stated check exactly. *)

module V = Vk

let width = 64
let height = 64
let format = V.Format.r8g8b8a8_unorm
let clear_color = (0.1, 0.2, 0.3, 1.0)

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

let test_offscreen_triangle () =
  let instance = V.create_instance (V.InstanceCreateInfo.make ()) in
  let pd = List.hd (V.enumerate_physical_devices instance) in
  let qfi = find_queue_family pd V.QueueFlags.graphics in
  let device =
    V.create_device pd
      (V.DeviceCreateInfo.make
         ~queue_create_infos:
           [ V.DeviceQueueCreateInfo.make ~queue_family_index:qfi ~queue_priorities:[ 1.0 ] () ]
         ())
  in
  let queue = V.get_device_queue device qfi 0 in
  let mem_props = V.get_physical_device_memory_properties pd in

  (* -- colour attachment image -- *)
  let image =
    V.create_image device
      (V.ImageCreateInfo.make ~image_type:V.ImageType._2d ~format
         ~extent:(V.Extent3D.make ~width ~height ~depth:1 ())
         ~mip_levels:1 ~array_layers:1 ~samples:V.SampleCountFlags._1
         ~tiling:V.ImageTiling.optimal
         ~usage:V.ImageUsageFlags.(color_attachment lor transfer_src)
         ~sharing_mode:V.SharingMode.exclusive ~initial_layout:V.ImageLayout.undefined ())
  in
  let image_reqs = V.get_image_memory_requirements device image in
  let image_memory =
    V.allocate_memory device
      (V.MemoryAllocateInfo.make
         ~allocation_size:(Ctypes.getf image_reqs V.MemoryRequirements.size)
         ~memory_type_index:
           (find_memory_type mem_props
              ~type_bits:(Ctypes.getf image_reqs V.MemoryRequirements.memory_type_bits)
              ~required_properties:V.MemoryPropertyFlags.device_local)
         ())
  in
  V.bind_image_memory device image image_memory 0;
  let subresource_range =
    V.ImageSubresourceRange.make ~aspect_mask:V.ImageAspectFlags.color ~base_mip_level:0
      ~level_count:1 ~base_array_layer:0 ~layer_count:1 ()
  in
  let image_view =
    V.create_image_view device
      (V.ImageViewCreateInfo.make ~image ~view_type:V.ImageViewType._2d ~format
         ~components:(V.ComponentMapping.make ()) ~subresource_range ())
  in

  (* -- render pass + framebuffer -- *)
  let render_pass =
    V.create_render_pass device
      (V.RenderPassCreateInfo.make
         ~attachments:
           [ V.AttachmentDescription.make ~format ~samples:V.SampleCountFlags._1
               ~load_op:V.AttachmentLoadOp.clear ~store_op:V.AttachmentStoreOp.store
               ~stencil_load_op:V.AttachmentLoadOp.dont_care
               ~stencil_store_op:V.AttachmentStoreOp.dont_care
               ~initial_layout:V.ImageLayout.undefined
               ~final_layout:V.ImageLayout.color_attachment_optimal ()
           ]
         ~subpasses:
           [ V.SubpassDescription.make ~pipeline_bind_point:V.PipelineBindPoint.graphics
               ~color_attachments:
                 [ V.AttachmentReference.make ~attachment:0
                     ~layout:V.ImageLayout.color_attachment_optimal ()
                 ]
               ()
           ]
         ())
  in
  let framebuffer =
    V.create_framebuffer device
      (V.FramebufferCreateInfo.make ~render_pass ~attachments:[ image_view ] ~width ~height
         ~layers:1 ())
  in

  (* -- graphics pipeline: triangle.vert/frag, no vertex buffers, fixed
     64x64 viewport/scissor, no blending -- *)
  let vert_module =
    V.create_shader_module device
      (V.ShaderModuleCreateInfo.make ~code:Vk_test_shaders.triangle_vert ())
  in
  let frag_module =
    V.create_shader_module device
      (V.ShaderModuleCreateInfo.make ~code:Vk_test_shaders.triangle_frag ())
  in
  let pipeline_layout = V.create_pipeline_layout device (V.PipelineLayoutCreateInfo.make ()) in
  let pipeline =
    (* FIXME(integration lane): confirm the renamed `module` field/label on
       PipelineShaderStageCreateInfo (assumed `module_`, see test_compute.ml's
       TODO block for the same assumption). *)
    let stages =
      [ V.PipelineShaderStageCreateInfo.make ~stage:V.ShaderStageFlags.vertex
          ~module_:vert_module ~name:"main" ();
        V.PipelineShaderStageCreateInfo.make ~stage:V.ShaderStageFlags.fragment
          ~module_:frag_module ~name:"main" ()
      ]
    in
    let vertex_input_state = V.PipelineVertexInputStateCreateInfo.make () in
    let input_assembly_state =
      V.PipelineInputAssemblyStateCreateInfo.make ~topology:V.PrimitiveTopology.triangle_list ()
    in
    let viewport_state =
      V.PipelineViewportStateCreateInfo.make
        ~viewports:
          [ V.Viewport.make ~x:0. ~y:0. ~width:(float_of_int width) ~height:(float_of_int height)
              ~min_depth:0. ~max_depth:1. ()
          ]
        ~scissors:
          [ V.Rect2D.make
              ~offset:(V.Offset2D.make ~x:0 ~y:0 ())
              ~extent:(V.Extent2D.make ~width ~height ())
              ()
          ]
        ()
    in
    let rasterization_state =
      V.PipelineRasterizationStateCreateInfo.make ~polygon_mode:V.PolygonMode.fill
        ~cull_mode:V.CullModeFlags.none ~front_face:V.FrontFace.counter_clockwise ~line_width:1.0
        ()
    in
    let multisample_state =
      V.PipelineMultisampleStateCreateInfo.make ~rasterization_samples:V.SampleCountFlags._1 ()
    in
    let color_blend_state =
      V.PipelineColorBlendStateCreateInfo.make
        ~attachments:
          [ V.PipelineColorBlendAttachmentState.make
              ~color_write_mask:
                V.ColorComponentFlags.(r lor g lor b lor a)
              ()
          ]
        ()
    in
    List.hd
      (V.create_graphics_pipelines device V.PipelineCache.null
         [ V.GraphicsPipelineCreateInfo.make ~stages ~vertex_input_state ~input_assembly_state
             ~viewport_state ~rasterization_state ~multisample_state ~color_blend_state
             ~layout:pipeline_layout ~render_pass ~subpass:0 ()
         ])
  in

  (* -- record + submit: clear, draw 3 vertices, transition, copy out -- *)
  let readback_buffer_size = width * height * 4 in
  let readback_buffer =
    V.create_buffer device
      (V.BufferCreateInfo.make ~size:readback_buffer_size ~usage:V.BufferUsageFlags.transfer_dst
         ~sharing_mode:V.SharingMode.exclusive ())
  in
  let readback_reqs = V.get_buffer_memory_requirements device readback_buffer in
  let readback_memory =
    V.allocate_memory device
      (V.MemoryAllocateInfo.make
         ~allocation_size:(Ctypes.getf readback_reqs V.MemoryRequirements.size)
         ~memory_type_index:
           (find_memory_type mem_props
              ~type_bits:(Ctypes.getf readback_reqs V.MemoryRequirements.memory_type_bits)
              ~required_properties:V.MemoryPropertyFlags.(host_visible lor host_coherent))
         ())
  in
  V.bind_buffer_memory device readback_buffer readback_memory 0;

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
  let r, g, b, a = clear_color in
  V.cmd_begin_render_pass cb
    (V.RenderPassBeginInfo.make ~render_pass ~framebuffer
       ~render_area:
         (V.Rect2D.make ~offset:(V.Offset2D.make ~x:0 ~y:0 ()) ~extent:(V.Extent2D.make ~width ~height ()) ())
       ~clear_values:[ V.ClearValue.color (V.ClearColorValue.float32 [ r; g; b; a ]) ]
       ())
    V.SubpassContents.inline;
  V.cmd_bind_pipeline cb V.PipelineBindPoint.graphics pipeline;
  V.cmd_draw cb 3 1 0 0;
  V.cmd_end_render_pass cb;
  V.cmd_pipeline_barrier cb V.PipelineStageFlags.color_attachment_output
    V.PipelineStageFlags.transfer V.DependencyFlags.empty [] []
    [ V.ImageMemoryBarrier.make ~src_access_mask:V.AccessFlags.color_attachment_write
        ~dst_access_mask:V.AccessFlags.transfer_read
        ~old_layout:V.ImageLayout.color_attachment_optimal
        ~new_layout:V.ImageLayout.transfer_src_optimal
        ~src_queue_family_index:V.queue_family_ignored ~dst_queue_family_index:V.queue_family_ignored
        ~image ~subresource_range ()
    ];
  V.cmd_copy_image_to_buffer cb image V.ImageLayout.transfer_src_optimal readback_buffer
    [ V.BufferImageCopy.make ~buffer_offset:0 ~buffer_row_length:0 ~buffer_image_height:0
        ~image_subresource:
          (V.ImageSubresourceLayers.make ~aspect_mask:V.ImageAspectFlags.color ~mip_level:0
             ~base_array_layer:0 ~layer_count:1 ())
        ~image_offset:(V.Offset3D.make ~x:0 ~y:0 ~z:0 ())
        ~image_extent:(V.Extent3D.make ~width ~height ~depth:1 ())
        ()
    ];
  V.end_command_buffer cb;

  let fence = V.create_fence device (V.FenceCreateInfo.make ()) in
  V.queue_submit queue [ V.SubmitInfo.make ~command_buffers:[ cb ] () ] fence;
  let wait_result = V.wait_for_fences device [ fence ] true 5_000_000_000 (* 5s, in ns *) in
  Alcotest.(check bool) "fence signalled before the 5s timeout" true
    (V.Result.equal wait_result V.Result.success);

  (* -- read back and check pixels (tightly packed RGBA8, no row padding) -- *)
  let pixels = V.map_memory device readback_memory 0 readback_buffer_size V.MemoryMapFlags.empty in
  let bytes = Ctypes.(coerce (ptr void) (ptr uint8_t) pixels) in
  let pixel_at x y =
    let o = ((y * width) + x) * 4 in
    let byte k = Unsigned.UInt8.to_int Ctypes.(!@(bytes +@ (o + k))) in
    (byte 0, byte 1, byte 2, byte 3)
  in
  (* UNORM<->float8 conversion is only exact up to rounding, and the clear
     value is applied by the driver, not computed by this test -- compare
     with a +/-2 tolerance instead of bit-exact equality. *)
  let to_u8 f = int_of_float ((f *. 255.) +. 0.5) in
  let close_enough a b = abs (a - b) <= 2 in
  let center = pixel_at (width / 2) (height / 2) in
  let corner = pixel_at 0 0 in
  let center_r, center_g, center_b, _ = center in
  Alcotest.(check bool) "centre pixel is non-black (inside the triangle)" true
    (center_r > 0 || center_g > 0 || center_b > 0);
  let corner_r, corner_g, corner_b, _ = corner in
  Alcotest.(check bool)
    (Printf.sprintf "corner pixel %s equals the clear colour %s (+/-2, outside the triangle)"
       (Printf.sprintf "(%d,%d,%d)" corner_r corner_g corner_b)
       (Printf.sprintf "(%d,%d,%d)" (to_u8 r) (to_u8 g) (to_u8 b)))
    true
    (close_enough corner_r (to_u8 r) && close_enough corner_g (to_u8 g)
    && close_enough corner_b (to_u8 b));

  V.destroy_fence device fence ();
  V.destroy_command_pool device command_pool ();
  V.destroy_pipeline device pipeline ();
  V.destroy_pipeline_layout device pipeline_layout ();
  V.destroy_shader_module device frag_module ();
  V.destroy_shader_module device vert_module ();
  V.destroy_framebuffer device framebuffer ();
  V.destroy_render_pass device render_pass ();
  V.destroy_image_view device image_view ();
  V.free_memory device image_memory ();
  V.destroy_image device image ();
  V.unmap_memory device readback_memory;
  V.free_memory device readback_memory ();
  V.destroy_buffer device readback_buffer ();
  V.destroy_device device ();
  V.destroy_instance instance ()

let suite : unit Alcotest.test_case list =
  [ Alcotest.test_case "offscreen triangle: centre non-black, corner = clear colour" `Quick
      test_offscreen_triangle ]
