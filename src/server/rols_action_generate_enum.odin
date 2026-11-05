#+private file
package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// A sparse table has one entry per value from the lowest to the highest. Over this span it takes megabytes, and with
// `B = 1 << 40` it no longer builds.
TABLE_SPAN_MAX :: 1 << 16

// On the name of a top-level enum: "Generate bit_set", which declares `Flags :: bit_set[Flag]` for `Flag`, else
// `<Enum>_Set`, and "Generate name table", which declares `<ENUM>_NAMES` with each member's name. Both go after the
// enum and need the value of every member.
@(private = "package")
add_generate_enum_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_generate_enum {
		return
	}
	decl, found := top_decl_at(ctx.document, ctx.range.start)
	if !found || decl.is_mutable || decl.type != nil || len(decl.values) != 1 {
		return
	}
	if _, is_enum := decl.values[0].derived.(^ast.Enum_Type); !is_enum {
		return
	}
	reset_ast_context(ctx.ast_context)
	symbol, resolved := resolve_type_expression(ctx.ast_context, decl.values[0])
	members, is_enum := symbol.value.(SymbolEnumValue)
	if !resolved || !is_enum || len(members.names) == 0 {
		return
	}
	values, classes := enum_member_values(ctx.ast_context, members)
	low, high := max(int), min(int)
	count := 0
	for value, i in values {
		n, known := value.?
		if !known {
			return
		}
		low, high = min(low, n), max(high, n)
		if classes[i] == i {
			count += 1
		}
	}

	src := ctx.document.ast.src
	name := node_text(src, decl.names[0])
	// A bit_set holds at most 128 bits, counted from bit 0 for an enum that starts above 0.
	if low >= 0 && high <= 127 {
		set_name := "Flags" if name == "Flag" else strings.concatenate({name, "_Set"}, context.temp_allocator)
		add_generated(ctx, decl, "Generate bit_set", set_name, fmt.tprintf("%s :: bit_set[%s]", set_name, name))
	}

	// A `_` member has no name to key its entry, and an enumerated array literal must list every value.
	if slice.contains(members.names, "_") || high - low >= TABLE_SPAN_MAX {
		return
	}
	// An alias shares the value of its member, and a second key for one value does not compile.
	width := 0
	for member, i in members.names {
		if classes[i] == i {
			width = max(width, strings.rune_count(member))
		}
	}
	table := strings.concatenate(
		{strings.to_screaming_snake_case(name, context.temp_allocator), "_NAMES"},
		context.temp_allocator,
	)
	unit := indent_unit(src, "", nil)
	sb := strings.builder_make(context.temp_allocator)
	// An enumerated array over an enum with gaps between its values needs `#sparse`.
	sparse := "#sparse" if high - low + 1 != count else ""
	fmt.sbprintf(&sb, "%s := %s[%s]string {{\n", table, sparse, name)
	for member, i in members.names {
		if classes[i] != i {
			continue
		}
		padding := strings.repeat(" ", width - strings.rune_count(member), context.temp_allocator)
		fmt.sbprintf(&sb, "%s.%s%s = \"%s\",\n", unit, member, padding, member)
	}
	strings.write_string(&sb, "}")
	add_generated(ctx, decl, "Generate name table", table, strings.to_string(sb))
}
