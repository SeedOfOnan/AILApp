import Lake
open Lake DSL

package "AILApp" where
  -- PIC18 application written in AIL (AST-direct form).
  -- Depends on the AIL compiler library in the sibling AIL/ directory.

require AIL from "../AIL"

@[default_target]
lean_exe ailapp where
  root := `src.App
