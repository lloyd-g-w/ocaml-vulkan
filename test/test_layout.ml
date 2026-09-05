(* test_layout.ml -- Vk.Layout.all vs the golden test/layout/<arch>.txt file
   produced by gen/layout_check.py + scripts/gen_layout.sh from the real C
   headers. See DESIGN.md §7 (`vk_layout.ml`) and §12 (test_layout.ml).

   TODO(integration lane) -- cannot compile yet (no lib/vk.ml content). Written
   directly against DESIGN.md. Assumptions:
   - `Vk.Layout.all : (string * int * (string * int) list) list` exactly as
     specified in DESIGN §2/§7 (C struct/union name, ctypes sizeof, [(C member
     name, ctypes offset)]).
   - The golden file naming scheme is `test/layout/<target-triple>.txt`
     (scripts/gen_layout.sh names it after `gcc -dumpmachine`). Only one
     golden file is committed by this lane (x86_64-linux-gnu, DESIGN §1:
     "64-bit platforms only, Linux first"), so rather than shell out to gcc
     (extra `unix` dependency + failure modes for no real benefit today) we
     hardcode that one filename; on any other platform/arch the file simply
     won't exist and the test skips, which is the documented behaviour
     anyway. Generalise this if/when a second golden file is added.
   - Per the task spec: only structs/unions present in *both* the golden file
     and `Vk.Layout.all` are compared (a struct known to only one side, e.g.
     because the generator hasn't implemented it yet, is not a failure here).
   - Bitfield members are simply absent from the golden file's member list
     (gen/layout_check.py skips them) and are expected to be absent, renamed,
     or merged (DESIGN §7 `<first>_bits`) on the Vk.Layout.all side -- since
     we only iterate the golden file's member list, such members are simply
     never checked, by construction. *)

module V = Vk

(* test/dune runs with cwd = _build/default/test; the golden files are
   checked in under <repo>/test/layout, which dune mirrors verbatim into
   _build/default/test/layout, so a plain relative path is enough. *)
let golden_path () = Filename.concat "layout" "x86_64-linux-gnu.txt"

(* Golden-file line grammar (see gen/layout_check.py):
     "VkName <size>"        -- struct/union header, no leading space
     "  memberName <off>"   -- member line, exactly two leading spaces *)
let parse_golden path : (string * (int * (string * int) list)) list =
  let ic = open_in path in
  let rec loop current acc =
    match input_line ic with
    | exception End_of_file ->
      close_in ic;
      let acc = match current with Some (n, e) -> (n, e) :: acc | None -> acc in
      List.rev acc
    | line ->
      if String.length line = 0 then loop current acc
      else if line.[0] = ' ' then (
        match current with
        | None -> loop current acc (* malformed; ignore stray member line *)
        | Some (name, (size, members)) ->
          (match String.split_on_char ' ' (String.trim line) with
          | [ member; off ] ->
            loop (Some (name, (size, (member, int_of_string off) :: members))) acc
          | _ -> loop current acc)
      )
      else (
        let acc = match current with Some (n, (s, m)) -> (n, (s, List.rev m)) :: acc | None -> acc in
        match String.split_on_char ' ' line with
        | [ name; size ] -> loop (Some (name, (int_of_string size, []))) acc
        | _ -> loop None acc)
  in
  loop None []

let test_layout_matches_golden () =
  let path = golden_path () in
  if not (Sys.file_exists path) then
    Alcotest.skip ();
  let golden = parse_golden path in
  let generated : (string, int * (string * int) list) Hashtbl.t = Hashtbl.create 4096 in
  List.iter (fun (name, size, members) -> Hashtbl.replace generated name (size, members)) V.Layout.all;
  let mismatches = ref [] in
  let add fmt = Printf.ksprintf (fun s -> mismatches := s :: !mismatches) fmt in
  let compared = ref 0 in
  List.iter
    (fun (name, (golden_size, golden_members)) ->
      match Hashtbl.find_opt generated name with
      | None -> () (* only compare structs present on both sides *)
      | Some (gen_size, gen_members) ->
        incr compared;
        if gen_size <> golden_size then
          add "%s: sizeof mismatch: golden=%d generated=%d" name golden_size gen_size;
        let gen_offsets = Hashtbl.create (List.length gen_members) in
        List.iter (fun (m, off) -> Hashtbl.replace gen_offsets m off) gen_members;
        List.iter
          (fun (member, golden_off) ->
            match Hashtbl.find_opt gen_offsets member with
            | None -> add "%s.%s: member missing from Vk.Layout.all" name member
            | Some gen_off ->
              if gen_off <> golden_off then
                add "%s.%s: offset mismatch: golden=%d generated=%d" name member golden_off gen_off)
          golden_members)
    golden;
  let mismatches = List.rev !mismatches in
  Alcotest.(check bool) "compared at least one struct present in both files" true (!compared > 0);
  if mismatches <> [] then (
    let first_20 = List.filteri (fun i _ -> i < 20) mismatches in
    Alcotest.failf "%d mismatch(es) between %s and Vk.Layout.all (first 20 shown):\n%s"
      (List.length mismatches) path
      (String.concat "\n" first_20))

(* P1-3 regression (gen/vkgen/registry.py's reachability filter,
   gen/vkgen/emit_common.py's fail-loud sType check): every struct module
   with `structure_type = Some st` must have a *real*, non-zero StructureType
   value -- before the fix, 54 structs reachable only from vulkansc-only or
   disabled extensions (or from a provisional extension, whose enum values
   were altogether skipped) silently got `StructureType.of_int 0` (=
   VK_STRUCTURE_TYPE_APPLICATION_INFO) instead. `VkApplicationInfo` is the
   one legitimate struct whose real sType value *is* 0, so it is the sole
   exception. `Vk.Layout.structure_types : (string * StructureType.t option)
   list` is a small companion table alongside `Vk.Layout.all` (whose own
   shape -- (name, sizeof, [(member, offset)]) -- is unchanged) added
   specifically for this check. *)
let test_no_struct_silently_defaults_its_s_type_to_zero () =
  let mismatches = ref [] in
  List.iter
    (fun (name, structure_type) ->
      match structure_type with
      | None -> () (* VkBaseInStructure/VkBaseOutStructure: no single fixed sType by design *)
      | Some st ->
        if V.StructureType.to_int st = 0 && name <> "VkApplicationInfo" then
          mismatches := name :: !mismatches)
    V.Layout.structure_types;
  Alcotest.(check bool) "compared at least one struct's structure_type" true
    (V.Layout.structure_types <> []);
  if !mismatches <> [] then
    Alcotest.failf "%d struct(s) with structure_type = Some st but StructureType.to_int st = 0 \
                    (silently defaulted, i.e. its real sType value did not resolve): %s"
      (List.length !mismatches)
      (String.concat ", " (List.sort compare !mismatches))

let suite : unit Alcotest.test_case list =
  [ Alcotest.test_case "Vk.Layout.all matches the golden layout file" `Quick
      test_layout_matches_golden;
    Alcotest.test_case
      "no struct with a resolved structure_type silently defaults its sType to 0" `Quick
      test_no_struct_silently_defaults_its_s_type_to_zero ]
