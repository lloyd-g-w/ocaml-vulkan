(* examples/debug_utils.ml -- VK_EXT_debug_utils callback + pNext chaining.

   Two independent things, both demonstrated on lavapipe (no validation
   layer is installed on this machine, but lavapipe's own Vulkan loader
   exposes the VK_EXT_debug_utils *extension*, which is a loader/ICD
   feature independent of any layer -- see DESIGN.md's "no validation layer"
   note in the task and the loader-implemented vkSubmitDebugUtilsMessageEXT
   used below):

   1. An OCaml callback (Vk.PfnDebugUtilsMessengerCallbackEXT.fn) is
      installed via Vk.DebugUtilsMessengerCreateInfoEXT.make
      ~pfn_user_callback, both permanently (vkCreateDebugUtilsMessengerEXT)
      and transiently for instance creation/destruction itself (chained
      onto InstanceCreateInfo's ~next). Since there's no validation layer
      to generate organic messages, we prove the callback actually fires by
      calling vkSubmitDebugUtilsMessageEXT (a loader-implemented function
      that fans a message out to every registered messenger) directly.

   2. pNext chaining with Vk.next: querying VkPhysicalDeviceFeatures2 with a
      VkPhysicalDeviceVulkan12Features chained on, showing how a struct
      allocated in OCaml is both written by the driver and read back
      through the same binding.

   Run with: dune exec examples/debug_utils.exe

   Note on naming: DESIGN.md §3 says ergonomic argument labels drop the
   p/pp/pfn prefix (e.g. ~user_callback), but the generated
   DebugUtilsMessengerCreateInfoEXT.make actually keeps it
   (~pfn_user_callback, ~p_user_data) -- see the handoff report. This file
   uses the real (~pfn_user_callback) label, not the DESIGN-documented one. *)

let messages_seen = ref 0

(* Vk.PfnDebugUtilsMessengerCallbackEXT.fn =
     DebugUtilsMessageSeverityFlagsEXT.t -> DebugUtilsMessageTypeFlagsEXT.t ->
     DebugUtilsMessengerCallbackDataEXT.t Ctypes.structure Ctypes.ptr ->
     unit Ctypes.ptr -> bool
   Returning false is the normal case: true would abort the Vulkan call
   that triggered the message (reserved for validation-layer-style use). *)
let callback severity message_type data _user_data =
  incr messages_seen;
  let data = Ctypes.( !@ ) data in
  let message = Vk.string_of_char_ptr (Ctypes.getf data Vk.DebugUtilsMessengerCallbackDataEXT.p_message) in
  Printf.printf "  [%s][%s] %s\n"
    (Vk.DebugUtilsMessageSeverityFlagsEXT.to_string severity)
    (Vk.DebugUtilsMessageTypeFlagsEXT.to_string message_type)
    message;
  false

let () =
  (* -- 1a. pNext-chain a messenger onto instance creation itself, so
     create/destroy_instance are covered too (not just calls made after the
     instance exists). *)
  let instance_debug_info =
    Vk.DebugUtilsMessengerCreateInfoEXT.make
      ~message_severity:
        Vk.DebugUtilsMessageSeverityFlagsEXT.(verbose_ext lor info_ext lor warning_ext lor error_ext)
      ~message_type:
        Vk.DebugUtilsMessageTypeFlagsEXT.(general_ext lor validation_ext lor performance_ext)
      ~pfn_user_callback:callback ()
  in
  let application =
    Vk.ApplicationInfo.make ~application_name:"ocaml-vulkan debug_utils" ~api_version:Vk.api_version_1_4 ()
  in
  let instance =
    Vk.create_instance
      (Vk.InstanceCreateInfo.make ~next:(Vk.next instance_debug_info) ~application_info:application
         ~enabled_extension_names:[ Vk.Ext.ext_debug_utils ] ())
  in

  (* -- 1b. a permanent messenger for everything between here and
     vkDestroyInstance. *)
  let messenger =
    Vk.create_debug_utils_messenger_ext instance
      (Vk.DebugUtilsMessengerCreateInfoEXT.make
         ~message_severity:
           Vk.DebugUtilsMessageSeverityFlagsEXT.(verbose_ext lor info_ext lor warning_ext lor error_ext)
         ~message_type:
           Vk.DebugUtilsMessageTypeFlagsEXT.(general_ext lor validation_ext lor performance_ext)
         ~pfn_user_callback:callback ())
  in
  Printf.printf "created instance + debug messenger (VK_EXT_debug_utils enabled)\n";

  (* Inject a message ourselves (vkSubmitDebugUtilsMessageEXT is
     loader-implemented: it calls every registered messenger's callback
     directly, with no ICD/validation-layer involvement) -- this is what
     proves callback dispatches OCaml code correctly, deterministically,
     without depending on a validation layer being installed. *)
  Printf.printf "submitting a synthetic debug message:\n";
  Vk.submit_debug_utils_message_ext instance Vk.DebugUtilsMessageSeverityFlagsEXT.info_ext
    Vk.DebugUtilsMessageTypeFlagsEXT.general_ext
    (Vk.DebugUtilsMessengerCallbackDataEXT.make ~message_id_name:"ocaml-vulkan.demo"
       ~message:"hello from an OCaml debug callback" ());
  if !messages_seen < 1 then failwith "the OCaml debug_utils callback never fired";

  (* -- 2. pNext chaining: VkPhysicalDeviceFeatures2 + a chained
     VkPhysicalDeviceVulkan12Features, queried in one call. -- *)
  let physical_device = List.hd (Vk.enumerate_physical_devices instance) in
  let vulkan_12_features = Vk.PhysicalDeviceVulkan12Features.make () in
  let features2 = Vk.PhysicalDeviceFeatures2.make ~next:(Vk.next vulkan_12_features) () in
  Vk.get_physical_device_features_2 physical_device features2;
  let base_features = Ctypes.getf features2 Vk.PhysicalDeviceFeatures2.features in
  Printf.printf "PhysicalDeviceFeatures2 (base struct) + chained PhysicalDeviceVulkan12Features:\n";
  Printf.printf "  features.sampler_anisotropy   = %b\n"
    (Ctypes.getf base_features Vk.PhysicalDeviceFeatures.sampler_anisotropy);
  Printf.printf "  features.geometry_shader      = %b\n"
    (Ctypes.getf base_features Vk.PhysicalDeviceFeatures.geometry_shader);
  Printf.printf "  vulkan12.timeline_semaphore   = %b\n"
    (Ctypes.getf vulkan_12_features Vk.PhysicalDeviceVulkan12Features.timeline_semaphore);
  Printf.printf "  vulkan12.buffer_device_address = %b\n"
    (Ctypes.getf vulkan_12_features Vk.PhysicalDeviceVulkan12Features.buffer_device_address);
  Printf.printf "  vulkan12.descriptor_indexing  = %b\n"
    (Ctypes.getf vulkan_12_features Vk.PhysicalDeviceVulkan12Features.descriptor_indexing);

  Vk.destroy_debug_utils_messenger_ext instance messenger ();
  Vk.destroy_instance instance ();
  Printf.printf "debug_utils: %d callback invocation(s) observed; pNext-chained query succeeded\n"
    !messages_seen
