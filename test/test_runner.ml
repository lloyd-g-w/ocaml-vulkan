(* test_runner.ml -- single alcotest entry point wiring together the suites
   defined in test_enums.ml/test_layout.ml/test_structs.ml/test_instance.ml/
   test_compute.ml/test_graphics.ml/test_enum_values.ml (DESIGN.md §12);
   each of those files defines a `suite : unit Alcotest.test_case list`
   rather than calling Alcotest.run itself. *)

let () =
  Alcotest.run "vulkan"
    [ ("enums", Test_enums.suite);
      ("layout", Test_layout.suite);
      ("enum_values", Test_enum_values.suite);
      ("structs", Test_structs.suite);
      ("instance", Test_instance.suite);
      ("compute", Test_compute.suite);
      ("graphics", Test_graphics.suite)
    ]
