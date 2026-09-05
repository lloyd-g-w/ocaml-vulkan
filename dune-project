(lang dune 3.10)

(name vulkan)

(generate_opam_files true)

(source
 (github lloyd-g-w/ocaml-vulkan))

(authors "Lloyd Williams")

(maintainers "Lloyd Williams")

(license GPL-3.0-only)

(documentation https://github.com/lloyd-g-w/ocaml-vulkan)

(package
 (name vulkan)
 (synopsis "OCaml bindings to the Vulkan graphics and compute API")
 (description
  "Complete, generated bindings to Vulkan (core 1.0-1.4 and all registry extensions) built on ctypes. Provides a faithful raw layer plus an ergonomic OCaml layer with labelled struct constructors, lists instead of count/pointer pairs and exceptions for VkResult errors. Loads libvulkan at runtime, no C stubs or headers required.")
 (depends
  (ocaml (>= 4.14))
  (ctypes (>= 0.20))
  (ctypes-foreign (>= 0.20))
  integers
  (alcotest :with-test)
  (odoc :with-doc))
 (tags
  (vulkan graphics gpu compute bindings ctypes)))
