package server

import "core:fmt"
import path "core:path/slashpath"
import "core:strings"

import "src:common"

MAX_MOVE_TARGETS :: 8

add_move_decl_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_move_decl {
		return
	}
	move, ok := prepare_move(ctx.document, ctx.range.start)
	if !ok {
		return
	}
	document := ctx.document
	siblings := package_siblings(document, ctx.files)

	name := strings.to_lower(node_text(document.ast.src, move.decl.names[0]), context.temp_allocator)
	new_path := path.join({document.package_name, strings.concatenate({name, ".odin"}, context.temp_allocator)}, context.temp_allocator)
	if ctx.config.client_create_file_support && !package_file_exists(new_path, ctx.files) {
		uri := common.create_uri(new_path, context.temp_allocator)
		if edit, edit_ok := move_edit(move, uri.uri, ctx.files); edit_ok {
			append(ctx.actions, CodeAction{title = fmt.tprintf("Move to new file %s.odin", name), kind = "refactor.move", edit = edit})
		}
	}

	for sibling in siblings[:min(len(siblings), MAX_MOVE_TARGETS)] {
		uri := common.create_uri(sibling, context.temp_allocator)
		if edit, edit_ok := move_edit(move, uri.uri, ctx.files); edit_ok {
			append(ctx.actions, CodeAction{title = fmt.tprintf("Move to %s", path.base(sibling)), kind = "refactor.move", edit = edit})
		}
	}
}
