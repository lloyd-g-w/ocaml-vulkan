include Vk_base.Public
include Vk_consts
include Vk_enums
include Vk_handles
include Vk_types_01
include Vk_types_02
include Vk_types_03
include Vk_types_04
include Vk_types_05
include Vk_types_06
include Vk_types_07
include Vk_types_08
include Vk_types_09
include Vk_types_10
include Vk_types_11
include Vk_types_12
include Vk_types_13
include Vk_types_14
include Vk_types_15
module Fn = Vk_fn
include Vk_api
module Loader = struct
  include Vk_base.Loader
  let load_instance = Vk_fn.load_instance
  let load_device = Vk_fn.load_device
  let get_instance_proc_addr instance name =
    Vk_base.Loader.get_instance_proc_addr
      (Ctypes.ptr_of_raw_address (Instance.to_nativeint instance)) name
  let get_device_proc_addr device name =
    Vk_base.Loader.get_device_proc_addr
      (Ctypes.ptr_of_raw_address (Device.to_nativeint device)) name
end
module Layout = Vk_layout
module Enum_values = Vk_enum_values
