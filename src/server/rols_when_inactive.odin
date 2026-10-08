package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"

// The target that build_target_package collects a package for, which resolve_when_ident and host_target read
// before the profile. Thread-local, so a collection in a test does not move other tests' targets.
@(thread_local)
when_target: Maybe(parser.Build_Target)

// The target whose ODIN_OS and ODIN_ARCH the `when` conditions of this thread read before when_target. It is set
// while the lints walk a file that the host does not build, and while a document's globals or locals evaluate their
// `when` statements (use_file_when_target), for the target that builds that file. Unlike when_target, it leaves
// host_target alone, so the lookups of that file still find the declarations of its target (see rols_excluded.odin).
@(thread_local)
when_eval_target: Maybe(parser.Build_Target)

// Sets when_eval_target to the target that builds the file of ast_context when the host does not build it and no
// caller set a target, so hover, references, lints and semantic tokens take the same `when` branch there. Returns
// the value to restore.
use_file_when_target :: proc(ast_context: ^AstContext) -> (saved: Maybe(parser.Build_Target)) {
	saved = when_eval_target
	if saved != nil do return
	if target, has_target := file_target(ast_context.fullpath); has_target do when_eval_target = target
	return
}

// The value of ODIN_OS or ODIN_ARCH under when_eval_target, else when_target, spelled as resolve_when_ident spells
// it.
when_target_ident :: proc(ident: string) -> (value: When_Expr, ok: bool) {
	target, evaluated := when_eval_target.?
	if !evaluated do target = when_target.? or_return
	switch ident {
	case "ODIN_OS":
		return fmt.tprint(target.os), true
	case "ODIN_ARCH":
		return fmt.tprint(target.arch), true
	}
	return nil, false
}

// Adds the constants of file outside any `when` to plain, by name.
@(private = "package")
add_plain_consts :: proc(plain: ^map[string]^ast.Expr, file: ^ast.File) {
	for decl in file.decls {
		value_decl := decl.derived.(^ast.Value_Decl) or_continue
		if value_decl.is_mutable do continue
		for name, i in value_decl.names {
			ident := name.derived.(^ast.Ident) or_continue
			if i < len(value_decl.values) do plain[ident.name] = value_decl.values[i]
		}
	}
}
