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
	move, _, ok := prepare_move(ctx.document, ctx.range.start)
	if !ok {
		return
	}
	document := ctx.document
	siblings := package_siblings(document, ctx.files)

	name := strings.to_lower(node_text(document.ast.src, move.decl.names[0]), context.temp_allocator)
	// The new file keeps the platform suffix of the source, as in `helper_windows.odin`, so it builds on the same targets.
	new_name := strings.concatenate(
		{name, target_suffix(path.base(document.fullpath)), ".odin"},
		context.temp_allocator,
	)
	new_path := path.join({document.package_name, new_name}, context.temp_allocator)
	if ctx.config.client_create_file_support && !package_file_exists(new_path, ctx.files) {
		uri := common.create_uri(new_path, context.temp_allocator)
		if edit, _, edit_ok := move_edit(move, uri.uri, ctx.files); edit_ok {
			append(
				ctx.actions,
				CodeAction{title = fmt.tprintf("Move to new file %s", new_name), kind = "refactor.move", edit = edit},
			)
		}
	}

	for sibling in siblings[:min(len(siblings), MAX_MOVE_TARGETS)] {
		uri := common.create_uri(sibling, context.temp_allocator)
		if edit, _, edit_ok := move_edit(move, uri.uri, ctx.files); edit_ok {
			append(
				ctx.actions,
				CodeAction{title = fmt.tprintf("Move to %s", path.base(sibling)), kind = "refactor.move", edit = edit},
			)
		}
	}
}
