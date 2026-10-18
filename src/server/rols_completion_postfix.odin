#+private file
package server

import "core:fmt"
import "core:odin/ast"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"

/*
	Postfix templates and pseudo methods after a dot on a value, like `ok.if` or `s.contains`.
	Each item removes the receiver and the dot, as the upstream magic completions do, and writes the template in
	place of the typed label. Statement templates appear only when the receiver starts its line. A label that an
	upstream completion already offers is skipped.

	An item is offered only where its result type-checks: `orr` needs a callee whose last result is a bool or
	nilable and an enclosing procedure that can return it, `&` needs an addressable receiver, a `slice` helper needs
	an element type that its `where` clause accepts, and so on. A call of a procedure group that the resolver
	leaves unresolved gets nothing.
*/

Receiver :: struct {
	text:        string, // snippet-escaped receiver source
	value:       string, // the receiver dereferenced to its pointee, like `p^`
	statement:   bool, // the receiver starts a line of a procedure body
	single:      bool, // one value, not a call with several results
	addressing:  Addressing, // `&x` compiles unless .None, `x[:]` on a fixed array only for .Variable
	in_defer:    bool, // inside a `defer`, which allows no `return` or `or_return`
	deferred:    bool, // the statement is the one a `defer` runs, which cannot be a declaration or a `defer`
	has_context: bool, // the enclosing procedure has `context`, which allocating and printing procedures need
}

Template :: struct {
	label:  string,
	format: string, // %v is the receiver
}

Element_Need :: enum {
	None,
	Comparable, // `==`, like `slice.contains`
	Ordered, // `<`, like `slice.sort`
}

Pseudo :: struct {
	pkg:   string, // "" for a builtin
	name:  string,
	extra: bool, // takes arguments after the receiver
	needs: Element_Need,
}

// odinfmt: disable
bool_templates := []Template {
	{"if",    "if %v {{\n\t$0\n}}"},
	{"ifnot", "if !%v {{\n\t$0\n}}"},
}

nil_templates := []Template {
	{"nil",    "if %v == nil {{\n\t$0\n}}"},
	{"notnil", "if %v != nil {{\n\t$0\n}}"},
}

int_for := Template{"for", "for ${{1:i}} in 0..<%v {{\n\t$0\n}}"}

single_value_templates := []Template {
	{"cast",      "cast($1)%v"},
	{"transmute", "transmute($1)%v"},
	{"paren",     "(%v)"},
}

string_pseudos := []Pseudo {
	{"", "delete", false, .None},
	{"", "raw_data", false, .None},
	{"strings", "contains", true, .None},
	{"strings", "has_prefix", true, .None},
	{"strings", "has_suffix", true, .None},
	{"strings", "index", true, .None},
	{"strings", "last_index", true, .None},
	{"strings", "count", true, .None},
	{"strings", "split", true, .None},
	{"strings", "fields", false, .None},
	{"strings", "trim_space", false, .None},
	{"strings", "trim", true, .None},
	{"strings", "to_upper", false, .None},
	{"strings", "to_lower", false, .None},
	{"strings", "replace_all", true, .None},
	{"strings", "clone", false, .None},
	{"strconv", "parse_int", false, .None},
	{"strconv", "parse_f64", false, .None},
	{"strconv", "parse_bool", false, .None},
}

slice_pseudos := []Pseudo {
	{"", "copy", true, .None},
	{"", "raw_data", false, .None},
	{"slice", "sort", false, .Ordered},
	{"slice", "sort_by", true, .None},
	{"slice", "contains", true, .Comparable},
	{"slice", "linear_search", true, .Comparable},
	{"slice", "reverse", false, .None},
	{"slice", "clone", false, .None},
	{"slice", "filter", true, .None},
	{"slice", "mapper", true, .None},
	{"slice", "min", false, .Ordered},
	{"slice", "max", false, .Ordered},
	{"slice", "fill", true, .None},
	{"slice", "is_sorted", false, .Ordered},
}

map_pseudos := []Pseudo {
	{"", "delete", false, .None},
	{"slice", "map_keys", false, .None},
	{"slice", "map_values", false, .None},
}

log_levels := [][2]string {
	{"logd", "debugf"},
	{"logi", "infof"},
	{"logw", "warnf"},
	{"loge", "errorf"},
}
// odinfmt: enable

Postfix_Context :: struct {
	ast_context:      ^AstContext,
	position_context: ^DocumentPositionContext,
	config:           ^common.Config,
	results:          ^[dynamic]CompletionResult,
	seen:             map[string]struct{},
	remove_edit:      []TextEdit,
	edit_range:       common.Range,
	receiver:         Receiver,
}

// Appends the templates and pseudo methods for the receiver of a selector completion. `receiver` is the symbol of
// the expression left of the dot, `selector` the symbol whose members the completion lists, which for a call is
// the type of its result.
@(private = "package")
rols_append_postfix_completions :: proc(
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	receiver: Symbol,
	selector: Symbol,
	results: ^[dynamic]CompletionResult,
	config: ^common.Config,
) {
	if !config.enable_postfix_completions || position_context.selector == nil {
		return
	}
	expr := position_context.selector

	// A name or a selector can name a type or a package. Every other expression left of a dot is a value.
	#partial switch _ in expr.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
		if .Variable not_in receiver.flags && receiver.type != .Variable && receiver.type != .Field {
			return
		}
	}

	// The selector completion has moved to the package of the selector's type. The receiver is the document's.
	ast_context.current_package = ast_context.document_package

	// A conversion like `f32(n)` or `Callback(f)` is a call expression too, and yields one value. A call of a
	// procedure group has no known result count, and neither has an arrow call: it resolves to the method when the
	// method has several results and to the result otherwise, which for a procedure result looks the same.
	call_expr := ast.unparen_expr(expr)
	is_call, is_arrow_call: bool
	#partial switch call in call_expr.derived {
	case ^ast.Selector_Call_Expr:
		is_call, is_arrow_call = true, true
	case ^ast.Call_Expr:
		is_call = true
		// `Maybe(int)` names a type, as a conversion like `U(x)` of a plain union does not.
		if callee, ok := resolve_fresh(ast_context, call.expr); ok {
			if union_value, is_union := callee.value.(SymbolUnionValue); is_union && union_value.poly != nil {
				return
			}
		}
	}
	if _, calls_group := receiver.value.(SymbolProcedureGroupValue); calls_group && is_call {
		return
	}
	callee, calls_proc := receiver.value.(SymbolProcedureValue)
	is_conversion := calls_proc && is_proc_type_conversion(ast_context, call_expr, receiver)
	calls_proc &&= is_call && !is_conversion && !is_arrow_call
	result_count := calls_proc ? field_count(callee.return_types) : 1
	if result_count == 0 {
		return
	}

	range, ok := get_range_from_selection_start_to_dot(position_context)
	if !ok {
		return
	}

	pc := Postfix_Context {
		ast_context = ast_context,
		position_context = position_context,
		config = config,
		results = results,
		seen = make(map[string]struct{}, context.temp_allocator),
		edit_range = {start = range.end, end = range.end},
	}
	for result in results {
		if item, is_item := result.completion_item.?; is_item {
			pc.seen[item.label] = {}
		} else {
			pc.seen[result.symbol.name] = {}
		}
	}

	pc.remove_edit = make([]TextEdit, 1, context.temp_allocator)
	pc.remove_edit[0] = TextEdit {
		range = range,
	}

	// The template replaces the typed part of the label, like `pri` in `x.pri`.
	if field := position_context.field; field != nil && position_in_node(field, position_context.position) {
		pc.edit_range.end = common.get_token_range(field, position_context.file.src).end
	}

	// A proc-typed variable is a value of its own, not the result that the selector completion resolves.
	// A call with several results stays a procedure, and only the templates for any value apply.
	symbol := selector
	if is_arrow_call {
		symbol = {}
	} else if _, is_proc := receiver.value.(SymbolProcedureValue); is_proc {
		if !is_call || is_conversion {
			symbol = receiver
		} else if result_count != 1 {
			symbol = {}
		}
	}

	src := position_context.file.src
	text := escape_snippet(src[expr.pos.offset:expr.end.offset])
	pointers := symbol.pointers
	statement, deferred, in_defer := starts_statement(position_context.function, expr)
	pc.receiver = Receiver {
		text        = text,
		value       = fmt.tprint(text, repeat("^", pointers, context.temp_allocator), sep = ""),
		statement   = statement,
		deferred    = deferred,
		single      = result_count == 1 && !is_arrow_call,
		addressing  = addressing(&pc, expr),
		in_defer    = in_defer,
		has_context = has_context(position_context.function),
	}

	if pointers > 0 {
		add_template(&pc, {"^", "%v^"})
		add_pseudo(&pc, {"", "free", false, .None}, text)
	}
	if is_nil_comparable(symbol) {
		add_templates(&pc, nil_templates, statement = true)
	}

	if calls_proc {
		add_call_templates(&pc, callee, receiver, result_count)
	} else if index, is_index := expr.derived.(^ast.Index_Expr); is_index {
		if indexed, ok := resolve_fresh(ast_context, index.expr); ok && indexed.pointers == 0 {
			if _, is_map := indexed.value.(SymbolMapValue); is_map {
				add_template(&pc, {"ore", "%v or_else $0"})
			}
		}
	}

	is_soa := .Soa in symbol.flags || .SoaPointer in symbol.flags
	#partial switch v in symbol.value {
	case SymbolBasicValue:
		name := v.ident.name
		switch {
		case slice.contains(untyped_map[.Bool], name):
			if pointers == 0 {
				add_bool_templates(&pc)
			}
		case slice.contains(untyped_map[.Integer], name) && pointers == 0:
			add_template(&pc, int_for, statement = true)
		case name == "string":
			add_value_template(&pc, {"fori", "for ${{1:r}}, ${{2:i}} in %v {{\n\t$0\n}}"})
			// The string procedures take `string`, which a distinct string does not convert to.
			if .Distinct not_in symbol.flags {
				add_pseudos(&pc, string_pseudos)
			}
		}
	case SymbolUntypedValue:
		#partial switch v.type {
		case .Bool:
			add_bool_templates(&pc)
		case .Integer:
			add_template(&pc, int_for, statement = true)
		case .String:
			add_pseudos(&pc, string_pseudos)
		}
	case SymbolEnumValue:
		add_enum_switch(&pc, symbol, v)
	case SymbolUnionValue:
		// `.?` without a type unwraps only a union of one variant, like `Maybe(T)`.
		if !is_call && pointers == 0 && len(v.types) == 1 {
			add_template(&pc, {"ore", "%v.? or_else $0"})
		}
	case SymbolMapValue:
		add_value_template(&pc, {"fori", "for ${{1:k}}, ${{2:v}} in %v {{\n\t$0\n}}"})
		add_pseudos(&pc, map_pseudos)
	case SymbolSliceValue:
		add_array_like(&pc, symbol, v.expr, false, true, is_soa)
	case SymbolDynamicArrayValue:
		add_array_like(&pc, symbol, v.expr, true, true, is_soa)
	case SymbolFixedArrayValue:
		add_array_like(&pc, symbol, v.expr, true, false, is_soa)
	}

	if !pc.receiver.in_defer && returns_value(&pc, symbol) {
		add_template(&pc, {"return", "return %v"}, statement = true)
	}
	if pc.receiver.single {
		if !pc.receiver.deferred {
			add_template(&pc, {"var", "${{1:name}} := %v"}, statement = true)
		}
		add_templates(&pc, single_value_templates)
	}
	if pc.receiver.addressing != .None && !is_call {
		add_template(&pc, {"&", "&%v"})
	}

	// `fmt.println` takes every result of a call. The formats take one value each.
	add_print(&pc, "print", "fmt", "%v.println(%v)")
	if pc.receiver.single {
		add_print(&pc, "printf", "fmt", "%v.printfln(\"$1%%v\", %v)")
		for level in log_levels {
			add_print(&pc, level[0], "log", fmt.tprintf("%%v.%v(\"$1%%%%v\", %%v)", level[1]))
		}
	}
}

// `defer`, `orr` and `ore` on a call of `callee`, the procedure that `owner` names.
add_call_templates :: proc(pc: ^Postfix_Context, callee: SymbolProcedureValue, owner: Symbol, result_count: int) {
	// A builtin or intrinsic like `len` requires its results to be handled.
	builtin := .Builtin in owner.flags || is_builtin_pkg(owner.pkg) || is_objc_intrinsics_package(owner.pkg)
	if !builtin && !slice.contains(attribute_names(callee.attributes), "require_results") {
		if !pc.receiver.deferred {
			add_template(pc, {"defer", "defer %v"}, statement = true)
		}
	}

	last, has_last := last_result_type(pc.ast_context, owner, callee.return_types)
	if !has_last || !(is_boolean(last) || is_nil_comparable(last, enums = true)) {
		return
	}
	if result_count == 2 {
		add_template(pc, {"ore", "%v or_else $0"})
	}
	// `or_return` on a single value yields nothing, so it stands as a statement.
	if !pc.receiver.in_defer && can_return_or(pc, last) {
		add_template(pc, {"orr", "%v or_return"}, statement = result_count == 1)
	}
}

// `or_return` returns `last` from the enclosing procedure: its other results must be named, and its last result
// must take a boolean when `last` is one, or else `last` itself, directly or as a variant of a union.
can_return_or :: proc(pc: ^Postfix_Context, last: Symbol) -> bool {
	fields := enclosing_results(pc)
	if field_count(fields) == 0 {
		return false
	}
	// The parser names an unnamed result `_`.
	if field_count(fields) > 1 {
		for field in fields {
			for name in field.names {
				if ident, is_ident := name.derived.(^ast.Ident); !is_ident || ident.name == "_" {
					return false
				}
			}
		}
	}
	target, ok := last_result_type(pc.ast_context, {pkg = pc.ast_context.document_package}, fields)
	if !ok {
		return false
	}
	if is_boolean(last) {
		return is_boolean(target)
	}
	return accepts(pc.ast_context, target, last)
}

// `return x` compiles when the enclosing procedure has one result that takes the receiver.
returns_value :: proc(pc: ^Postfix_Context, symbol: Symbol) -> bool {
	if !pc.receiver.single || symbol.value == nil {
		return false
	}
	fields := enclosing_results(pc)
	if field_count(fields) != 1 {
		return false
	}
	target, ok := last_result_type(pc.ast_context, {pkg = pc.ast_context.document_package}, fields)
	if !ok {
		return false
	}
	// A variable holding an untyped value has the default type, `n := 5` an `int`. Only a literal converts.
	if untyped, is_untyped := symbol.value.(SymbolUntypedValue); is_untyped {
		if _, is_literal := pc.position_context.selector.derived.(^ast.Basic_Lit); !is_literal {
			return is_default_type(pc.ast_context, target, untyped.type)
		}
	}
	return accepts(pc.ast_context, target, symbol)
}

// `target` is the default type of an untyped value, or a union that holds it.
is_default_type :: proc(ast_context: ^AstContext, target: Symbol, type: SymbolUntypedValueType) -> bool {
	// odinfmt: disable
	defaults := [SymbolUntypedValueType]string {
		.Integer = "int", .Float = "f64", .Complex = "complex128", .Quaternion = "quaternion256",
		.String = "string", .Bool = "bool", .Rune = "rune",
	}
	// odinfmt: enable
	names_default :: proc(symbol: Symbol, name: string) -> bool {
		basic, is_basic := symbol.value.(SymbolBasicValue)
		return is_basic && symbol.pointers == 0 && .Distinct not_in symbol.flags && basic.ident.name == name
	}
	if names_default(target, defaults[type]) {
		return true
	}
	union_value, is_union := target.value.(SymbolUnionValue)
	if !is_union || target.pointers > 0 {
		return false
	}
	set_ast_package_from_symbol_scoped(ast_context, target)
	for variant in union_value.types {
		if symbol, ok := resolve_fresh(ast_context, variant); ok && names_default(symbol, defaults[type]) {
			return true
		}
	}
	return false
}

// The results of the procedure around the cursor.
enclosing_results :: proc(pc: ^Postfix_Context) -> []^ast.Field {
	function := pc.position_context.function
	if function == nil || function.type == nil || function.type.results == nil {
		return nil
	}
	return function.type.results.list
}

// A procedure of the `odin` calling convention has `context`. A `contextless` or foreign one has it only after
// assigning it, which a postfix completion does not look for.
has_context :: proc(function: ^ast.Proc_Lit) -> bool {
	if function == nil || function.type == nil {
		return false
	}
	switch cc in function.type.calling_convention {
	case string:
		return strings.trim(cc, "\"`") == "odin"
	case ast.Proc_Calling_Convention_Extra:
		return false
	}
	return true
}

// `target` takes a value of type `value` as the same type, or as a variant when `target` is a union.
accepts :: proc(ast_context: ^AstContext, target, value: Symbol) -> bool {
	if same_type(ast_context, target, value) {
		return true
	}
	union_value, is_union := target.value.(SymbolUnionValue)
	if !is_union || target.pointers > 0 {
		return false
	}
	set_ast_package_from_symbol_scoped(ast_context, target)
	for variant in union_value.types {
		if symbol, ok := resolve_fresh(ast_context, variant); ok && same_type(ast_context, symbol, value) {
			return true
		}
	}
	return false
}

// `is_symbol_same_typed` takes two distinct types over one base type for the same type. They are not.
same_type :: proc(ast_context: ^AstContext, a, b: Symbol) -> bool {
	if .Distinct in a.flags || .Distinct in b.flags {
		return a.name == b.name && a.pkg == b.pkg && a.pointers == b.pointers
	}
	return is_symbol_same_typed(ast_context, a, b)
}

// The type of the last result in `fields`, resolved in the package of `owner`.
last_result_type :: proc(ast_context: ^AstContext, owner: Symbol, fields: []^ast.Field) -> (Symbol, bool) {
	if len(fields) == 0 || fields[len(fields) - 1].type == nil {
		return {}, false
	}
	set_ast_package_from_symbol_scoped(ast_context, owner)
	return resolve_fresh(ast_context, fields[len(fields) - 1].type)
}

// The selector completion has resolved the receiver already, and a resolve that finds its expressions in
// `recursion_map` fails.
resolve_fresh :: proc(ast_context: ^AstContext, expr: ^ast.Expr) -> (Symbol, bool) {
	reset_ast_context(ast_context)
	return resolve_type_expression(ast_context, expr)
}

field_count :: proc(fields: []^ast.Field) -> (count: int) {
	for field in fields {
		count += max(1, len(field.names))
	}
	return
}

is_boolean :: proc(symbol: Symbol) -> bool {
	if symbol.pointers > 0 {
		return false
	}
	#partial switch v in symbol.value {
	case SymbolBasicValue:
		return slice.contains(untyped_map[.Bool], v.ident.name)
	case SymbolUntypedValue:
		return v.type == .Bool
	}
	return false
}

// `x == nil` compiles. An enum compares with nil too, but only `or_return` and `or_else` count it.
is_nil_comparable :: proc(symbol: Symbol, enums := false) -> bool {
	if is_valid_nil_symbol(symbol) {
		return true
	}
	#partial switch v in symbol.value {
	case SymbolMultiPointerValue:
		return true
	case SymbolEnumValue:
		return enums
	case SymbolBasicValue:
		switch v.ident.name {
		case "rawptr", "cstring", "cstring16", "any":
			return true
		}
	}
	return false
}

// How the compiler addresses `expr`. A map index can have its address taken as a whole, `&m[k]`, but a field
// or element of it is a value, as is any part of a value. Slicing a fixed array needs a variable.
Addressing :: enum {
	None,
	Map_Index,
	Variable,
}

// Parameters, range and type-switch values, constants, call results, string bytes, `context` and fields of a
// bit_field are not addressable.
addressing :: proc(pc: ^Postfix_Context, expr: ^ast.Expr) -> Addressing {
	ast_context := pc.ast_context
	#partial switch e in expr.derived {
	case ^ast.Ident:
		if e.name == "context" {
			return .None
		}
		symbol, ok := resolve_fresh(ast_context, e)
		if !ok || .Mutable not_in symbol.flags || .Parameter in symbol.flags {
			return .None
		}
		local, is_local := get_local(ast_context^, e^)
		if is_local && is_loop_value(pc.position_context.file.src, local.lhs) {
			return .None
		}
		return .Variable
	case ^ast.Selector_Expr:
		base, ok := resolve_fresh(ast_context, e.expr)
		if !ok {
			return .None
		}
		if _, is_bit_field := base.value.(SymbolBitFieldValue); is_bit_field {
			return .None
		}
		if _, is_package := base.value.(SymbolPackageValue); is_package {
			symbol, found := resolve_fresh(ast_context, e)
			return found && .Mutable in symbol.flags ? .Variable : .None
		}
		if base.pointers > 0 || addressing(pc, e.expr) == .Variable {
			return .Variable
		}
	case ^ast.Index_Expr:
		base, ok := resolve_fresh(ast_context, e.expr)
		if !ok {
			return .None
		}
		// A map or a string indexed through a pointer addresses as it does directly.
		#partial switch v in base.value {
		case SymbolMapValue:
			return .Map_Index
		case SymbolBasicValue:
			if slice.contains(untyped_map[.String], v.ident.name) ||
			   v.ident.name == "string16" ||
			   v.ident.name == "cstring16" {
				return .None
			}
		}
		if base.pointers > 0 {
			return .Variable
		}
		#partial switch _ in base.value {
		case SymbolSliceValue, SymbolDynamicArrayValue, SymbolMultiPointerValue:
			return .Variable
		case SymbolFixedArrayValue:
			if addressing(pc, e.expr) == .Variable {
				return .Variable
			}
		}
	case ^ast.Deref_Expr:
		return .Variable
	case ^ast.Paren_Expr:
		return addressing(pc, e.expr)
	}
	return .None
}

// The declaration `decl` is a value of a `for … in` or `switch … in` header that takes no `&`.
is_loop_value :: proc(src: string, decl: ^ast.Expr) -> bool {
	if decl == nil {
		return false
	}
	// `for &x in xs` declares `&x`.
	if _, is_unary := decl.derived.(^ast.Unary_Expr); is_unary {
		return false
	}
	line_start := strings.last_index_byte(src[:decl.pos.offset], '\n') + 1
	before := strings.trim_right_space(src[line_start:decl.pos.offset])
	if strings.has_suffix(before, "&") {
		return false
	}
	words := strings.fields(before, context.temp_allocator)
	if len(words) > 0 && strings.has_suffix(words[0], ":") {
		words = words[1:]
	}
	// `#reverse for` and `#unroll for`.
	for len(words) > 0 && strings.has_prefix(words[0], "#") {
		words = words[1:]
	}
	if len(words) == 0 || (words[0] != "for" && words[0] != "switch") {
		return false
	}
	rest := src[decl.end.offset:]
	// The header ends at its `{`, which can be lines below when it wraps after `in`.
	if end := strings.index_byte(rest, '{'); end != -1 {
		rest = rest[:end]
	}
	for word in strings.fields(rest, context.temp_allocator) {
		if word == "in" {
			return true
		}
		if strings.contains(word, ":=") {
			return false
		}
	}
	return false
}

// What the `where` clauses of the `slice` procedures ask of the element type.
element_meets :: proc(ast_context: ^AstContext, owner: Symbol, elem: ^ast.Expr, need: Element_Need) -> bool {
	if need == .None {
		return true
	}
	set_ast_package_from_symbol_scoped(ast_context, owner)
	symbol := resolve_fresh(ast_context, elem) or_return
	if symbol.pointers > 0 {
		return true
	}
	#partial switch v in symbol.value {
	case SymbolEnumValue:
		return true
	case SymbolBasicValue:
		name := v.ident.name
		ordered :=
			slice.contains(untyped_map[.Integer], name) ||
			slice.contains(untyped_map[.Float], name) ||
			name == "rune" ||
			name == "string"
		return ordered || (need == .Comparable && slice.contains(untyped_map[.Bool], name))
	}
	return false
}

add_bool_templates :: proc(pc: ^Postfix_Context) {
	add_templates(pc, bool_templates, statement = true)
	add_template(pc, {"not", "!%v"})
}

add_array_like :: proc(
	pc: ^Postfix_Context,
	symbol: Symbol,
	elem: ^ast.Expr,
	needs_slicing, owns: bool,
	is_soa: bool,
) {
	add_value_template(pc, {"fori", "for ${{1:e}}, ${{2:i}} in %v {{\n\t$0\n}}"})
	if is_soa {
		return
	}
	if owns {
		add_pseudo(pc, {"", "delete", false, .None}, pc.receiver.value)
	}
	// Only an addressable fixed array can be sliced. A pointer's pointee always is.
	_, is_fixed := symbol.value.(SymbolFixedArrayValue)
	if is_fixed && symbol.pointers == 0 && pc.receiver.addressing != .Variable {
		return
	}
	sliced := needs_slicing ? fmt.tprint(pc.receiver.value, "[:]", sep = "") : pc.receiver.value
	for pseudo in slice_pseudos {
		if element_meets(pc.ast_context, symbol, elem, pseudo.needs) {
			add_pseudo(pc, pseudo, sliced)
		}
	}
	// `strings.join` takes `[]string`, which a distinct slice does not convert to.
	ident, is_ident := elem.derived.(^ast.Ident)
	if is_ident && ident.name == "string" && (needs_slicing || .Distinct not_in symbol.flags) {
		add_pseudo(pc, {"strings", "join", true, .None}, sliced)
	}
}

// One case per value: an alias like `Last = B` would repeat the case of `B`.
add_enum_switch :: proc(pc: ^Postfix_Context, symbol: Symbol, v: SymbolEnumValue) {
	if len(v.names) == 0 {
		return
	}
	set_ast_package_from_symbol_scoped(pc.ast_context, symbol)
	_, classes := enum_member_values(pc.ast_context, v)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "switch %v {{\n", pc.receiver.value)
	for name, i in v.names {
		if classes[i] != i {
			continue
		}
		fmt.sbprintf(&b, "case .%v:\n", name)
		if i == 0 {
			strings.write_string(&b, "\t$0\n")
		}
	}
	strings.write_string(&b, "}")
	add_item(pc, "switch", "switch", strings.to_string(b), nil, statement = true)
}

add_templates :: proc(pc: ^Postfix_Context, templates: []Template, statement := false) {
	for template in templates {
		add_template(pc, template, statement)
	}
}

add_template :: proc(pc: ^Postfix_Context, template: Template, statement := false) {
	add_item(pc, template.label, template.label, fmt.tprintf(template.format, pc.receiver.text), nil, statement)
}

// A statement template on the pointee, like `for e in p^`.
add_value_template :: proc(pc: ^Postfix_Context, template: Template) {
	text := fmt.tprintf(template.format, pc.receiver.value)
	add_item(pc, template.label, template.label, text, nil, statement = true)
}

add_pseudos :: proc(pc: ^Postfix_Context, pseudos: []Pseudo) {
	for pseudo in pseudos {
		add_pseudo(pc, pseudo, pc.receiver.value)
	}
}

// `arg` is the receiver as the procedure takes it, like `p^` or `x[:]`.
add_pseudo :: proc(pc: ^Postfix_Context, pseudo: Pseudo, arg: string) {
	// `copy` and `raw_data` are intrinsics. Every other procedure takes `context`.
	if !pc.receiver.has_context && pseudo.name != "copy" && pseudo.name != "raw_data" {
		return
	}
	rest := pseudo.extra ? ", $0" : ""
	if pseudo.pkg == "" {
		add_item(pc, pseudo.name, pseudo.name, fmt.tprintf("%v(%v%v)", pseudo.name, arg, rest), nil)
		return
	}
	name, import_edit, ok := package_name(pc, pseudo.pkg)
	if !ok {
		return
	}
	detail := fmt.tprintf("%v.%v", pseudo.pkg, pseudo.name)
	add_item(pc, pseudo.name, detail, fmt.tprintf("%v.%v(%v%v)", name, pseudo.name, arg, rest), import_edit)
}

// `format` takes the package name, then the receiver.
add_print :: proc(pc: ^Postfix_Context, label, pkg, format: string) {
	if !pc.receiver.has_context {
		return
	}
	name, import_edit, ok := package_name(pc, pkg)
	if !ok {
		return
	}
	add_item(pc, label, label, fmt.tprintf(format, name, pc.receiver.text), import_edit, statement = true)
}

add_item :: proc(pc: ^Postfix_Context, label, detail, text: string, import_edit: Maybe(TextEdit), statement := false) {
	if statement && !pc.receiver.statement {
		return
	}
	if label in pc.seen {
		return
	}
	pc.seen[label] = {}

	edits := pc.remove_edit
	if edit, ok := import_edit.?; ok {
		edits = make([]TextEdit, 2, context.temp_allocator)
		edits[0] = pc.remove_edit[0]
		edits[1] = edit
	}

	item := CompletionItem {
		label = label,
		kind = .Snippet,
		detail = detail,
		textEdit = TextEdit{newText = text, range = pc.edit_range},
		additionalTextEdits = edits,
		insertTextFormat = .Snippet,
		InsertTextMode = .adjustIndentation,
	}
	append(pc.results, CompletionResult{completion_item = item, score = -1})
}

// The name the file gives a `core` package, and the import that adds it when the file lacks it. A local, a
// declaration of the package or another import with that name hides the package, and then no item uses it.
package_name :: proc(pc: ^Postfix_Context, pkg: string) -> (name: string, edit: Maybe(TextEdit), ok: bool) {
	dir, has_core := pc.config.collections["core"]
	if !has_core {
		return
	}
	fullpath := path.join({dir, pkg}, context.temp_allocator)
	clash := false
	for imp in pc.ast_context.imports {
		if imp.name == fullpath {
			return imp.base, nil, !is_shadowed(pc, imp.base)
		}
		clash ||= imp.base == pkg
	}
	if clash || is_shadowed(pc, pkg) {
		return
	}
	return pkg, rols_core_import_edit(pc.ast_context, pkg, fullpath, pc.config), true
}

// `name` is declared in scope at the receiver or anywhere in the document's package.
is_shadowed :: proc(pc: ^Postfix_Context, name: string) -> bool {
	ident := ast.Ident {
		name = name,
	}
	ident.pos = pc.position_context.selector.pos
	if _, is_local := get_local(pc.ast_context^, ident); is_local || name in pc.ast_context.globals {
		return true
	}
	_, declared := lookup(name, pc.ast_context.document_package, pc.ast_context.fullpath)
	return declared
}

// `expr` begins an expression statement of `function`, like `ok.` on a line of its own. A receiver that only
// starts a line, inside a call spread over several lines or a condition continued on the next, does not.
// `deferred` is set when that statement is the one a `defer` runs, as in `defer x.`, and `in_defer` when any
// `defer` of the body holds `expr`.
starts_statement :: proc(function: ^ast.Proc_Lit, expr: ^ast.Expr) -> (statement, deferred, in_defer: bool) {
	if function == nil || function.body == nil {
		return
	}
	Search :: struct {
		offset:    int,
		statement: ^ast.Node,
		deferred:  bool,
		in_defer:  bool,
		parent:    ^ast.Node, // the last node visited, which holds the next one
	}
	search := Search {
		offset = expr.pos.offset,
	}
	visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		search := cast(^Search)visitor.data
		if node == nil || node.pos.offset > search.offset || node.end.offset < search.offset {
			return nil
		}
		#partial switch _ in node.derived {
		case ^ast.Defer_Stmt:
			search.in_defer = true
		case ^ast.Expr_Stmt, ^ast.Bad_Stmt:
			search.statement = node
			_, search.deferred = search.parent.derived.(^ast.Defer_Stmt)
		}
		search.parent = node
		return visitor
	}
	visitor := ast.Visitor {
		visit = visit,
		data  = &search,
	}
	ast.walk(&visitor, function.body)
	statement = search.statement != nil && search.statement.pos.offset == expr.pos.offset
	return statement, statement && search.deferred, search.in_defer
}

escape_snippet :: proc(text: string) -> string {
	if !strings.contains_any(text, "\\$}") {
		return text
	}
	b := strings.builder_make(context.temp_allocator)
	for c in text {
		if c == '\\' || c == '$' || c == '}' {
			strings.write_byte(&b, '\\')
		}
		strings.write_rune(&b, c)
	}
	return strings.to_string(b)
}
