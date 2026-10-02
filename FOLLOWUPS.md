# Follow-ups

Known gaps and out-of-scope issues found during fork work. Each entry names where the issue is and a case that shows it. Remove an entry when its fix lands.

## Safe-rename check (`src/server/rols_rename_check.odin`)

- **Rename is skipped in inactive `when` branches.** `get_locals` in `src/server/locals.odin` takes only the `when` branch it evaluates as active. A local declared in an inactive branch has no symbol, so `ols query rename` on it reports "no symbol to rename at the position".
- **A field rename can capture a name inside a `using` procedure.** Given `limit :: 10` and `f :: proc(using foo: Foo) -> int { return limit }`, renaming `Foo.x` to `limit` passes the check. After the rename, `limit` in `f` means the field. `check_captures` returns early for `.Field` targets.
- **Nested blocks of a `using` procedure are not checked.** The reverse check in `check_embedders` compares the new field name only with the top-level scope of a procedure with a `using` parameter. A local of that name in a nested block is missed.
- **Only direct embedders are checked.** `check_embedders` checks structs with a `using` field of the renamed field's type. It does not check structs that embed those structs in turn.
- **`using` statements are not checked.** A `using x` statement inside a procedure body brings members into scope, and neither the collision scan nor the capture scan covers it.
- **Field renames cost a workspace scan.** Every rename of a field in a named struct runs `find_symbol_references` on the owner type across the workspace, plus one type resolution for each `using` field found.
