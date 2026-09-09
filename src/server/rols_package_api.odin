package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// The exported symbols of the package at dir, one line each sorted by name, or with name that symbol's
// full signature and docs. dir is the clean forward-slash absolute directory the index keys packages by.
get_package_api :: proc(dir: string, name := "") -> (text: string, ok: bool) {
	try_build_package(dir)
	pkg := indexer.index.collection.packages[dir] or_return
	ast_context := make_ast_context({}, {}, dir, "", "")
	sb := strings.builder_make(context.temp_allocator)

	if name != "" {
		symbol := pkg.symbols[name] or_return
		if is_private(symbol) {
			return
		}
		fmt.sbprintf(&sb, "%s :: %s\n", name, get_signature(&ast_context, symbol))
		if docs := construct_symbol_docs(symbol); docs != "" {
			strings.write_string(&sb, strings.trim_right_space(docs))
			strings.write_byte(&sb, '\n')
		}
		return strings.to_string(sb), true
	}

	names := make([dynamic]string, context.temp_allocator)
	for key, symbol in pkg.symbols {
		if !is_private(symbol) {
			append(&names, key)
		}
	}
	slice.sort(names[:])

	for key in names {
		symbol := pkg.symbols[key]
		separator := ": " if .Mutable in symbol.flags else " :: "
		fmt.sbprintf(&sb, "%s%s%s\n", key, separator, first_line(short_signature(&ast_context, symbol)))
		if docs := construct_symbol_docs(symbol); docs != "" {
			fmt.sbprintf(&sb, "\t%s\n", first_line(docs))
		}
	}
	return strings.to_string(sb), len(names) > 0
}

@(private = "file")
is_private :: proc(symbol: Symbol) -> bool {
	return .PrivateFile in symbol.flags || .PrivatePackage in symbol.flags
}

@(private = "file")
first_line :: proc(s: string) -> string {
	line, _, _ := strings.partition(s, "\n")
	return strings.trim_space(line)
}

// get_short_signature elides aggregate bodies as `struct {..}` and proc groups as `proc (..)`.
@(private = "file")
short_signature :: proc(ast_context: ^AstContext, symbol: Symbol) -> string {
	#partial switch v in symbol.value {
	case SymbolProcedureGroupValue:
		if group, is_group := v.group.derived.(^ast.Proc_Group); is_group {
			members := make([]string, len(group.args), context.temp_allocator)
			for arg, i in group.args {
				members[i] = node_to_string(arg)
			}
			return strings.concatenate(
				{"proc {", strings.join(members, ", ", context.temp_allocator), "}"},
				context.temp_allocator,
			)
		}
	case SymbolStructValue, SymbolUnionValue, SymbolEnumValue, SymbolBitFieldValue:
		signature := get_short_signature(ast_context, symbol)
		return strings.trim_suffix(strings.trim_suffix(signature, " {..}"), "{}")
	}
	return get_short_signature(ast_context, symbol)
}
