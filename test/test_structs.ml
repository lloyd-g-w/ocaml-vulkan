(* test_structs.ml -- `make` sets sType, count fields match list lengths,
   string arguments round-trip through char pointers, keep-alive survives
   Gc.full_major, bitfield packing. See DESIGN.md §7 (structs/unions) and §12
   (test_structs.ml).

   Verified against the real generated API (integration lane):
   - `X.make` signatures follow DESIGN §7's table: a `const char* p` with
     `len="null-terminated"` becomes `?x:string`; a `T* p` + count pair
     becomes `?xs:elem list` (count is derived, not passed separately).
   - `X.structure_type : StructureType.t option` and `make` sets `sType` from
     it automatically (DESIGN §7).
   - Every raw ctypes field is reachable as `X.field_name` per the
     `InstanceCreateInfo` example in DESIGN §7 (`s_type`, `p_application_name`,
     `enabled_layer_count`, ...).
   - `module`/`type` are OCaml keywords; the generator renames the C `module`
     field of `VkPipelineShaderStageCreateInfo` and the C `type` field of
     `VkDescriptorPoolSize` to `module_`/`type_`, the same "append `_`" rule
     DESIGN §3 documents for enum values. Not exercised in this file; noted
     here since test_compute.ml relies on it.
   - Bitfield members are merged into one raw field per contiguous run,
     named `<first_member>_bits`, per DESIGN §7. For
     `VkAccelerationStructureInstanceKHR` that means two 32-bit runs:
     `instance_custom_index_bits` (instanceCustomIndex:24 | mask:8) and
     `instance_shader_binding_table_record_offset_bits`
     (instanceShaderBindingTableRecordOffset:24 | flags:8), each packed
     LSB-first (low bitfield in the low bits). `make` exposes each original
     bitfield as its own labelled argument, typed like any other member of
     its C type (DESIGN §4/§7: "enum / flags -> module type"), so the plain
     `instance_custom_index`/`mask`/`instance_shader_binding_table_record_offset`
     bitfields take a plain `int` but `flags` (C type `VkGeometryInstanceFlagsKHR`)
     takes `GeometryInstanceFlagsKHR.t`, packed via `to_int`. *)

module V = Vk

let test_make_sets_s_type () =
  let info = V.ApplicationInfo.make () in
  match V.ApplicationInfo.structure_type with
  | None -> Alcotest.fail "ApplicationInfo.structure_type is None (expected Some application_info)"
  | Some expected ->
    let actual = Ctypes.getf info V.ApplicationInfo.s_type in
    Alcotest.(check bool) "make sets sType from structure_type" true
      (V.StructureType.equal actual expected)

let test_count_fields_match_list_lengths () =
  let ci =
    V.InstanceCreateInfo.make
      ~enabled_layer_names:[ "VK_LAYER_KHRONOS_validation" ]
      ~enabled_extension_names:[ "VK_KHR_surface"; "VK_KHR_get_surface_capabilities2" ]
      ()
  in
  Alcotest.(check int) "enabled_layer_count matches enabled_layer_names length" 1
    (Ctypes.getf ci V.InstanceCreateInfo.enabled_layer_count);
  Alcotest.(check int) "enabled_extension_count matches enabled_extension_names length" 2
    (Ctypes.getf ci V.InstanceCreateInfo.enabled_extension_count)

let test_string_round_trip_and_keep_alive () =
  let info =
    V.ApplicationInfo.make ~application_name:"harness-test" ~engine_name:"vk-lanes" ()
  in
  let read_back () =
    ( V.string_of_char_ptr (Ctypes.getf info V.ApplicationInfo.p_application_name),
      V.string_of_char_ptr (Ctypes.getf info V.ApplicationInfo.p_engine_name) )
  in
  Alcotest.(check (pair string string))
    "application/engine name round-trip through char pointers before GC"
    ("harness-test", "vk-lanes") (read_back ());
  (* The OCaml strings backing pApplicationName/pEngineName are only kept
     alive by `info`'s keep-alive list (DESIGN §7); a real collection must
     not free them while `info` itself is still reachable. *)
  Gc.full_major ();
  Gc.full_major ();
  Alcotest.(check (pair string string))
    "application/engine name still intact after Gc.full_major" ("harness-test", "vk-lanes")
    (read_back ())

let test_bitfield_packing () =
  let instance_custom_index = 0x00abcdef (* fits in 24 bits *) in
  let mask = 0xa5 (* fits in 8 bits *) in
  let sbt_offset = 0x00123456 (* fits in 24 bits *) in
  let flags = 0x03 (* fits in 8 bits *) in
  (* `transform` is left at its default (all-arguments-optional, DESIGN §7:
     "memory zero-filled by Ctypes.make"); this test only cares about the
     bitfield-packed members. *)
  let s =
    V.AccelerationStructureInstanceKHR.make ~instance_custom_index ~mask
      ~instance_shader_binding_table_record_offset:sbt_offset
      ~flags:(V.GeometryInstanceFlagsKHR.of_int flags)
      ~acceleration_structure_reference:0x1122_3344_5566_7788 ()
  in
  let word1 = Ctypes.getf s V.AccelerationStructureInstanceKHR.instance_custom_index_bits in
  let word2 =
    Ctypes.getf s V.AccelerationStructureInstanceKHR.instance_shader_binding_table_record_offset_bits
  in
  Alcotest.(check int) "instanceCustomIndex:24 | mask:8 packs LSB-first"
    (instance_custom_index lor (mask lsl 24))
    word1;
  Alcotest.(check int) "instanceShaderBindingTableRecordOffset:24 | flags:8 packs LSB-first"
    (sbt_offset lor (flags lsl 24))
    word2;
  Alcotest.(check int64) "accelerationStructureReference (64-bit member after the bitfields) round-trips"
    0x1122_3344_5566_7788L
    (Int64.of_int (Ctypes.getf s V.AccelerationStructureInstanceKHR.acceleration_structure_reference))

let suite : unit Alcotest.test_case list =
  [ Alcotest.test_case "make sets sType" `Quick test_make_sets_s_type;
    Alcotest.test_case "count fields match list argument lengths" `Quick
      test_count_fields_match_list_lengths;
    Alcotest.test_case "string args round-trip + keep-alive survives Gc.full_major" `Quick
      test_string_round_trip_and_keep_alive;
    Alcotest.test_case "bitfield packing (VkAccelerationStructureInstanceKHR)" `Quick
      test_bitfield_packing ]
