package cli

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "src:common"
import "src:server"

USAGE :: `usage: ols query <command> [--root DIR]
  def     FILE:LINE:COL
  refs    FILE:LINE:COL
  impl    FILE:LINE:COL
  callers FILE:LINE:COL
  callees FILE:LINE:COL
  hover   FILE:LINE:COL
  symbols FILE
  actions FILE:LINE:COL[-LINE:COL] [--apply TITLE]
  rename  FILE:LINE:COL NEW [--apply]
  check   [DIR]
  lint    FILE|DIR
Lines and columns are 1-based, columns in bytes, as odin check prints them.
--root defaults to the nearest directory with an ols.json above the file, else the cwd.
`

// Line and column are 1-based, the column in bytes.
Target :: struct {
	file:       string,
	start, end: [2]int,
}

run :: proc(args: []string) -> int {
	context.logger = log.create_console_logger(.Error)

	root, apply_title := "", ""
	apply := false
	rest := make([dynamic]string, context.temp_allocator)

	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--root":
			i += 1
			if i == len(args) {
				return usage()
			}
			root = args[i]
		case "--apply":
			apply = true
			if len(rest) > 0 && rest[0] == "actions" && i + 1 < len(args) {
				i += 1
				apply_title = args[i]
			}
		case:
			append(&rest, args[i])
		}
	}

	if len(rest) == 0 {
		return usage()
	}

	command := rest[0]
	rest_args := rest[1:]

	if command == "check" {
		dir := os.get_working_directory(context.temp_allocator) or_else "."
		if len(rest_args) > 0 {
			dir = rest_args[0]
		}
		dir = absolute(dir)
		setup(root if root != "" else find_root(dir))
		return check(dir)
	}

	if command == "lint" {
		if len(rest_args) < 1 {
			return usage()
		}
		target := absolute(rest_args[0])
		setup(root if root != "" else find_root(target if os.is_directory(target) else path.dir(target, context.temp_allocator)))
		return lint(target)
	}

	if len(rest_args) < 1 || (command == "rename" && len(rest_args) < 2) {
		return usage()
	}

	target, target_ok := parse_target(rest_args[0])
	if command == "symbols" {
		target, target_ok = Target{file = absolute(rest_args[0]), start = {1, 1}, end = {1, 1}}, true
	}
	if !target_ok {
		fmt.eprintfln("cannot parse position %q", rest_args[0])
		return 2
	}

	setup(root if root != "" else find_root(path.dir(target.file, context.temp_allocator)))

	document, position, range, open_ok := open(target)
	if !open_ok {
		return 1
	}
	config := &common.config

	switch command {
	case "def":
		locations, _ := server.get_definition_location(document, position, config)
		return print_nonempty(locations)
	case "refs":
		locations, _ := server.get_references(document, position)
		return print_nonempty(locations)
	case "impl":
		return print_nonempty(server.get_implementation_locations(document, position))
	case "callers", "callees":
		items := server.prepare_call_hierarchy(document, position)
		if len(items) == 0 {
			fmt.eprintln("no procedure at position")
			return 1
		}
		calls := make([dynamic]Call, context.temp_allocator)
		if command == "callers" {
			for call in server.incoming_calls(items[0]) {
				append(&calls, Call{call.from.name, call.from.uri, call.from.selectionRange, call.fromRanges})
			}
		} else {
			for call in server.outgoing_calls(items[0]) {
				append(&calls, Call{call.to.name, call.to.uri, call.to.selectionRange, call.fromRanges})
			}
		}
		return print_nonempty(calls[:])
	case "hover":
		hover, valid, _ := server.get_hover_information(document, position)
		if !valid {
			return 1
		}
		print(hover)
		return 0
	case "symbols":
		return print_nonempty(server.get_document_symbols(document))
	case "actions":
		actions, _ := server.get_code_actions(document, {}, range, config)
		if apply_title == "" {
			return print_nonempty(actions)
		}
		for action in actions {
			if action.title == apply_title {
				return apply_edit(action.edit)
			}
		}
		fmt.eprintfln("no action %q, available: %v", apply_title, titles(actions))
		return 1
	case "rename":
		edit, ok := server.get_rename(document, rest_args[1], position)
		if !ok || len(edit.changes) == 0 {
			return 1
		}
		if apply {
			return apply_edit(edit)
		}
		print(edit)
		return 0
	}

	return usage()
}

usage :: proc() -> int {
	fmt.eprint(USAGE)
	return 2
}

absolute :: proc(p: string) -> string {
	abs, err := filepath.abs(p, context.allocator)
	if err != nil {
		return p
	}
	return abs
}

// FILE:LINE:COL or FILE:LINE:COL-LINE:COL, parsed from the right so the file may contain colons.
parse_target :: proc(s: string) -> (target: Target, ok: bool) {
	parts := strings.split(s, ":", context.temp_allocator)
	n := len(parts)
	if n < 3 {
		return
	}

	if dash := strings.index(parts[n - 2], "-"); dash != -1 {
		if n < 4 {
			return
		}
		target.file = strings.join(parts[:n - 3], ":", context.temp_allocator)
		target.start.x = strconv.parse_int(parts[n - 3]) or_return
		target.start.y = strconv.parse_int(parts[n - 2][:dash]) or_return
		target.end.x = strconv.parse_int(parts[n - 2][dash + 1:]) or_return
		target.end.y = strconv.parse_int(parts[n - 1]) or_return
	} else {
		target.file = strings.join(parts[:n - 2], ":", context.temp_allocator)
		target.start.x = strconv.parse_int(parts[n - 2]) or_return
		target.start.y = strconv.parse_int(parts[n - 1]) or_return
		target.end = target.start
	}

	target.file = absolute(target.file)
	return target, target.start.x > 0 && target.start.y > 0 && target.end.x > 0 && target.end.y > 0
}

find_root :: proc(dir: string) -> string {
	for d := dir; ; d = path.dir(d, context.temp_allocator) {
		if os.exists(path.join({d, "ols.json"}, context.temp_allocator)) {
			return d
		}
		if d == "/" || d == "." || d == "" {
			break
		}
	}
	return os.get_working_directory(context.allocator) or_else "."
}

setup :: proc(root: string) {
	config := &common.config
	config.collections = make(map[string]string)
	server.apply_default_config(config)

	root_uri := common.create_uri(root, context.allocator)
	config.workspace_folders = make([dynamic]common.WorkspaceFolder)
	append(&config.workspace_folders, common.WorkspaceFolder{uri = root_uri.uri})

	read_ols_json(path.join({root, "ols.json"}, context.temp_allocator), root_uri)

	if base, ok := config.collections["base"]; ok {
		server.indexer.runtime_package = path.join({base, "runtime"})
		append(&server.indexer.builtin_packages, server.indexer.runtime_package)
	}

	config.builtin_path = server.get_builtin_path()
	server.setup_index(config.builtin_path)
	for pkg in server.indexer.builtin_packages {
		server.try_build_package(pkg)
	}
	server.find_all_package_aliases()
}

// Also called for a missing file: read_ols_initialize_options adds the core, base and vendor collections.
read_ols_json :: proc(file: string, uri: common.Uri) {
	ols_config: server.OlsConfig
	if data, err := os.read_entire_file(file, context.temp_allocator); err == nil {
		if json_err := json.unmarshal(data, &ols_config, allocator = context.temp_allocator); json_err != nil {
			log.errorf("Failed to unmarshal %v: %v", file, json_err)
		}
	}
	server.read_ols_initialize_options(&common.config, ols_config, uri)
}

open :: proc(target: Target) -> (document: ^server.Document, position: common.Position, range: common.Range, ok: bool) {
	text, err := os.read_entire_file(target.file, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s: %v", target.file, err)
		return
	}

	uri := common.create_uri(target.file, context.temp_allocator)
	if server.document_open(uri.uri, string(text), &common.config, nil) != .None {
		fmt.eprintfln("cannot parse %s", target.file)
		return
	}
	document = server.document_get(uri.uri)

	range.start = to_position(target.start, text) or_return
	range.end = to_position(target.end, text) or_return
	return document, range.start, range, true
}

to_position :: proc(line_col: [2]int, text: []u8) -> (common.Position, bool) {
	line_start, ok := common.get_absolute_position({line = line_col.x - 1}, text)
	if !ok {
		fmt.eprintfln("line %d is past the end of the file", line_col.x)
		return {}, false
	}
	return {line_col.x - 1, common.get_character_offset_u8_to_u16(line_col.y - 1, text[line_start:])}, true
}

check :: proc(dir: string) -> int {
	// resolve_check_paths checks the directory of each path, and a trailing slash keeps DIR itself.
	check_path := dir if !os.is_directory(dir) else strings.concatenate({dir, "/"}, context.temp_allocator)
	server.check(.Saved, {check_path}, &common.config)

	entries := make([dynamic]Entry, context.temp_allocator)
	for uri, diagnostics in server.get_merged_diagnostics() {
		for diagnostic in diagnostics {
			append(&entries, Entry{uri, diagnostic})
		}
	}
	print(entries[:])
	return 0
}

Entry :: struct {
	uri:        string,
	diagnostic: server.Diagnostic,
}

Call :: struct {
	name:       string,
	uri:        string,
	range:      common.Range,
	fromRanges: []common.Range,
}

lint :: proc(target: string) -> int {
	files := []string{target}
	if os.is_directory(target) {
		err: os.Error
		files, err = filepath.glob(path.join({target, "*.odin"}, context.temp_allocator), context.temp_allocator)
		if err != nil {
			fmt.eprintfln("cannot list %s: %v", target, err)
			return 1
		}
	}

	// document_open runs the per-file lints and the unused import check.
	uris := make(map[string]struct{}, context.temp_allocator)
	document: ^server.Document
	for file in files {
		ok: bool
		document, _, _, ok = open(Target{file = file, start = {1, 1}, end = {1, 1}})
		if !ok {
			return 1
		}
		uris[document.uri.uri] = {}
	}
	if document != nil {
		server.lint_unused_declarations(document, &common.config)
	}

	entries := make([dynamic]Entry, context.temp_allocator)
	for type in ([]server.DiagnosticType{.Lint, .Unused, .Unused_Decl}) {
		for uri, diagnostics in server.diagnostics[type] {
			if uri not_in uris do continue
			for diagnostic in diagnostics {
				append(&entries, Entry{uri, diagnostic})
			}
		}
	}
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool {
		if a.uri != b.uri do return a.uri < b.uri
		return a.diagnostic.range.start.line < b.diagnostic.range.start.line
	})
	print(entries[:])
	return 0
}

apply_edit :: proc(edit: server.WorkspaceEdit) -> int {
	written := make([dynamic]string, context.temp_allocator)
	for uri, edits in edit.changes {
		file := common.uri_to_path(uri, context.temp_allocator)
		text, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("cannot read %s: %v", file, err)
			return 1
		}
		new_text := common.apply_text_edits(edits, string(text))
		if err := os.write_entire_file(file, transmute([]u8)new_text); err != nil {
			fmt.eprintfln("cannot write %s: %v", file, err)
			return 1
		}
		append(&written, file)
	}
	print(written[:])
	return 0
}

titles :: proc(actions: []server.CodeAction) -> []string {
	result := make([]string, len(actions), context.temp_allocator)
	for action, i in actions {
		result[i] = action.title
	}
	return result
}

print_nonempty :: proc(items: []$T) -> int {
	print(items)
	return 0 if len(items) > 0 else 1
}

print :: proc(v: any) {
	data, err := server.marshal(v, {}, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("cannot marshal result: %v", err)
		return
	}
	fmt.println(string(data))
}
