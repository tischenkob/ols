package odin_printer

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

// Visits the comments before `pos` like visit_comments, but returns the leading block comments apart.
// A leading comment prints before the node at `pos` with one space after it.
// `above` holds every other comment, visited by visit_comment as before.
// `width` is the width that the leading comments and their spaces take on the node's line.
// `code_between` lets a block comment lead even when code separates it from `pos` on the line.
// A caller passes it when it prints the comments right before the node, so that code is already behind them.
// Without `space_after`, the space of a leading comment goes before it, for a node such as `;` that follows it directly.
@(private)
visit_comments_split :: proc(
	p: ^Printer,
	pos: tokenizer.Pos,
	code_between := false,
	space_after := true,
) -> (
	above: ^Document,
	leading: ^Document,
	width: int,
) {
	above = empty()
	leading = empty()

	for comment_before_position(p, pos) {
		for comment in p.comments[p.latest_comment_index].list {
			if is_leading_comment(p, comment, pos, code_between) {
				if space_after {
					leading = cons(leading, text(comment.text), text(" "))
				} else {
					leading = cons(leading, text(" "), text(comment.text))
				}
				width += strings.rune_count(comment.text) + 1
				p.source_position = comment.pos
			} else {
				_, document := visit_comment(p, comment)
				above = cons(above, document)
			}
		}
		next_comment_group(p)
	}

	return above, leading, width
}

// A block comment leads the node at `pos` when only spaces, tabs and other block comments separate them on one line.
// With `code_between`, any text without a newline may separate them.
@(private)
is_leading_comment :: proc(p: ^Printer, comment: tokenizer.Token, pos: tokenizer.Pos, code_between := false) -> bool {
	if !strings.has_prefix(comment.text, "/*") || strings.contains_rune(comment.text, '\n') {
		return false
	}
	if comment.pos.line in p.disabled_lines {
		return false
	}

	end := comment.pos.offset + len(comment.text)
	if end > pos.offset || pos.offset > len(p.src) {
		return false
	}

	gap := p.src[end:pos.offset]
	if code_between {
		return !strings.contains_rune(gap, '\n')
	}
	for i := 0; i < len(gap); {
		switch {
		case gap[i] == ' ' || gap[i] == '\t':
			i += 1
		case strings.has_prefix(gap[i:], "/*"):
			// block comments nest in Odin
			depth := 0
			for i < len(gap) {
				if strings.has_prefix(gap[i:], "/*") {
					depth += 1
					i += 2
				} else if strings.has_prefix(gap[i:], "*/") {
					depth -= 1
					i += 2
					if depth == 0 {
						break
					}
				} else if gap[i] == '\n' {
					return false
				} else {
					i += 1
				}
			}
			if depth != 0 {
				return false
			}
		case:
			return false
		}
	}

	return true
}

// Moves to the line of `pos` like move_line_limit with the configured newline limit,
// but a block comment that leads the node at `pos` prints before it with one space after it, as visit_comments_split prints it.
// visit_comment would print such a comment as trailing code on its line, with no space after it.
// move_line calls it, and visit_end_brace calls move_line_limit so that a comment before `}` keeps upstream's placement.
@(private)
move_line_leading :: proc(p: ^Printer, pos: tokenizer.Pos) -> ^Document {
	lines := pos.line - p.source_position.line
	if lines < 0 {
		return empty()
	}

	above := empty()
	leading := empty()
	newlined := 0
	for comment_before_position(p, pos) {
		for comment in p.comments[p.latest_comment_index].list {
			if is_leading_comment(p, comment, pos) {
				leading = cons(leading, text(comment.text), text(" "))
			} else {
				n, document := visit_comment(p, comment)
				newlined += n
				above = cons(above, document)
			}
		}
		next_comment_group(p)
	}

	p.source_position = pos

	return cons(above, newline(max(min(lines - newlined, p.config.newline_limit + 1), 0)), leading)
}

// Where a field's text starts: its first flag, such as `using` or `#any_int`, when the flags sit on the name's line.
// Field.pos is the position of the first name, after the flags.
@(private)
field_start :: proc(p: ^Printer, field: ^ast.Field) -> tokenizer.Pos {
	pos := field.pos
	if field.flags == {} || pos.offset > len(p.src) {
		return pos
	}

	start := pos.offset
	for {
		i := start
		for i > 0 && (p.src[i - 1] == ' ' || p.src[i - 1] == '\t') {
			i -= 1
		}
		j := i
		for j > 0 {
			c := p.src[j - 1]
			if c != '_' && !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') {
				break
			}
			j -= 1
		}
		word := p.src[j:i]
		if j > 0 && p.src[j - 1] == '#' && word != "" {
			j -= 1
		} else if word != "using" {
			break
		}
		start = j
	}

	pos.column -= pos.offset - start
	pos.offset = start
	return pos
}

// Returns the width that visit_comments_split gives the leading block comments before `pos`, without visiting them.
// `index` is the comment group to start from, and `next` is the first group at or after `pos`.
// An alignment pass calls it once per item in source order and passes `next` back as `index`.
@(private)
peek_leading_width :: proc(p: ^Printer, pos: tokenizer.Pos, index: int) -> (width: int, next: int) {
	next = index
	for next < len(p.comments) && p.comments[next].pos.offset < pos.offset {
		for comment in p.comments[next].list {
			if is_leading_comment(p, comment, pos) {
				width += strings.rune_count(comment.text) + 1
			}
		}
		next += 1
	}
	return
}

// Returns the position of the `;` before the post statement of a `for` header.
// The AST keeps no position for it, so this scans the source after the condition,
// or else after the init statement or the `for` keyword. An automatic semicolon does not count.
// Returns the post statement's position when that source holds no `;`.
@(private)
for_post_semicolon :: proc(p: ^Printer, stmt: ^ast.For_Stmt) -> tokenizer.Pos {
	start := stmt.for_pos
	start.offset += len("for")
	start.column += len("for")
	if stmt.cond != nil {
		start = stmt.cond.end
	} else if stmt.init != nil {
		start = stmt.init.end
	}

	end := stmt.post.pos.offset
	if start.offset < 0 || start.offset > end || end > len(p.src) {
		return stmt.post.pos
	}

	t: tokenizer.Tokenizer
	tokenizer.init(&t, p.src[start.offset:end], "", nil)
	semicolon := stmt.post.pos
	for token := tokenizer.scan(&t); token.kind != .EOF; token = tokenizer.scan(&t) {
		if token.kind != .Semicolon || token.text != ";" {
			continue
		}
		semicolon = token.pos
		semicolon.file = start.file
		semicolon.offset += start.offset
		if token.pos.line == 1 {
			semicolon.column += start.column - 1
		}
		semicolon.line += start.line - 1
	}
	return semicolon
}
