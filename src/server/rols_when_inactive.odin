package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"

// The target that build_target_package collects a package for, which resolve_when_ident and host_target read
// before the profile. Thread-local, so a collection in a test does not move other tests' targets.
@(thread_local)
when_target: Maybe(parser.Build_Target)

// The value of ODIN_OS or ODIN_ARCH under when_target, spelled as resolve_when_ident spells it.
when_target_ident :: proc(ident: string) -> (value: When_Expr, ok: bool) {
	target := when_target.? or_return
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
