(* Emit a C translation unit full of _Static_assert()s pinning the struct
   sizes and member offsets that ctypes computed for this library
   (Vk.Layout.all), so they can be checked against the real Vulkan headers
   with *any* C compiler -- including cross compilers for platforms we cannot
   run tests on (scripts/check_layout_win64.sh uses x86_64-w64-mingw32-gcc
   with -fsyntax-only).

   usage: layout_asserts.exe <golden-file> [platform-substrings...]
   - members of structs listed in the golden file are restricted to the
     members the golden file knows (it omits C bitfield members, whose
     offsetof is not valid C);
   - structs whose C name contains one of the platform substrings (e.g.
     "Win32" "D3D12" "FullScreenExclusive") are included in full. *)

let contains name sub =
  let ls = String.length sub and ln = String.length name in
  let rec go i = i + ls <= ln && (String.sub name i ls = sub || go (i + 1)) in
  go 0

let read_golden path =
  let tbl = Hashtbl.create 2048 in
  let ic = open_in path in
  let current = ref None in
  (try
     while true do
       let line = input_line ic in
       if line <> "" && line.[0] <> ' ' then begin
         let name = List.hd (String.split_on_char ' ' line) in
         current := Some name;
         Hashtbl.replace tbl name (Hashtbl.create 16)
       end else
         match !current, String.split_on_char ' ' (String.trim line) with
         | Some name, [ member; _ ] -> Hashtbl.replace (Hashtbl.find tbl name) member ()
         | _ -> ()
     done
   with End_of_file -> ());
  close_in ic;
  tbl

let () =
  let golden_path = Sys.argv.(1) in
  let platforms = Array.to_list (Array.sub Sys.argv 2 (Array.length Sys.argv - 2)) in
  let golden = read_golden golden_path in
  print_string "#define VK_ENABLE_BETA_EXTENSIONS 1\n";
  List.iter (fun p -> Printf.printf "/* platform substring: %s */\n" p) platforms;
  print_string "#include <vulkan/vulkan.h>\n#include <stddef.h>\n";
  let structs = ref 0 and asserts = ref 0 in
  List.iter
    (fun (name, size, fields) ->
      let platform = List.exists (contains name) platforms in
      let members =
        if platform then Some (fun _ -> true)
        else
          match Hashtbl.find_opt golden name with
          | Some known -> Some (fun m -> Hashtbl.mem known m)
          | None -> None
      in
      match members with
      | None -> ()
      | Some keep ->
        incr structs; incr asserts;
        Printf.printf "_Static_assert(sizeof(%s) == %d, \"sizeof %s\");\n" name size name;
        List.iter
          (fun (m, off) ->
            if keep m then begin
              incr asserts;
              Printf.printf "_Static_assert(offsetof(%s, %s) == %d, \"%s.%s\");\n" name m off name m
            end)
          fields)
    Vk.Layout.all;
  Printf.eprintf "layout_asserts: %d structs, %d assertions\n" !structs !asserts
