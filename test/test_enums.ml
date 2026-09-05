(* test_enums.ml -- enum/flag round trips, Result.to_string, Vk.Error printer.
   See DESIGN.md §5 (enums/flags) and §12 (test_enums.ml).

   TODO(integration lane) -- this file cannot be compiled yet: lib/vk.ml is
   still a stub (the generator lane hasn't landed). Written directly against
   DESIGN.md; please verify against the real generated Vk module and adjust
   as needed. Assumptions made here:
   - `Vk.ImageLayout`/`Vk.ImageUsageFlags`/`Vk.Result` exist with exactly the
     signatures in DESIGN §5 (of_int/to_int/to_string/equal/compare for
     enums; empty/( lor )/( land )/union/inter/diff/mem/of_list/to_list for
     flags).
   - `Vk.ImageUsageFlags.to_string` joins bit names with `" | "` in the exact
     format `"VK_A_BIT | VK_B_BIT"` shown in DESIGN §5 (raw C bit names, not
     the friendly OCaml value names).
   - `Vk.Result.to_string Vk.Result.success = "VK_SUCCESS"` and similarly for
     `error_device_lost` / `error_out_of_host_memory` -- DESIGN §3 says enum
     `to_string` reproduces the original spec identifier, and VkResult's C
     names have no type-derived prefix to strip beyond "VK_", so this should
     hold verbatim.
   - `exception Error of Result.t` has a registered Printexc printer that
     renders as `"Vk.Error(VK_ERROR_DEVICE_LOST)"` per DESIGN §5's comment. *)

module V = Vk

let test_enum_round_trip () =
  (* of_int/to_int must be inverse on every named value we reference. *)
  let values =
    [ V.ImageLayout.undefined; V.ImageLayout.general;
      V.ImageLayout.color_attachment_optimal; V.ImageLayout.transfer_src_optimal;
      V.ImageLayout.transfer_dst_optimal; V.ImageLayout.present_src_khr ]
  in
  List.iter
    (fun v ->
      Alcotest.(check int) "of_int (to_int v) = to_int v"
        (V.ImageLayout.to_int v)
        (V.ImageLayout.to_int (V.ImageLayout.of_int (V.ImageLayout.to_int v))))
    values;
  Alcotest.(check bool) "equal is reflexive" true
    (V.ImageLayout.equal V.ImageLayout.general V.ImageLayout.general);
  Alcotest.(check bool) "compare distinguishes different values" true
    (V.ImageLayout.compare V.ImageLayout.undefined V.ImageLayout.general <> 0)

let test_enum_to_string () =
  Alcotest.(check string) "known value stringifies to its VK_ name"
    "VK_IMAGE_LAYOUT_GENERAL"
    (V.ImageLayout.to_string V.ImageLayout.general);
  (* Unknown/out-of-range values must not raise -- DESIGN §5 promises a
     `"ImageLayout(1234)"`-shaped fallback instead of an exception. *)
  let bogus = V.ImageLayout.of_int 0x7fff_fff0 in
  let s = V.ImageLayout.to_string bogus in
  Alcotest.(check bool) "unknown value stringifies without raising" true
    (String.length s > 0)

let test_flags_ops () =
  let open V.ImageUsageFlags in
  Alcotest.(check bool) "empty has no bits set" true (mem empty color_attachment |> not);
  let both = color_attachment lor transfer_dst in
  Alcotest.(check bool) "mem sees both bits after lor" true
    (mem both color_attachment && mem both transfer_dst);
  Alcotest.(check bool) "land extracts a single shared bit" true
    (equal (both land color_attachment) color_attachment);
  Alcotest.(check bool) "union is the same as lor for two bits" true
    (equal (union color_attachment transfer_dst) both);
  Alcotest.(check bool) "inter of disjoint sets is empty" true
    (equal (inter color_attachment transfer_dst) empty);
  Alcotest.(check bool) "diff removes a bit" true
    (equal (diff both transfer_dst) color_attachment);
  Alcotest.(check bool) "of_list/to_list round trip (as a set)" true
    (let roundtripped = of_list (to_list both) in
     equal roundtripped both);
  let printed = to_string both in
  Alcotest.(check bool) {|to_string joins bits with " | "|} true
    (String.length printed > 0 && String.contains printed '|')

let test_result_to_string () =
  Alcotest.(check string) "VK_SUCCESS" "VK_SUCCESS" (V.Result.to_string V.Result.success);
  Alcotest.(check string) "VK_ERROR_DEVICE_LOST" "VK_ERROR_DEVICE_LOST"
    (V.Result.to_string V.Result.error_device_lost)

let test_check_and_error_printer () =
  (* Vk.check must be a no-op on success codes ... *)
  (try V.check V.Result.success
   with _ -> Alcotest.fail "Vk.check raised on VK_SUCCESS");
  (* ... and raise Vk.Error on negative (error) codes. *)
  (try
     V.check V.Result.error_device_lost;
     Alcotest.fail "Vk.check did not raise on VK_ERROR_DEVICE_LOST"
   with
  | V.Error r -> Alcotest.(check bool) "raised with the same Result.t" true (V.Result.equal r V.Result.error_device_lost)
  | e -> Alcotest.failf "Vk.check raised the wrong exception: %s" (Printexc.to_string e));
  Alcotest.(check string) "Vk.Error has a registered pretty printer"
    "Vk.Error(VK_ERROR_DEVICE_LOST)"
    (Printexc.to_string (V.Error V.Result.error_device_lost))

let suite : unit Alcotest.test_case list =
  [ Alcotest.test_case "enum of_int/to_int round trip" `Quick test_enum_round_trip;
    Alcotest.test_case "enum to_string" `Quick test_enum_to_string;
    Alcotest.test_case "flags ops (empty/lor/land/union/inter/diff/mem/of_list/to_list)" `Quick
      test_flags_ops;
    Alcotest.test_case "Result.to_string" `Quick test_result_to_string;
    Alcotest.test_case "Vk.check + Vk.Error printer" `Quick test_check_and_error_printer ]
