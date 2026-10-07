package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "src:common"

// Every verb core:fmt accepts; see core/fmt/doc.odin.
@(private = "file")
VERBS :: "vwTtbcrodizxXUmMeEfFgGhHsqp"

lint_printf :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_printf do return
	call, is_call := node.derived.(^ast.Call_Expr)
	if !is_call do return

	name, ok := printf_callee(ctx, call)
	if !ok do return

	index := format_index(name)
	if index < 0 {
		lint_print_directive(ctx, call, name, diags)
		return
	}
	if len(call.args) <= index do return
	for arg in call.args {
		// A spread hides how many arguments the call really passes.
		if _, is_spread := arg.derived.(^ast.Ellipsis); is_spread do return
	}

	text, is_string := string_literal(call.args[index])
	if !is_string do return
	lit := call.args[index]
	args := call.args[index + 1:]
	for len(args) > 0 {
		if _, is_named := args[len(args) - 1].derived.(^ast.Field_Value); !is_named do break
		args = args[:len(args) - 1]
	}

	format := parse_format(text)
	// A call with several results passes them all, so a format index can land inside one argument.
	// owner[k] is the argument that passes value k, and results[i] how many values argument i passes.
	owner := make([dynamic]int, context.temp_allocator)
	results := make([]int, len(args), context.temp_allocator)
	exact := true
	for arg, i in args {
		count, known := arg_results(ctx, arg)
		if !known {
			exact = false
			break
		}
		results[i] = count
		for _ in 0 ..< count do append(&owner, i)
	}
	arg_count := len(owner)

	for bad in format.unknown {
		message := bad == 0 ? "unknown format verb '%'" : fmt.tprintf("unknown format verb '%%%r'", bad)
		append(diags, printf_diagnostic(ctx, lit, "printf-verb", message))
	}

	// With an unknown argument count, only the types of the values before that argument are checked.
	if exact && format.needed > arg_count {
		append(
			diags,
			printf_diagnostic(
				ctx,
				lit,
				"printf-arity",
				fmt.tprintf("format needs %d arguments, call has %d", format.needed, arg_count),
			),
		)
	} else if exact {
		// core:fmt prints every argument that no verb or `*` read as %!(EXTRA …).
		extra, first := 0, -1
		for k in 0 ..< min(arg_count, 64) {
			if k in format.used do continue
			extra += 1
			if first < 0 do first = k
		}
		if extra > 0 {
			append(
				diags,
				printf_diagnostic(
					ctx,
					args[owner[first]],
					"printf-arity",
					fmt.tprintf("call has %d extra argument%s", extra, extra == 1 ? "" : "s"),
				),
			)
		}
	}

	for use in format.uses {
		if use.arg >= len(owner) do continue
		arg := owner[use.arg]
		// One value of a multi-value call has a type the lint does not know.
		if results[arg] != 1 do continue
		kind := arg_kind(ctx, args[arg])
		if !verb_rejects(use.verb, kind) do continue
		append(
			diags,
			printf_diagnostic(
				ctx,
				args[arg],
				"printf-type",
				fmt.tprintf("format verb '%%%r' does not accept %s", use.verb, kind_names[kind]),
			),
		)
	}
}

// The number of arguments the call passes, counting every result of a multi-value call.
// exact is false when an argument passes an unknown number of values.
expanded_arg_count :: proc(ctx: ^LintContext, args: []^ast.Expr) -> (count: int, exact: bool) {
	for arg in args {
		results := arg_results(ctx, arg) or_return
		count += results
	}
	return count, true
}

// How many values an argument passes. known is false for a call whose callee does not resolve,
// and for a procedure group call whose members return different numbers of results.
@(private = "file")
arg_results :: proc(ctx: ^LintContext, arg: ^ast.Expr) -> (results: int, known: bool) {
	call, is_call := arg.derived.(^ast.Call_Expr)
	// `x->f()` wraps the call `x->f(x)`.
	if selector_call, is_selector_call := arg.derived.(^ast.Selector_Call_Expr); is_selector_call {
		call, is_call = selector_call.call, selector_call.call != nil
	}
	if !is_call do return 1, true
	callee := ast.unparen_expr(call.expr)
	#partial switch _ in callee.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
	case ^ast.Call_Expr,
	     ^ast.Index_Expr,
	     ^ast.Deref_Expr,
	     ^ast.Type_Assertion,
	     ^ast.Proc_Lit,
	     ^ast.Ternary_If_Expr,
	     ^ast.Ternary_When_Expr:
		// The resolve map holds named callees only, so `f()()` or `arr[i]()` resolves here. A call
		// resolves to the procedure it calls, which for `f()()` is the procedure that f returns.
		return callee_results(ctx, call)
	case:
		// A conversion such as `(^int)(p)`, or a directive such as `#location()`.
		return 1, true
	}
	resolved, ok := lint_symbols(ctx)[uintptr(callee)]
	if !ok || resolved.is_unresolved || resolved.symbol == nil do return callee_results(ctx, callee)

	if names_proc_type(resolved.symbol^) do return 1, true
	#partial switch v in resolved.symbol.value {
	case SymbolProcedureValue:
		return proc_results(v), true
	case SymbolAggregateValue:
		// The whole-file resolve keeps every group member that fits the arguments.
		return members_results(v.symbols)
	case SymbolProcedureGroupValue:
		return callee_results(ctx, callee)
	case SymbolPolyTypeValue, SymbolGenericValue:
		// A value of a poly type, such as `fp: $F`, may be a procedure with any number of results.
		if resolved.symbol.type == .Variable do return 1, false
	}
	return 1, true
}

// The values passed by the procedure that expr resolves to with the locals visible at it. A group
// call whose overload does not resolve, as with an argument of a poly type, resolves without the
// call to every member of the group, and passes a known number of values when they all agree.
// A callee that resolves to a type, as in `Vec(int)(v)`, or a name of a procedure type, as in `Callback(f)`,
// is a conversion and passes one value. The call of an unnamed callee such as `arr[i]()` resolves to the
// procedure type of `arr`'s elements, so only a name counts as a procedure type.
@(private = "file")
callee_results :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> (int, bool) {
	symbol, ok := resolve_callee(ctx, expr)
	if !ok do return 1, false
	if _, is_call := expr.derived.(^ast.Call_Expr); !is_call && names_proc_type(symbol) do return 1, true
	#partial switch v in symbol.value {
	case SymbolProcedureValue:
		return proc_results(v), true
	case SymbolAggregateValue:
		return members_results(v.symbols)
	case SymbolProcedureGroupValue, SymbolGenericValue, SymbolPolyTypeValue, SymbolPackageValue, SymbolUntypedValue:
		return 1, false
	}
	return 1, true
}

// expr resolved with the locals visible at it, or with the package globals when that fails. The context shares
// the walker's globals, since collecting them walks every declaration of the file, which for each argument made
// a lint run quadratic.
@(private = "file")
resolve_callee :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> (Symbol, bool) {
	document := ctx.document
	position := common.get_token_range(expr, ctx.src).start
	if position_context, found := get_document_position_context(document, position, .Hover); found {
		ast_context := make_ast_context(
			document.ast,
			document.imports,
			document.package_name,
			document.uri.uri,
			document.fullpath,
			context.temp_allocator,
		)
		ast_context.globals = ctx.ast_context.globals
		ast_context.position_hint = position_context.hint
		get_locals(&ast_context, &position_context)
		if symbol, ok := resolve_type_expression(&ast_context, expr); ok do return symbol, true
	}
	return resolve_type_with(ctx.ast_context, document.package_name, expr)
}

@(private = "file")
members_results :: proc(members: []Symbol) -> (results: int, known: bool) {
	if len(members) == 0 do return 1, false
	results = -1
	for member in members {
		value, is_proc := member.value.(SymbolProcedureValue)
		if !is_proc do return 1, false
		count := proc_results(value)
		if results >= 0 && count != results do return 1, false
		results = count
	}
	return results, true
}

@(private = "file")
proc_results :: proc(value: SymbolProcedureValue) -> int {
	// #optional_ok and #optional_allocator_error procs yield one value where an argument is wanted.
	if len(value.return_types) == 0 || value.tags & {.Optional_Ok, .Optional_Allocator_Error} != {} do return 1
	results := 0
	for field in value.return_types do results += max(len(field.names), 1)
	return results
}

@(private = "file")
lint_print_directive :: proc(ctx: ^LintContext, call: ^ast.Call_Expr, name: string, diags: ^[dynamic]Diagnostic) {
	if !slice.contains(print_procs, name) do return
	first := strings.has_prefix(name, "sb") ? 1 : 0
	if len(call.args) <= first do return
	text, is_string := string_literal(call.args[first])
	if !is_string do return

	for i in 0 ..< len(text) - 1 {
		if text[i] != '%' do continue
		verb, _ := utf8.decode_rune_in_string(text[i + 1:])
		if !strings.contains_rune(VERBS, verb) do continue

		formatting :=
			strings.has_suffix(name, "ln") ? fmt.tprintf("%sfln", name[:len(name) - 2]) : fmt.tprintf("%sf", name)
		append(
			diags,
			printf_diagnostic(
				ctx,
				call.args[first],
				"print-directive",
				fmt.tprintf("'%%%r' looks like a format directive; use %s", verb, formatting),
			),
		)
		return
	}
}

@(private = "file")
print_procs := []string {
	"print",
	"println",
	"eprint",
	"eprintln",
	"aprint",
	"aprintln",
	"tprint",
	"tprintln",
	"sbprint",
	"sbprintln",
	"debug",
	"info",
	"warn",
	"error",
	"fatal",
	"panic",
}

// The index of the format argument, or -1 when the procedure takes no format.
@(private = "file")
format_index :: proc(name: string) -> int {
	switch name {
	case "printf",
	     "printfln",
	     "eprintf",
	     "eprintfln",
	     "aprintf",
	     "aprintfln",
	     "tprintf",
	     "tprintfln",
	     "caprintf",
	     "caprintfln",
	     "ctprintf",
	     "ctprintfln",
	     "panicf",
	     "debugf",
	     "infof",
	     "warnf",
	     "errorf",
	     "fatalf":
		return 0
	case "bprintf",
	     "bprintfln",
	     "assertf",
	     "ensuref",
	     "sbprintf",
	     "sbprintfln",
	     "wprintf",
	     "wprintfln",
	     "fprintf",
	     "fprintfln",
	     "logf":
		return 1
	}
	return -1
}

// The name of the called procedure when it resolves into core:fmt or core:log.
@(private = "file")
printf_callee :: proc(ctx: ^LintContext, call: ^ast.Call_Expr) -> (string, bool) {
	if _, is_selector := call.expr.derived.(^ast.Selector_Expr); !is_selector do return "", false
	resolved, is_resolved := lint_symbols(ctx)[uintptr(call.expr)]
	if !is_resolved || resolved.is_unresolved do return "", false
	sym := resolved.symbol
	if !strings.has_suffix(sym.pkg, "/fmt") && !strings.has_suffix(sym.pkg, "/log") do return "", false
	return sym.name, true
}

@(private = "file")
string_literal :: proc(expr: ^ast.Expr) -> (string, bool) {
	lit, is_lit := expr.derived.(^ast.Basic_Lit)
	if !is_lit || lit.tok.kind != .String || len(lit.tok.text) < 2 do return "", false
	return lit.tok.text[1:len(lit.tok.text) - 1], true
}

@(private = "file")
printf_diagnostic :: proc(ctx: ^LintContext, node: ^ast.Expr, code, message: string) -> Diagnostic {
	return Diagnostic {
		range = common.get_token_range(node, ctx.src),
		severity = .Warning,
		code = code,
		message = message,
	}
}

@(private = "file")
Format_Use :: struct {
	arg:  int,
	verb: rune,
}

@(private = "file")
Format :: struct {
	uses:    [dynamic]Format_Use,
	unknown: [dynamic]rune, // 0 stands for a trailing '%'
	needed:  int, // one past the highest argument index the format reads
	used:    bit_set[0 ..< 64], // arguments read so far; 64 is core:fmt's MAX_CHECKED_ARGS
}

// Mirrors the scanner of core:fmt's wprintf: %% and {{ }} are literals, %[flags][width][.prec][n]verb
// and {n:spec} each read one argument, and * reads one more. `{` picks its argument before the options,
// so `{:*d}` reads the same argument for the width and the value.
@(private = "file")
parse_format :: proc(f: string) -> (format: Format) {
	format.uses = make([dynamic]Format_Use, context.temp_allocator)
	format.unknown = make([dynamic]rune, context.temp_allocator)

	i := 0
	for i < len(f) {
		c := f[i]
		if c != '%' && c != '{' && c != '}' {
			i += 1
			continue
		}
		i += 1

		if c == '}' {
			if i < len(f) && f[i] == '}' do i += 1
			continue
		}

		if c == '{' {
			if i < len(f) && f[i] == '{' {
				i += 1
				continue
			}

			explicit := -1
			if i < len(f) && f[i] != '}' && f[i] != ':' {
				explicit = parse_digits(f, &i)
				if explicit < 0 do continue
			}
			arg := explicit >= 0 ? explicit : lowest_unused(format)

			verb := 'v'
			if i < len(f) && f[i] == ':' {
				i += 1
				parse_options(f, &i, &format)
				if i >= len(f) || f[i] == '}' do continue
				w: int
				verb, w = utf8.decode_rune_in_string(f[i:])
				i += w
			}
			if i >= len(f) || f[i] != '}' do continue
			i += 1
			consume_verb(&format, arg, verb, true)
			continue
		}

		if i < len(f) && f[i] == '%' {
			i += 1
			continue
		}

		parse_options(f, &i, &format)

		explicit := -1
		if i < len(f) && f[i] == '[' {
			explicit = parse_index(f, &i)
		}

		if i >= len(f) {
			append(&format.unknown, rune(0))
			break
		}
		verb, w := utf8.decode_rune_in_string(f[i:])
		i += w
		consume_verb(&format, explicit, verb, verb != ' ')
	}
	return
}

// Flags, width and precision; a `*` there reads its value from an argument.
@(private = "file")
parse_options :: proc(f: string, i: ^int, format: ^Format) {
	for i^ < len(f) && strings.index_byte("+- #0", f[i^]) >= 0 do i^ += 1
	parse_star_or_int(f, i, format)
	if i^ < len(f) && f[i^] == '.' {
		i^ += 1
		parse_star_or_int(f, i, format)
	}
}

@(private = "file")
parse_star_or_int :: proc(f: string, i: ^int, format: ^Format) {
	if i^ < len(f) && f[i^] == '*' {
		i^ += 1
		explicit := -1
		if i^ < len(f) && f[i^] == '[' {
			explicit = parse_index(f, i)
		}
		consume(format, explicit)
		return
	}
	for i^ < len(f) && f[i^] >= '0' && f[i^] <= '9' do i^ += 1
}

// `[n]` at i, or -1 when it is malformed. Advances past it on success.
@(private = "file")
parse_index :: proc(f: string, i: ^int) -> int {
	start := i^ + 1
	end := start
	for end < len(f) && f[end] >= '0' && f[end] <= '9' do end += 1
	if end == start || end >= len(f) || f[end] != ']' do return -1
	value, _ := strconv.parse_int(f[start:end])
	i^ = end + 1
	return value
}

// A bare argument number, as in `{1:d}`, or -1 when there is none.
@(private = "file")
parse_digits :: proc(f: string, i: ^int) -> int {
	end := i^
	for end < len(f) && f[end] >= '0' && f[end] <= '9' do end += 1
	if end == i^ do return -1
	value, _ := strconv.parse_int(f[i^:end])
	i^ = end
	return value
}

@(private = "file")
consume :: proc(format: ^Format, explicit: int) -> int {
	arg := explicit >= 0 ? explicit : lowest_unused(format^)
	if arg < 64 do format.used += {arg}
	format.needed = max(format.needed, arg + 1)
	return arg
}

// core:fmt takes the lowest argument that no earlier verb, `*` or `[n]` used.
@(private = "file")
lowest_unused :: proc(format: Format) -> int {
	arg := 0
	for arg < 64 && (arg in format.used) do arg += 1
	return arg
}

// core:fmt reads the argument of an unknown verb too, and prints it as %!k(…). consumes is false where
// it reads none, as for the space after `%5`.
@(private = "file")
consume_verb :: proc(format: ^Format, explicit: int, verb: rune, consumes: bool) {
	if !strings.contains_rune(VERBS, verb) {
		append(&format.unknown, verb)
		if consumes do consume(format, explicit)
		return
	}
	append(&format.uses, Format_Use{consume(format, explicit), verb})
}

@(private = "file")
Arg_Kind :: enum {
	Unknown,
	Bool,
	Integer,
	Float,
	String,
	Rune,
}

@(private = "file")
kind_names := [Arg_Kind]string {
	.Unknown = "",
	.Bool    = "a bool",
	.Integer = "an integer",
	.Float   = "a float",
	.String  = "a string",
	.Rune    = "a rune",
}

@(private = "file")
verb_rejects :: proc(verb: rune, kind: Arg_Kind) -> bool {
	switch verb {
	case 'b', 'o', 'd', 'i', 'z', 'U', 'm', 'M':
		return kind == .Bool || kind == .String || kind == .Float
	case 'x', 'X':
		// hex also dumps the bytes of a string
		return kind == .Bool || kind == .Float
	case 'f', 'F', 'e', 'E', 'g', 'G', 'h', 'H':
		return kind == .Bool || kind == .String || kind == .Integer
	case 't':
		return kind != .Bool && kind != .Unknown
	case 's', 'q':
		return kind == .Bool || kind == .Integer || kind == .Float
	case 'p':
		return kind == .Bool || kind == .String || kind == .Float || kind == .Integer
	}
	return false
}

// Only plain basic types are judged; everything else formats under too many verbs to call wrong.
@(private = "file")
arg_kind :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> Arg_Kind {
	#partial switch _ in expr.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
	case:
		return .Unknown
	}
	if ident, is_ident := expr.derived.(^ast.Ident); is_ident && bound_by_type_switch(ctx, ident) do return .Unknown
	resolved, is_resolved := lint_symbols(ctx)[uintptr(expr)]
	if !is_resolved || resolved.is_unresolved || resolved.symbol.pointers > 0 do return .Unknown

	#partial switch v in resolved.symbol.value {
	case SymbolBasicValue:
		switch {
		case slice.contains(untyped_map[.Bool], v.ident.name):
			return .Bool
		case slice.contains(untyped_map[.Integer], v.ident.name), v.ident.name == "uintptr":
			return .Integer
		case slice.contains(untyped_map[.Float], v.ident.name):
			return .Float
		case slice.contains(untyped_map[.String], v.ident.name):
			return .String
		case v.ident.name == "rune":
			return .Rune
		}
	case SymbolUntypedValue:
		#partial switch v.type {
		case .Bool:
			return .Bool
		case .Integer:
			return .Integer
		case .Float:
			return .Float
		case .String:
			return .String
		case .Rune:
			return .Rune
		}
	}
	return .Unknown
}

// A type switch binds its variable to a different type per case; the whole-file resolve picks
// one of them, so those identifiers are not judged.
@(private = "file")
bound_by_type_switch :: proc(ctx: ^LintContext, ident: ^ast.Ident) -> bool {
	stmt := top_level_stmt_at(ctx.document.ast.decls[:], ident.pos.offset)
	if stmt == nil do return false
	for at in nodes_at({stmt}, ident.pos.offset) {
		ts := at.node.derived.(^ast.Type_Switch_Stmt) or_continue
		if ts.tag == nil do continue
		assign := ts.tag.derived.(^ast.Assign_Stmt) or_continue
		if len(assign.lhs) == 0 do continue
		if name, ok := assign.lhs[0].derived.(^ast.Ident); ok && name.name == ident.name do return true
	}
	return false
}
