open Ctypes

(* Vulkan's public scalar values are ordinary OCaml ints.  The uint64 view
   preserves two's-complement spellings, so -1 is VK_WHOLE_SIZE. *)
let uint8 = view ~read:Unsigned.UInt8.to_int ~write:Unsigned.UInt8.of_int uint8_t
let uint16 = view ~read:Unsigned.UInt16.to_int ~write:Unsigned.UInt16.of_int uint16_t
let uint32 = view ~read:Unsigned.UInt32.to_int ~write:Unsigned.UInt32.of_int uint32_t
let uint64 =
  view
    ~read:(fun x -> Int64.to_int (Unsigned.UInt64.to_int64 x))
    ~write:(fun x -> Unsigned.UInt64.of_int64 (Int64.of_int x))
    uint64_t
let int8 = int8_t
let int16 = int16_t
let int32 = view ~read:Int32.to_int ~write:Int32.of_int int32_t
let int64 = view ~read:Int64.to_int ~write:Int64.of_int int64_t
let size_t = view ~read:Unsigned.Size_t.to_int ~write:Unsigned.Size_t.of_int size_t
let device_size = uint64
let device_address = uint64
let bool32 =
  view
    ~read:(fun x -> not (Unsigned.UInt32.equal x Unsigned.UInt32.zero))
    ~write:(fun x -> Unsigned.UInt32.of_int (if x then 1 else 0))
    uint32_t

module type ENUM = sig
  type t = private int
  val t : t typ
  val of_int : int -> t
  val to_int : t -> int
  val register : (t * string) list -> unit
  val to_string : t -> string
  val pp : Format.formatter -> t -> unit
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Enum32 () : ENUM = struct
  type t = int
  let t = view ~read:(fun x -> x) ~write:(fun x -> x) int32
  let of_int x = x
  let to_int x = x
  let names = ref []
  let register xs = names := xs
  let to_string x =
    match List.find_opt (fun (v, _) -> v = x) !names with
    | Some (_, name) -> name
    | None -> Printf.sprintf "Enum32(%d)" x
  let pp fmt x = Format.pp_print_string fmt (to_string x)
  let equal (a : t) b = a = b
  let compare (a : t) b = Stdlib.compare a b
end

module Enum64 () : ENUM = struct
  type t = int
  let t = view ~read:(fun x -> x) ~write:(fun x -> x) int64
  let of_int x = x
  let to_int x = x
  let names = ref []
  let register xs = names := xs
  let to_string x =
    match List.find_opt (fun (v, _) -> v = x) !names with
    | Some (_, name) -> name
    | None -> Printf.sprintf "Enum64(%d)" x
  let pp fmt x = Format.pp_print_string fmt (to_string x)
  let equal (a : t) b = a = b
  let compare (a : t) b = Stdlib.compare a b
end

module type FLAGS = sig
  include ENUM
  val empty : t
  val ( lor ) : t -> t -> t
  val ( land ) : t -> t -> t
  val union : t -> t -> t
  val inter : t -> t -> t
  val diff : t -> t -> t
  val mem : t -> t -> bool
  val of_list : t list -> t
  val to_list : t -> t list
end

module Flags32 () : FLAGS = struct
  type t = int
  let t = view ~read:(fun x -> x) ~write:(fun x -> x) uint32
  let of_int x = x
  let to_int x = x
  let names = ref []
  let register xs = names := xs
  let empty = 0
  let ( lor ) a b = Stdlib.(a lor b)
  let ( land ) a b = Stdlib.(a land b)
  let union = ( lor )
  let inter = ( land )
  let diff a b = Stdlib.(a land (lnot b))
  let mem flags bit = bit <> 0 && Stdlib.(flags land bit) = bit
  let of_list xs = List.fold_left ( lor ) empty xs
  let is_single_bit x = x <> 0 && Stdlib.(x land (x - 1)) = 0
  let to_list x =
    !names
    |> List.filter_map (fun (v, _) -> if is_single_bit v && mem x v then Some v else None)
    |> List.sort_uniq Stdlib.compare
  let to_string x =
    match List.find_opt (fun (v, _) -> v = x) !names with
    | Some (_, name) -> name
    | None ->
        let parts =
          !names
          |> List.filter (fun (v, _) -> is_single_bit v && mem x v)
          |> List.sort_uniq (fun (a, _) (b, _) -> Stdlib.compare a b)
          |> List.map snd
        in
        if parts = [] then Printf.sprintf "Flags32(0x%x)" x
        else String.concat " | " parts
  let pp fmt x = Format.pp_print_string fmt (to_string x)
  let equal (a : t) b = a = b
  let compare (a : t) b = Stdlib.compare a b
end

module Flags64 () : FLAGS = struct
  type t = int
  let t = view ~read:(fun x -> x) ~write:(fun x -> x) uint64
  let of_int x = x
  let to_int x = x
  let names = ref []
  let register xs = names := xs
  let empty = 0
  let ( lor ) a b = Stdlib.(a lor b)
  let ( land ) a b = Stdlib.(a land b)
  let union = ( lor )
  let inter = ( land )
  let diff a b = Stdlib.(a land (lnot b))
  let mem flags bit = bit <> 0 && Stdlib.(flags land bit) = bit
  let of_list xs = List.fold_left ( lor ) empty xs
  let is_single_bit x = x <> 0 && Stdlib.(x land (x - 1)) = 0
  let to_list x =
    !names
    |> List.filter_map (fun (v, _) -> if is_single_bit v && mem x v then Some v else None)
    |> List.sort_uniq Stdlib.compare
  let to_string x =
    match List.find_opt (fun (v, _) -> v = x) !names with
    | Some (_, name) -> name
    | None ->
        let parts =
          !names
          |> List.filter (fun (v, _) -> is_single_bit v && mem x v)
          |> List.sort_uniq (fun (a, _) (b, _) -> Stdlib.compare a b)
          |> List.map snd
        in
        if parts = [] then Printf.sprintf "Flags64(0x%x)" x
        else String.concat " | " parts
  let pp fmt x = Format.pp_print_string fmt (to_string x)
  let equal (a : t) b = a = b
  let compare (a : t) b = Stdlib.compare a b
end

module type HANDLE = sig
  type t
  val t : t typ
  val null : t
  val is_null : t -> bool
  val equal : t -> t -> bool
  val to_int64 : t -> int64
  val of_int64 : int64 -> t
  val to_nativeint : t -> nativeint
  val of_nativeint : nativeint -> t
  val to_string : t -> string
end

module Dispatchable () : HANDLE = struct
  type t = unit ptr
  let t = ptr void
  let null = null
  let is_null = is_null
  let equal a b = ptr_compare a b = 0
  let to_nativeint = raw_address_of_ptr
  let of_nativeint = ptr_of_raw_address
  let to_int64 x = Int64.of_nativeint (to_nativeint x)
  let of_int64 x = of_nativeint (Int64.to_nativeint x)
  let to_string x = Printf.sprintf "0x%nx" (to_nativeint x)
end

module Non_dispatchable () : HANDLE = struct
  type t = int64
  let t = view ~read:Unsigned.UInt64.to_int64 ~write:Unsigned.UInt64.of_int64 uint64_t
  let null = 0L
  let is_null x = x = 0L
  let equal (a : t) b = a = b
  let to_int64 x = x
  let of_int64 x = x
  let to_nativeint = Int64.to_nativeint
  let of_nativeint = Int64.of_nativeint
  let to_string x = Printf.sprintf "0x%Lx" x
end

type next = Next : 'a structure -> next
let next value = Next value
let next_pointer (Next value) = to_voidp (addr value)

let make_kept typ =
  let keep = ref [] in
  let value =
    Ctypes.make ~finalise:(fun _ -> ignore (Sys.opaque_identity !keep)) typ
  in
  value, keep
let retain keep value = keep := Obj.repr value :: !keep
let null_ptr typ = from_voidp typ null

let string_of_char_array chars =
  let length = CArray.length chars in
  let rec stop i =
    if i = length || CArray.get chars i = '\000' then i else stop (i + 1)
  in
  String.init (stop 0) (CArray.get chars)

let string_of_char_ptr p =
  if is_null p then "" else coerce (ptr char) string p

let carray_of_strings values =
  let strings = List.map CArray.of_string values in
  let pointers = CArray.of_list (ptr char) (List.map CArray.start strings) in
  strings, pointers

let uint32_carray_of_bytes bytes =
  let length = String.length bytes in
  let words = CArray.make uint32 ((length + 3) / 4) in
  for i = 0 to CArray.length words - 1 do
    let word = ref 0 in
    for j = 0 to 3 do
      let k = (i * 4) + j in
      if k < length then word := !word lor (Char.code bytes.[k] lsl (8 * j))
    done;
    CArray.set words i !word
  done;
  words

let make_api_version ?(variant = 0) major minor patch =
  (variant lsl 29) lor (major lsl 22) lor (minor lsl 12) lor patch
let make_version major minor patch = make_api_version major minor patch
let api_version_1_0 = make_api_version 1 0 0
let api_version_1_1 = make_api_version 1 1 0
let api_version_1_2 = make_api_version 1 2 0
let api_version_1_3 = make_api_version 1 3 0
let api_version_1_4 = make_api_version 1 4 0
let version_variant version = version lsr 29
let version_major version = (version lsr 22) land 0x7f
let version_minor version = (version lsr 12) land 0x3ff
let version_patch version = version land 0xfff
let string_of_version version =
  Printf.sprintf "%d.%d.%d" (version_major version) (version_minor version)
    (version_patch version)
let whole_size = -1

exception Not_loaded of string
let not_loaded name = raise (Not_loaded name)

module Loader = struct
  let library : Dl.library option ref = ref None
  let get_instance : (unit ptr -> string -> unit ptr) option ref = ref None
  let get_device : (unit ptr -> string -> unit ptr) option ref = ref None
  let loaded = ref false
  let global_hook = ref (fun () -> ())
  let instance_hook : (unit ptr -> unit) ref = ref (fun _ -> ())
  let device_hook : (unit ptr -> unit) ref = ref (fun _ -> ())

  let default_library () =
    match Sys.os_type with
    | "Win32" | "Cygwin" -> "vulkan-1.dll"
    | "Unix" when Sys.file_exists "/System/Library" -> "libvulkan.1.dylib"
    | _ -> "libvulkan.so.1"

  let load ?library:requested () =
    if not !loaded then begin
      let filename =
        match requested, Sys.getenv_opt "OCAML_VULKAN_LIBRARY" with
        | Some x, _ -> x
        | None, Some x -> x
        | None, None -> default_library ()
      in
      let lib = Dl.dlopen ~filename ~flags:Dl.[ RTLD_NOW; RTLD_LOCAL ] in
      let signature = ptr void @-> string @-> returning (ptr void) in
      let gipa = Foreign.foreign ~from:lib "vkGetInstanceProcAddr" signature in
      let gdpa = Foreign.foreign ~from:lib "vkGetDeviceProcAddr" signature in
      library := Some lib;
      get_instance := Some gipa;
      get_device := Some gdpa;
      loaded := true;
      !global_hook ()
    end

  let ensure () = load ()

  let get_instance_proc_addr instance name =
    ensure ();
    match !get_instance with Some f -> f instance name | None -> assert false

  let get_device_proc_addr device name =
    ensure ();
    match !get_device with Some f -> f device name | None -> assert false

  let load_instance instance = ensure (); !instance_hook instance
  let load_device device = ensure (); !device_hook device
end

module Public = struct
  type nonrec next = next
  let next = next
  let string_of_char_array = string_of_char_array
  let string_of_char_ptr = string_of_char_ptr
  let make_api_version = make_api_version
  let make_version = make_version
  let api_version_1_0 = api_version_1_0
  let api_version_1_1 = api_version_1_1
  let api_version_1_2 = api_version_1_2
  let api_version_1_3 = api_version_1_3
  let api_version_1_4 = api_version_1_4
  let version_variant = version_variant
  let version_major = version_major
  let version_minor = version_minor
  let version_patch = version_patch
  let string_of_version = string_of_version
  let whole_size = whole_size
  exception Not_loaded = Not_loaded
  module Loader = Loader
end
