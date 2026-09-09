#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

@(private = "package")
add_comment_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_comment {
		return
	}
	add_doc_comment(ctx)
	add_comment_form_action(ctx)
}

// Odin doc comments are prose, so the stub is one line rather than a tag per parameter.
add_doc_comment :: proc(ctx: ^ActionContext) {
	decl, found := top_decl_at(ctx.document, ctx.range.start)
	if !found || decl.docs != nil {
		return
	}

	src := ctx.document.ast.src
	start := decl.pos.offset
	for attribute in decl.attributes {
		start = min(start, attribute.pos.offset)
	}
	start = strings.last_index_byte(src[:start], '\n') + 1

	append_insert(
		ctx,
		start,
		"Add doc comment",
		"refactor.rewrite",
		fmt.tprintf("%s// %s \n", get_line_indentation(src, start), node_text(src, decl.names[0])),
	)
}

add_comment_form_action :: proc(ctx: ^ActionContext) {
	src := ctx.document.ast.src
	toks := comments_overlapping(ctx.document.ast, ctx.range.start, ctx.range.end)
	if len(toks) == 0 {
		return
	}

	line_start := strings.last_index_byte(src[:toks[0].pos.offset], '\n') + 1
	last := toks[len(toks) - 1]
	last_end := last.pos.offset + len(last.text)

	// The selection may not reach past the comments, nor start on code before them.
	if strings.trim_space(src[line_start:toks[0].pos.offset]) != "" {
		return
	}
	if ctx.range.start < line_start {
		return
	}
	if ctx.range.end > last_end && strings.trim_space(src[last_end:ctx.range.end]) != "" {
		return
	}

	ind := src[line_start:toks[0].pos.offset]
	if strings.has_prefix(toks[0].text, "/*") {
		if len(toks) != 1 || len(last.text) < 4 || !strings.has_suffix(last.text, "*/") {
			return
		}
		append_replace_range(ctx, line_start, last_end, "Convert to line comments", to_line_comments(last, ind))
		return
	}

	for tok, i in toks {
		if !strings.has_prefix(tok.text, "//") {
			return
		}
		// A `*/` in the text would close the block early.
		if strings.contains(tok.text, "*/") {
			return
		}
		if i > 0 {
			prev := toks[i - 1]
			gap := src[prev.pos.offset + len(prev.text):tok.pos.offset]
			if strings.trim_space(gap) != "" || strings.count(gap, "\n") != 1 {
				return
			}
		}
	}
	append_replace_range(ctx, line_start, last_end, "Convert to block comment", to_block_comment(toks, ind))
}

comments_overlapping :: proc(file: ast.File, start, end: int) -> []tokenizer.Token {
	found := make([dynamic]tokenizer.Token, context.temp_allocator)
	for group in file.comments {
		for tok in group.list {
			if tok.pos.offset <= end && start <= tok.pos.offset + len(tok.text) {
				append(&found, tok)
			}
		}
	}
	return found[:]
}

to_block_comment :: proc(toks: []tokenizer.Token, ind: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, ind)
	strings.write_string(&sb, "/*\n")
	for tok in toks {
		if body := strings.trim_space(tok.text[2:]); body != "" {
			strings.write_string(&sb, ind)
			strings.write_string(&sb, body)
		}
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, ind)
	strings.write_string(&sb, "*/")
	return strings.to_string(sb)
}

to_line_comments :: proc(tok: tokenizer.Token, ind: string) -> string {
	lines := strings.split(tok.text[2:len(tok.text) - 2], "\n", context.temp_allocator)
	if len(lines) > 1 && strings.trim_space(lines[0]) == "" {
		lines = lines[1:]
	}
	if len(lines) > 1 && strings.trim_space(lines[len(lines) - 1]) == "" {
		lines = lines[:len(lines) - 1]
	}

	sb := strings.builder_make(context.temp_allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, ind)
		strings.write_string(&sb, "//")
		if body := strings.trim_space(line); body != "" {
			strings.write_byte(&sb, ' ')
			strings.write_string(&sb, body)
		}
	}
	return strings.to_string(sb)
}
