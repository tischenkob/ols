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

	format := parse_format(text)

	for bad in format.unknown {
		message := bad == 0 ? "unknown format verb '%'" : fmt.tprintf("unknown format verb '%%%r'", bad)
		append(diags, printf_diagnostic(ctx, lit, "printf-verb", message))
	}

	if format.needed > len(args) {
		append(
			diags,
			printf_diagnostic(
				ctx,
				lit,
				"printf-arity",
				fmt.tprintf("format needs %d arguments, call has %d", format.needed, len(args)),
			),
		)
	} else if !format.positional && format.needed < len(args) {
		extra := len(args) - format.needed
		append(
			diags,
			printf_diagnostic(
				ctx,
				args[format.needed],
				"printf-arity",
				fmt.tprintf("call has %d extra argument%s", extra, extra == 1 ? "" : "s"),
			),
		)
	}

	for use in format.uses {
		if use.arg >= len(args) do continue
		kind := arg_kind(ctx, args[use.arg])
		if !verb_rejects(use.verb, kind) do continue
		append(
			diags,
			printf_diagnostic(
				ctx,
				args[use.arg],
				"printf-type",
				fmt.tprintf("format verb '%%%r' does not accept %s", use.verb, kind_names[kind]),
			),
		)
	}
}

@(private = "file")
lint_print_directive :: proc(ctx: ^LintContext, call: ^ast.Call_Expr, name: string, diags: ^[dynamic]Diagnostic) {
	if !slice.contains(print_procs, name) || len(call.args) == 0 do return
	text, is_string := string_literal(call.args[0])
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
				call.args[0],
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
	uses:       [dynamic]Format_Use,
	unknown:    [dynamic]rune, // 0 stands for a trailing '%'
	needed:     int, // one past the highest argument index the format reads
	positional: bool,
}

// Mirrors the scanner of core:fmt's wprintf: %% and {{ }} are literals, %[flags][width][.prec][n]verb
// and {n:spec} each read one argument, and * reads one more.
@(private = "file")
parse_format :: proc(f: string) -> (format: Format) {
	format.uses = make([dynamic]Format_Use, context.temp_allocator)
	format.unknown = make([dynamic]rune, context.temp_allocator)
	next := 0

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

			verb := 'v'
			if i < len(f) && f[i] == ':' {
				i += 1
				parse_options(f, &i, &format, &next)
				if i >= len(f) || f[i] == '}' do continue
				w: int
				verb, w = utf8.decode_rune_in_string(f[i:])
				i += w
			}
			if i >= len(f) || f[i] != '}' do continue
			i += 1
			consume_verb(&format, &next, explicit, verb)
			continue
		}

		if i < len(f) && f[i] == '%' {
			i += 1
			continue
		}

		parse_options(f, &i, &format, &next)

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
		consume_verb(&format, &next, explicit, verb)
	}
	return
}

// Flags, width and precision; a `*` there reads its value from an argument.
@(private = "file")
parse_options :: proc(f: string, i: ^int, format: ^Format, next: ^int) {
	for i^ < len(f) && strings.index_byte("+- #0", f[i^]) >= 0 do i^ += 1
	parse_star_or_int(f, i, format, next)
	if i^ < len(f) && f[i^] == '.' {
		i^ += 1
		parse_star_or_int(f, i, format, next)
	}
}

@(private = "file")
parse_star_or_int :: proc(f: string, i: ^int, format: ^Format, next: ^int) {
	if i^ < len(f) && f[i^] == '*' {
		i^ += 1
		explicit := -1
		if i^ < len(f) && f[i^] == '[' {
			explicit = parse_index(f, i)
		}
		consume(format, next, explicit)
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
consume :: proc(format: ^Format, next: ^int, explicit: int) -> int {
	arg := next^
	if explicit >= 0 {
		arg = explicit
		format.positional = true
	}
	next^ = arg + 1
	format.needed = max(format.needed, arg + 1)
	return arg
}

@(private = "file")
consume_verb :: proc(format: ^Format, next: ^int, explicit: int, verb: rune) {
	if !strings.contains_rune(VERBS, verb) {
		append(&format.unknown, verb)
		return
	}
	append(&format.uses, Format_Use{consume(format, next, explicit), verb})
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
	case 'b', 'o', 'd', 'i', 'z', 'x', 'X', 'U', 'm', 'M':
		return kind == .Bool || kind == .String || kind == .Float
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
