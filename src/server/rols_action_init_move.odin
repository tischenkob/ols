#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:unicode"

@(private = "package")
add_init_move_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_init_move {
		return
	}
	stmts, index, ok := stmt_at_range(ctx)
	if !ok {
		return
	}
	if decl, is_decl := stmts[index].derived.(^ast.Value_Decl); is_decl {
		if index + 1 < len(stmts) {
			move_into_init(ctx, stmts, decl, stmts[index + 1])
		}
		return
	}
	move_out_of_init(ctx, stmts, stmts[index])
}

// The parts of an `if`, `switch` or C-style `for` that a move touches. `for` has a post statement as well.
Header :: struct {
	keyword: string,
	at:      tokenizer.Pos,
	init:    ^ast.Stmt,
	cond:    ^ast.Expr,
	post:    ^ast.Stmt,
	body:    ^ast.Stmt,
}

header_of :: proc(stmt: ^ast.Stmt) -> (Header, bool) {
	#partial switch s in stmt.derived {
	case ^ast.If_Stmt:
		return {keyword = "if", at = s.if_pos, init = s.init, cond = s.cond, body = s.body}, s.cond != nil
	case ^ast.Switch_Stmt:
		return {keyword = "switch", at = s.switch_pos, init = s.init, cond = s.cond, body = s.body}, true
	case ^ast.For_Stmt:
		return {keyword = "for", at = s.for_pos, init = s.init, cond = s.cond, post = s.post, body = s.body}, true
	}
	return {}, false
}

// What a move needs in both directions, so that each move has the other as its reverse. In the result of a move out,
// decl stands alone before stmt, and its names must reach only stmt.
can_move :: proc(
	ctx: ^ActionContext,
	stmts: []^ast.Stmt,
	decl: ^ast.Value_Decl,
	stmt: ^ast.Stmt,
	header: Header,
) -> bool {
	if !movable_decl(decl) ||
	   !keyword_starts_line(ctx.document.ast.src, header.at.offset) ||
	   !fits_header(decl, header.keyword) {
		return false
	}
	function := ctx.position_context.function
	if in_when_body(function.body, header.at.offset) {
		return false
	}

	// Beside the statement the declaration reaches the rest of the block, so its names must be free there. A bare
	// `return` must also still see a result of the same name.
	for other in stmts {
		if other == stmt || other == decl {
			continue
		}
		for use in collect_ident_uses(other) {
			if !is_member_name(use) && declared_name(decl, use.ident.name) != nil {
				return false
			}
		}
	}
	if function.type.results != nil {
		for field in function.type.results.list {
			for result in field.names {
				if ident, is_ident := result.derived.(^ast.Ident); is_ident && declared_name(decl, ident.name) != nil {
					return false
				}
			}
		}
	}

	symbols := resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")
	used := false
	for use in collect_ident_uses(function.body) {
		at := use.ident.pos.offset
		in_decl := decl.pos.offset <= at && at < decl.end.offset
		if at < stmt.pos.offset || in_decl || is_member_name(use) {
			continue
		}
		name := declared_name(decl, use.ident.name)
		if name == nil {
			continue
		}
		offset, is_local := local_decl_offset(ctx, symbols, use.ident)
		is_declared := is_local && offset == name.pos.offset
		if at < stmt.end.offset {
			// A pointer or slice to the local can outlive the statement that now holds its scope.
			if is_declared && (address_taken(use) || aliases(use)) {
				return false
			}
			used ||= is_declared
		} else if is_declared || !is_local {
			return false
		}
	}
	return used
}

// `x, ok := f()` then `if ok {` becomes `if x, ok := f(); ok {`. The value still runs once, right before the header.
move_into_init :: proc(ctx: ^ActionContext, stmts: []^ast.Stmt, decl: ^ast.Value_Decl, next: ^ast.Stmt) {
	src := ctx.document.ast.src
	header, is_header := header_of(next)
	if !is_header || header.init != nil || len(decl.values) == 0 || !alone_on_line(src, decl) {
		return
	}
	// A trailing comment has no place in the header.
	line_end := strings.index_byte(src[decl.end.offset:], '\n')
	if line_end < 0 || strings.trim_space(src[decl.end.offset:][:line_end]) != "" {
		return
	}
	// A blank or comment line between the two would have no way back.
	from := line_start_at(src, decl.pos.offset)
	to := decl.end.offset + line_end + 1
	if line_start_at(src, header.at.offset) != to {
		return
	}

	edits := make([dynamic]TextEdit, context.temp_allocator)
	append(&edits, TextEdit{range = range_of(ctx, from, to)})

	text := node_text(src, decl)
	after := header.at.offset + len(header.keyword)
	rest := src[after:header.body.pos.offset]
	semicolon := after + len(rest) - len(strings.trim_left_space(rest))
	if header.keyword == "for" && src[semicolon] == ';' {
		// `for ; ; {` with an init does not parse, and `for ; c; {` would come back as `for c {`.
		if header.post == nil {
			return
		}
		append(&edits, TextEdit{range = range_of(ctx, after, semicolon), newText = fmt.tprintf(" %s", text)})
	} else {
		first_part := header.cond != nil ? header.cond.pos.offset : header.body.pos.offset
		// `for {` with an init does not parse.
		if header.keyword == "for" && header.cond == nil {
			return
		}
		if strings.trim_space(src[after:first_part]) != "" {
			return
		}
		append(&edits, TextEdit{range = range_of(ctx, first_part, first_part), newText = fmt.tprintf("%s; ", text)})
		if header.keyword == "for" {
			append(
				&edits,
				TextEdit{range = range_of(ctx, header.cond.end.offset, header.cond.end.offset), newText = ";"},
			)
		}
	}
	if !can_move(ctx, stmts, decl, next, header) {
		return
	}

	title := fmt.tprintf("Move into %s init", header.keyword)
	append(ctx.actions, make_code_action(ctx, title, "refactor.rewrite", edits[:]))
}

// `if x, ok := f(); ok {` becomes `x, ok := f()` then `if ok {`.
move_out_of_init :: proc(ctx: ^ActionContext, stmts: []^ast.Stmt, stmt: ^ast.Stmt) {
	src := ctx.document.ast.src
	header, is_header := header_of(stmt)
	if !is_header {
		return
	}
	// An `else if` is no statement of a list, so its header never gets here.
	if header.init == nil || ctx.range.start < header.at.offset || header.body.pos.offset < ctx.range.end {
		return
	}
	decl, is_decl := header.init.derived.(^ast.Value_Decl)
	if !is_decl || !can_move(ctx, stmts, decl, stmt, header) {
		return
	}

	init := decl.pos.offset
	init_end := decl.end.offset
	edits := make([dynamic]TextEdit, context.temp_allocator)
	line := line_start_at(src, header.at.offset)
	indent := get_line_indentation(src, header.at.offset)
	append(
		&edits,
		TextEdit{range = range_of(ctx, line, line), newText = fmt.tprintf("%s%s\n", indent, node_text(src, decl))},
	)

	if header.post != nil {
		// `for i := 0; ; i += 1 {` keeps both semicolons, whatever stands between them.
		if !strings.has_prefix(strings.trim_left_space(src[init_end:header.body.pos.offset]), ";") {
			return
		}
		append(&edits, TextEdit{range = range_of(ctx, init, init_end)})
	} else {
		next_part := header.cond != nil ? header.cond.pos.offset : header.body.pos.offset
		if strings.trim_space(src[init_end:next_part]) != ";" {
			return
		}
		append(&edits, TextEdit{range = range_of(ctx, init, next_part)})
		if header.keyword == "for" {
			// `for i < 3 {` has no semicolons at all, so the one after the condition goes too. A `do` stays.
			if header.cond == nil {
				return
			}
			tail := src[header.cond.end.offset:header.body.pos.offset]
			trimmed := strings.trim_left_space(tail)
			rest := strings.trim_space(strings.trim_prefix(trimmed, ";"))
			if !strings.has_prefix(trimmed, ";") || rest != "" && rest != "do" {
				return
			}
			semicolon := header.cond.end.offset + len(tail) - len(trimmed)
			append(&edits, TextEdit{range = range_of(ctx, header.cond.end.offset, semicolon + 1)})
		}
	}

	append(ctx.actions, make_code_action(ctx, "Move out of init", "refactor.rewrite", edits[:]))
}

movable_decl :: proc(decl: ^ast.Value_Decl) -> bool {
	if !decl.is_mutable || decl.is_using || len(decl.attributes) > 0 {
		return false
	}
	for name in decl.names {
		if _, is_ident := name.derived.(^ast.Ident); !is_ident {
			return false
		}
	}
	return true
}

// The name in decl spelled like name, nil when it has none. `_` declares nothing.
declared_name :: proc(decl: ^ast.Value_Decl, name: string) -> ^ast.Ident {
	if name == "_" {
		return nil
	}
	for candidate in decl.names {
		if ident, is_ident := candidate.derived.(^ast.Ident); is_ident && ident.name == name {
			return ident
		}
	}
	return nil
}

// A `{` in a header starts the body, a `for` header takes `in` for a range loop, and `or_break` or `or_continue` in
// the header of a loop can name another loop than it did beside the header.
fits_header :: proc(decl: ^ast.Value_Decl, keyword: string) -> bool {
	Data :: struct {
		is_for: bool,
		fits:   bool,
	}
	data := Data{keyword == "for", true}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Comp_Lit,
			     ^ast.Proc_Lit,
			     ^ast.Struct_Type,
			     ^ast.Union_Type,
			     ^ast.Enum_Type,
			     ^ast.Bit_Field_Type,
			     ^ast.Or_Branch_Expr:
				data.fits = false
				return nil
			case ^ast.Binary_Expr:
				if data.is_for && (n.op.kind == .In || n.op.kind == .Not_In) {
					data.fits = false
					return nil
				}
			}
			return visitor
		},
	}
	if decl.type != nil {
		ast.walk(&visitor, decl.type)
	}
	for value in decl.values {
		ast.walk(&visitor, value)
	}
	return data.fits
}

// Whether only `#partial` or a label stands before the keyword on its line. Both stay with the keyword. Anything else,
// such as `do`, `case` or `#no_bounds_check`, holds the statement or governs its init.
keyword_starts_line :: proc(src: string, at: int) -> bool {
	start, end := before_on_line(src, at)
	text := strings.trim_space(strings.trim_suffix(strings.trim_space(src[start:end]), "#partial"))
	if text == "" {
		return true
	}
	if !strings.has_suffix(text, ":") {
		return false
	}
	label := text[:len(text) - 1]
	if label == "" || label == "case" {
		return false
	}
	for c in label {
		if c != '_' && !unicode.is_letter(c) && !unicode.is_digit(c) {
			return false
		}
	}
	return true
}

// A `when` body opens no scope, so a declaration there reaches the block around the `when`.
in_when_body :: proc(body: ^ast.Stmt, at: int) -> bool {
	#reverse for node in nodes_at({body}, at) {
		#partial switch _ in node.node.derived {
		case ^ast.Block_Stmt:
			if node.parent != nil {
				_, is_when := node.parent.derived.(^ast.When_Stmt)
				return is_when
			}
			return false
		case ^ast.Case_Clause:
			return false
		}
	}
	return false
}

line_start_at :: proc(src: string, offset: int) -> int {
	return strings.last_index_byte(src[:offset], '\n') + 1
}
