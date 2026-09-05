(* Sanity check for the vk_test_shaders library: every embedded SPIR-V blob
   must start with the SPIR-V magic number 0x07230203 (little-endian, as
   produced by glslc) and have a length divisible by 4 (SPIR-V is a stream of
   32-bit words). Runs with `dune build -j 2 shaders` / `dune runtest`; does
   not depend on the vk library (which doesn't exist in this lane's clone
   yet, see DESIGN.md) or on a Vulkan driver. *)

let spirv_magic = 0x07230203

let check name blob =
  let len = String.length blob in
  if len < 4 || len mod 4 <> 0 then (
    Printf.eprintf "check_magic: %s: length %d is not a positive multiple of 4\n"
      name len;
    exit 1);
  let byte i = Char.code blob.[i] in
  let magic = byte 0 lor (byte 1 lsl 8) lor (byte 2 lsl 16) lor (byte 3 lsl 24) in
  if magic <> spirv_magic then (
    Printf.eprintf "check_magic: %s: magic 0x%08x <> expected 0x%08x\n" name magic
      spirv_magic;
    exit 1);
  Printf.printf "check_magic: %s: OK (%d bytes, magic 0x%08x)\n" name len magic

let () =
  check "double_comp" Vk_test_shaders.double_comp;
  check "triangle_vert" Vk_test_shaders.triangle_vert;
  check "triangle_frag" Vk_test_shaders.triangle_frag
