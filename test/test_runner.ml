(* test_runner.ml -- single alcotest entry point wiring together the suites
   defined in test_enums.ml/test_layout.ml/test_structs.ml/test_instance.ml/
   test_compute.ml/test_graphics.ml (DESIGN.md §12). Not itself one of the
   six files the task lists, but the minimal glue needed for `dune runtest`
   to run them all as one alcotest report; each of those files defines a
   `suite : unit Alcotest.test_case list` rather than calling Alcotest.run
   itself. See each file's own TODO block for compile-time assumptions --
   this file cannot build until lib/vk.ml has real content either. *)

let () =
  Alcotest.run "vulkan"
    [ ("enums", Test_enums.suite);
      ("layout", Test_layout.suite);
      ("structs", Test_structs.suite);
      ("instance", Test_instance.suite);
      ("compute", Test_compute.suite);
      ("graphics", Test_graphics.suite)
    ]
