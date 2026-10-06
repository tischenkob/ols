package odin_printer

import "core:odin/tokenizer"
import "core:strings"

// Visits the comments before `pos` like visit_comments, but returns the leading block comments apart.
// A leading comment prints before the node at `pos` with one space after it.
// `above` holds every other comment, visited by visit_comment as before.
// `width` is the width that the leading comments and their spaces take on the node's line.
// `code_between` lets a block comment lead even when code separates it from `pos` on the line.
// A caller passes it when it prints the comments right before the node, so that code is already behind them.
@(private)
visit_comments_split :: proc(
	p: ^Printer,
	pos: tokenizer.Pos,
	code_between := false,
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
				leading = cons(leading, text(comment.text), text(" "))
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
