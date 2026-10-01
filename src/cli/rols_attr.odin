package cli

import "core:fmt"

import "src:common"
import "src:server"

// `ols query attr add|remove|rename …`: each subcommand computes a workspace edit and writes it through
// run_edit, so the compile gate rolls back an attribute odin check rejects. --all is valid on remove only.
attr :: proc(args: []string, root: string, all, apply, check: bool) -> int {
	if len(args) == 0 || (all && args[0] != "remove") {
		return usage()
	}
	sub, rest := args[0], args[1:]
	name := fmt.tprintf("attr %s", sub)
	config := &common.config

	edit: server.WorkspaceEdit
	warnings, reasons: []string
	ok: bool
	switch {
	case sub == "remove" && all, sub == "rename":
		want := 1 if sub == "remove" else 2
		if len(rest) < want || len(rest) > want + 1 {
			return usage()
		}
		dir_arg := rest[want] if len(rest) > want else ""
		root := root
		if root == "" {
			root = find_root(absolute(dir_arg if dir_arg != "" else "."))
		}
		setup(root)
		// A collection path resolves only after setup reads the collections.
		dir := resolve_package(dir_arg) if dir_arg != "" else ""
		edit, warnings, reasons, ok = server.attr_sweep(dir, rest[0], rest[1] if sub == "rename" else "", config)
	case sub == "add" || sub == "remove":
		if len(rest) != 2 {
			return usage()
		}
		document, _, position, _, code, opened := open_target(name, rest[0], root, symbol_paths = true)
		if !opened {
			return code
		}
		if sub == "add" {
			edit, warnings, reasons, ok = server.attr_add(document, position, rest[1], config)
		} else {
			edit, warnings, reasons, ok = server.attr_remove(document, position, rest[1], config)
		}
	case:
		return usage()
	}
	if !ok {
		return refuse(name, ..reasons)
	}
	return run_edit(name, edit, apply, check, warnings)
}
