import Lake
open Lake DSL

package utf8_repro

@[default_target]
lean_lib Repro where
  srcDir := "out"

lean_lib Valid where
  srcDir := "out"
