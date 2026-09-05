(* test_enum_values.ml -- Vk.Enum_values.all vs the golden test/enum_values/<arch>.txt
   file produced by gen/enum_check.py + scripts/gen_enum_values.sh from the
   real C headers (mirrors test_layout.ml / gen/layout_check.py exactly; see
   DESIGN.md sections 5, 10, 12, 13).

   Golden-file line grammar (see gen/enum_check.py): one line per constant,
   "VK_CONSTANT_NAME <value>" -- no header/member distinction like the layout
   golden file, and no leading whitespace at all. Values are printed by the
   probe program as `(long long)` (signed 64-bit), so a golden line can be
   negative (VkResult error codes) or exceed 32 bits (64-bit flag bits);
   OCaml ints are 63-bit (DESIGN.md section 4), which comfortably covers
   every value the current registry actually defines (the highest bitpos in
   use is 59), so plain `int_of_string` is enough on both sides. *)

module V = Vk

(* test/dune runs with cwd = _build/default/test; test/enum_values is
   mirrored there the same way test/layout is (see test/dune). *)
let golden_path () = Filename.concat "enum_values" "x86_64-linux-gnu.txt"

let parse_golden path : (string * int) list =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | exception End_of_file ->
      close_in ic;
      List.rev acc
    | line ->
      if String.length line = 0 then loop acc
      else (
        match String.rindex_opt line ' ' with
        | None -> loop acc (* malformed; ignore *)
        | Some i ->
          let name = String.sub line 0 i in
          let value = String.sub line (i + 1) (String.length line - i - 1) in
          (match int_of_string_opt value with
          | Some v -> loop ((name, v) :: acc)
          | None -> loop acc))
  in
  loop []

let test_enum_values_match_golden () =
  let path = golden_path () in
  if not (Sys.file_exists path) then
    Alcotest.skip ();
  let golden = parse_golden path in
  let generated : (string, int) Hashtbl.t = Hashtbl.create 8192 in
  List.iter (fun (name, value) -> Hashtbl.replace generated name value) V.Enum_values.all;
  let mismatches = ref [] in
  let add fmt = Printf.ksprintf (fun s -> mismatches := s :: !mismatches) fmt in
  let compared = ref 0 in
  List.iter
    (fun (name, golden_value) ->
      match Hashtbl.find_opt generated name with
      | None -> () (* only compare constants present on both sides *)
      | Some gen_value ->
        incr compared;
        if gen_value <> golden_value then
          add "%s: value mismatch: golden=%d generated=%d" name golden_value gen_value)
    golden;
  let mismatches = List.rev !mismatches in
  Alcotest.(check bool) "compared at least one constant present in both files" true (!compared > 0);
  if mismatches <> [] then (
    let first_20 = List.filteri (fun i _ -> i < 20) mismatches in
    Alcotest.failf "%d mismatch(es) between %s and Vk.Enum_values.all (first 20 shown):\n%s"
      (List.length mismatches) path
      (String.concat "\n" first_20))

let suite : unit Alcotest.test_case list =
  [ Alcotest.test_case "Vk.Enum_values.all matches the golden enum-values file" `Quick
      test_enum_values_match_golden ]
