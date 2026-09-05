(* test_gc_safety.ml -- regression tests for the independent review's two P0
   generator keep-alive bugs, plus a P1 callback-lifetime regression. Adapted
   from the reviewer's repro programs under /tmp/vk-review/:
   - repro1_byvalue_uaf.ml      -> test_byvalue_struct_embedding_survives_gc
   - repro2_wrapper_list_uaf.ml -> test_queue_submit_keeps_submit_info_alive
   - repro7_debug_callback_uaf.ml -> test_debug_messenger_callback_survives_gc

   See DESIGN.md §7 (struct-by-value members are retained in the parent's
   `keep` list; PFN_* members are additionally retained forever via
   `Vk_base.retain_forever`) and §9/§10 (every wrapper argument -- the
   original list/struct the caller passed in, and any temporary CArray
   `_make_args` derived from it -- is kept reachable past the raw
   `Vk_fn.*` call with `Sys.opaque_identity`).

   Each test deliberately builds the "victim" value inside a helper function
   that does not itself return that value, so the only thing reachable
   afterwards is whatever the *generated code path under test* keeps alive;
   forces `Gc.full_major` (twice, matching the repros) plus heap-spraying
   with same-size allocations to encourage the allocator to reuse any freed
   block; and then checks the embedded data is still intact. This actually
   exercises the fix (it would fail if the `Vk_base.retain`/
   `Sys.opaque_identity`/`Vk_base.retain_forever` calls were removed from the
   generated code -- verified manually while developing this file by
   reverting the generator change and confirming these tests then fail). *)

module V = Vk

let spray_garbage n size =
  let garbage = ref [] in
  for i = 0 to n do
    let b = Bytes.make size 'X' in
    garbage := Ctypes.CArray.of_string (Bytes.to_string b) :: !garbage;
    if i land 4095 = 0 then Gc.minor ()
  done;
  (* Keep the compiler from proving `garbage` dead before this point (and
     thus from ever actually spraying the heap) while not otherwise caring
     about its contents. *)
  ignore (Sys.opaque_identity (List.length !garbage))

(* ---- P0-1 (gen/vkgen/emit_types.py, by-value struct/union embedding) -- *)

let collected_inner_stage = ref false

(* Mirrors repro1_byvalue_uaf.ml's `build`: the only thing that survives
   after this function returns is `pci`'s *copied bytes* of `stage`: `stage`
   itself (an OCaml value with its own `pName` keep-alive list) is not
   returned. *)
let build_compute_pipeline_create_info () =
  let stage =
    V.PipelineShaderStageCreateInfo.make ~stage:V.ShaderStageFlags.compute
      ~module_:V.ShaderModule.null ~name:"main_entry_pt" ()
  in
  Gc.finalise (fun _ -> collected_inner_stage := true) stage;
  V.ComputePipelineCreateInfo.make ~stage ~layout:V.PipelineLayout.null ()

let test_byvalue_struct_embedding_survives_gc () =
  collected_inner_stage := false;
  let pci = build_compute_pipeline_create_info () in
  Gc.full_major ();
  Gc.full_major ();
  spray_garbage 200_000 15 (* "main_entry_pt\000" is a 15-byte allocation *);
  Gc.full_major ();
  let name =
    V.string_of_char_ptr
      (Ctypes.getf
         (Ctypes.getf pci V.ComputePipelineCreateInfo.stage)
         V.PipelineShaderStageCreateInfo.p_name)
  in
  Alcotest.(check bool)
    "the embedded `stage` value (and hence its pName allocation) was not collected \
     while `pci` is still reachable"
    false !collected_inner_stage;
  Alcotest.(check string)
    "pci.stage.pName still reads back \"main_entry_pt\" after 2x Gc.full_major + heap spraying"
    "main_entry_pt" name

(* ---- P0-2 (gen/vkgen/emit_api.py, wrapper list-argument keep-alive) --- *)

let find_compute_queue_family pd =
  V.get_physical_device_queue_family_properties pd
  |> List.mapi (fun i qf -> (i, qf))
  |> List.find_opt (fun (_, qf) ->
         V.QueueFlags.mem (Ctypes.getf qf V.QueueFamilyProperties.queue_flags) V.QueueFlags.compute)
  |> function
  | Some (i, _) -> i
  | None -> Alcotest.fail "no compute-capable queue family"

(* An allocating, GC-triggering debug-utils callback: installed for the
   whole test as a realistic (if not 100%-guaranteed-timed) source of a GC
   landing *during* a raw Vulkan call, per the reviewer's suggested
   regression strategy (a debug messenger with an allocating callback is a
   plausible GC trigger during vkQueueSubmit on this loader/lavapipe, since
   the loader can emit debug-utils messages around any call once a messenger
   is registered). *)
let allocating_debug_callback _severity _type_ _data _user_data =
  spray_garbage 2_000 8;
  Gc.full_major ();
  false

let test_queue_submit_keeps_submit_info_alive () =
  let instance =
    V.create_instance
      (V.InstanceCreateInfo.make
         ~application_info:(V.ApplicationInfo.make ~application_name:"test_gc_safety" ())
         ~enabled_extension_names:[ V.Ext.ext_debug_utils ] ())
  in
  let messenger =
    V.create_debug_utils_messenger_ext instance
      (V.DebugUtilsMessengerCreateInfoEXT.make
         ~message_severity:
           V.DebugUtilsMessageSeverityFlagsEXT.(verbose_ext lor info_ext lor warning_ext lor error_ext)
         ~message_type:
           V.DebugUtilsMessageTypeFlagsEXT.(general_ext lor validation_ext lor performance_ext)
         ~pfn_user_callback:allocating_debug_callback ())
  in
  let pd = List.hd (V.enumerate_physical_devices instance) in
  let qfi = find_compute_queue_family pd in
  let device =
    V.create_device pd
      (V.DeviceCreateInfo.make
         ~queue_create_infos:
           [ V.DeviceQueueCreateInfo.make ~queue_family_index:qfi ~queue_priorities:[ 1.0 ] () ]
         ())
  in
  let queue = V.get_device_queue device qfi 0 in
  let command_pool =
    V.create_command_pool device (V.CommandPoolCreateInfo.make ~queue_family_index:qfi ())
  in
  let cb =
    List.hd
      (V.allocate_command_buffers device
         (V.CommandBufferAllocateInfo.make ~command_pool ~level:V.CommandBufferLevel.primary
            ~command_buffer_count:1 ()))
  in
  (* Repeatedly: force a major GC + spray the heap (the exact repro2 window,
     against the real generated wrapper this time), then build a *fresh*
     SubmitInfo inline (never bound to a name the loop itself keeps alive)
     and submit the same, empty, valid command buffer. `vkBeginCommandBuffer`
     on an already-recorded command buffer implicitly resets it, so the same
     `cb` can be re-recorded/resubmitted every iteration. If `Vk.queue_submit`
     ever again fails to retain `arg_submits`/`array_submits` past the raw
     call, this is exactly the window in which the driver could read a freed
     `pCommandBuffers` array. *)
  for i = 0 to 19 do
    V.begin_command_buffer cb (V.CommandBufferBeginInfo.make ());
    V.end_command_buffer cb;
    Gc.full_major ();
    Gc.full_major ();
    spray_garbage 30_000 8 (* one CommandBuffer.t (a pointer) is 8 bytes on x86_64 *);
    let fence = V.create_fence device (V.FenceCreateInfo.make ()) in
    V.queue_submit queue [ V.SubmitInfo.make ~command_buffers:[ cb ] () ] fence;
    let result = V.wait_for_fences device [ fence ] true 5_000_000_000 (* 5s, in ns *) in
    if not (V.Result.equal result V.Result.success) then
      Alcotest.failf "queue_submit iteration %d: fence did not signal before the 5s timeout (result=%s)"
        i (V.Result.to_string result);
    V.destroy_fence device fence ()
  done;
  V.destroy_command_pool device command_pool ();
  V.destroy_device device ();
  V.destroy_debug_utils_messenger_ext instance messenger ();
  V.destroy_instance instance ()

(* ---- P1-4 (gen/vkgen/emit_types.py, PFN_* member callback lifetime) --- *)

let messenger_callback_invoked = ref false

(* Mirrors repro7_debug_callback_uaf.ml: build the messenger inside a helper
   that returns only the handle, not the create-info struct or the OCaml
   closure -- so the only thing keeping the callback alive afterwards must be
   `Vk_base.retain_forever` (its owning create-info struct is unreachable the
   moment this function returns). *)
let create_messenger_without_retaining_callback instance =
  let callback _severity _type_ _data _user_data =
    messenger_callback_invoked := true;
    false
  in
  V.create_debug_utils_messenger_ext instance
    (V.DebugUtilsMessengerCreateInfoEXT.make
       ~message_severity:
         V.DebugUtilsMessageSeverityFlagsEXT.(verbose_ext lor info_ext lor warning_ext lor error_ext)
       ~message_type:V.DebugUtilsMessageTypeFlagsEXT.(general_ext lor validation_ext lor performance_ext)
       ~pfn_user_callback:callback ())

let test_debug_messenger_callback_survives_gc () =
  messenger_callback_invoked := false;
  let instance =
    V.create_instance
      (V.InstanceCreateInfo.make
         ~application_info:(V.ApplicationInfo.make ~application_name:"test_gc_safety" ())
         ~enabled_extension_names:[ V.Ext.ext_debug_utils ] ())
  in
  let messenger = create_messenger_without_retaining_callback instance in
  Gc.full_major ();
  Gc.full_major ();
  spray_garbage 200_000 64 (* closures are small heap blocks; spray a range of sizes *);
  Gc.full_major ();
  let callback_data =
    V.DebugUtilsMessengerCallbackDataEXT.make ~message:"test_gc_safety synthetic message" ()
  in
  (* Calls back into the (allegedly collected, if the bug were present)
     OCaml closure via the raw C trampoline the driver/loader still holds. *)
  V.submit_debug_utils_message_ext instance V.DebugUtilsMessageSeverityFlagsEXT.warning_ext
    V.DebugUtilsMessageTypeFlagsEXT.general_ext callback_data;
  Alcotest.(check bool)
    "the debug messenger's OCaml callback closure, retained forever via \
     Vk_base.retain_forever, still fires after its owning create-info struct is long gone"
    true !messenger_callback_invoked;
  V.destroy_debug_utils_messenger_ext instance messenger ();
  V.destroy_instance instance ()

let suite : unit Alcotest.test_case list =
  [ Alcotest.test_case "P0-1: struct-by-value embedding (ComputePipelineCreateInfo.stage) \
                        survives Gc.full_major"
      `Quick test_byvalue_struct_embedding_survives_gc;
    Alcotest.test_case "P0-2: Vk.queue_submit keeps its SubmitInfo list alive across \
                        the raw call under GC pressure"
      `Quick test_queue_submit_keeps_submit_info_alive;
    Alcotest.test_case "P1-4: a debug messenger callback retained via Vk_base.retain_forever \
                        survives its create-info struct going out of scope"
      `Quick test_debug_messenger_callback_survives_gc
  ]
