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

USAGE :: `usage: ols query <command> [--root DIR] [--json]
  def     FILE:LINE:COL                    where the symbol is declared
  refs    FILE:LINE:COL                    every use across the workspace
  impl    FILE:LINE:COL                    members of a proc group, or the groups a proc belongs to
  callers FILE:LINE:COL                    procedures calling the one at the position
  callees FILE:LINE:COL                    procedures it calls
  hover   FILE:LINE:COL                    signature and doc comment
  symbols FILE                             outline of one file
  actions FILE:LINE:COL[-LINE:COL] [--apply TITLE]
                                           refactorings at a position or selection; --apply writes one by title
  rename  FILE:LINE:COL NEW [--apply]
  reorder-params FILE:LINE:COL --order 2,0,1 [--apply]
  move    FILE:LINE:COL --to TARGET.odin [--apply]
  check   [DIR]                            odin check errors plus lints, no build or run; run after every edit
  lint    FILE|DIR                         lints only, works on code that does not compile
  tests   [DIR|FILE]                       list @(test) procedures
  test    DIR [NAME,...]                   odin test with the collections and defines of ols.json; NAME is
                                           pkg.name or name, several separated by commas
  api     PKG [NAME]                       exported symbols of a package (a directory or core:strings), one per line;
                                           with NAME the full signature and doc comment
  find    QUERY                            fuzzy symbol search over the workspace
Output is one line per result, FILE:LINE:COL: TEXT; --json prints the LSP objects instead.
Lines and columns are 1-based, columns in bytes, as odin check prints them.
--root defaults to the nearest directory with an ols.json above the file, else the cwd.
`

// Line and column are 1-based, the column in bytes.
Target :: struct {
	file:       string,
	start, end: [2]int,
}

@(private = "file")
json_output: bool

run :: proc(args: []string) -> int {
	context.logger = log.create_console_logger(.Error)

	root, apply_title, order_text, move_to := "", "", "", ""
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
		case "--order":
			i += 1
			if i == len(args) {
				return usage()
			}
			order_text = args[i]
		case "--to":
			i += 1
			if i == len(args) {
				return usage()
			}
			move_to = args[i]
		case "--json":
			json_output = true
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

	if command == "lint" || command == "tests" || command == "test" {
		target := os.get_working_directory(context.temp_allocator) or_else "."
		if len(rest_args) > 0 {
			target = rest_args[0]
		} else if command != "tests" {
			return usage()
		}
		target = absolute(target)
		setup(
			root if root != "" else find_root(target if os.is_directory(target) else path.dir(target, context.temp_allocator)),
		)
		switch command {
		case "lint":
			return lint(target)
		case "tests":
			return tests(target)
		case:
			return test(target, strings.join(rest_args[1:], ",", context.temp_allocator))
		}
	}

	if command == "api" || command == "find" {
		if len(rest_args) < 1 {
			return usage()
		}
		cwd := os.get_working_directory(context.temp_allocator) or_else "."
		setup(root if root != "" else find_root(cwd))
		if command == "find" {
			return find(rest_args[0])
		}
		return api(resolve_package(rest_args[0]), rest_args[1] if len(rest_args) > 1 else "")
	}

	if len(rest_args) < 1 || (command == "rename" && len(rest_args) < 2) {
		return usage()
	}

	target, target_ok := parse_target(rest_args[0])
	if command == "symbols" {
		target, target_ok = Target {
				file  = absolute(rest_args[0]),
				start = {1, 1},
				end   = {1, 1},
			}, true
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
		return print_locations(locations)
	case "refs":
		locations, _ := server.get_references(document, position)
		return print_locations(locations)
	case "impl":
		return print_locations(server.get_implementation_locations(document, position))
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
		if json_output {
			return print_nonempty(calls[:])
		}
		for call in calls {
			print_location({call.uri, call.range}, call.name)
		}
		return 0 if len(calls) > 0 else 1
	case "hover":
		hover, valid, _ := server.get_hover_information(document, position)
		if !valid {
			return 1
		}
		if json_output {
			print(hover)
		} else {
			fmt.println(hover.contents.value)
		}
		return 0
	case "symbols":
		symbols := server.get_document_symbols(document)
		if json_output {
			return print_nonempty(symbols)
		}
		print_symbols(target.file, symbols, "")
		return 0 if len(symbols) > 0 else 1
	case "actions":
		actions, _ := server.get_code_actions(document, {}, range, config)
		if apply_title == "" {
			if json_output {
				return print_nonempty(actions)
			}
			for action in actions {
				fmt.println(action.title)
			}
			return 0 if len(actions) > 0 else 1
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
		print_edit(edit)
		return 0
	case "reorder-params":
		order, order_ok := parse_order(order_text)
		if !order_ok {
			fmt.eprintln("--order takes comma separated parameter indices, like 2,0,1")
			return 2
		}
		edit, ok := server.reorder_params(document, position, order)
		if !ok {
			fmt.eprintln(
				"cannot reorder: the position must be on the name of a plain procedure that is only ever called with every argument positional, and --order must list each index once",
			)
			return 1
		}
		if apply {
			return apply_edit(edit)
		}
		print_edit(edit)
		return 0
	case "move":
		if move_to == "" {
			fmt.eprintln("--to names the target file")
			return 2
		}
		if !filepath.is_abs(move_to) {
			move_to = path.join({path.dir(target.file, context.temp_allocator), move_to}, context.temp_allocator)
		}
		edit, ok := server.move_declaration(document, position, common.create_uri(move_to, context.temp_allocator).uri)
		if !ok {
			fmt.eprintln(
				"cannot move: the position must be on the name of a top-level declaration that is not file private and uses no file-private symbol, and --to must name a .odin file of the same directory",
			)
			return 1
		}
		if apply {
			return apply_edit(edit)
		}
		print_edit(edit)
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

parse_order :: proc(text: string) -> ([]int, bool) {
	parts := strings.split(text, ",", context.temp_allocator)
	order := make([]int, len(parts), context.temp_allocator)
	for part, i in parts {
		ok: bool
		order[i], ok = strconv.parse_int(strings.trim_space(part))
		if !ok {
			return {}, false
		}
	}
	return order, len(order) > 0
}

find_root :: proc(dir: string) -> string {
	for d := dir;; d = path.dir(d, context.temp_allocator) {
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
	config.client_create_file_support = true

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

open :: proc(
	target: Target,
) -> (
	document: ^server.Document,
	position: common.Position,
	range: common.Range,
	ok: bool,
) {
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
	if os.is_directory(dir) {
		lints, ok := collect_lints(dir)
		if !ok {
			return 1
		}
		append(&entries, ..lints)
	}
	print_entries(entries[:])
	return 0
}

tests :: proc(target: string) -> int {
	found := server.find_tests(target, &common.config)
	if json_output {
		return print_nonempty(found)
	}
	for test in found {
		fmt.printfln("%s:%d:%d: %s", test.file, test.line, test.col, test.name)
	}
	return 0 if len(found) > 0 else 1
}

test :: proc(dir: string, names: string) -> int {
	cmd := server.test_command(dir, names, &common.config)
	fmt.eprintln(strings.join(cmd, " ", context.temp_allocator))
	process, err := os.process_start({command = cmd, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("cannot run %s: %v", cmd[0], err)
		return 1
	}
	state, _ := os.process_wait(process)
	return state.exit_code
}

Entry :: struct {
	uri:        string,
	diagnostic: server.Diagnostic,
}

// A collection path like core:strings, else a directory. The index keys packages by clean forward-slash paths.
resolve_package :: proc(arg: string) -> string {
	if i := strings.index_byte(arg, ':'); i > 0 {
		if base, ok := common.config.collections[arg[:i]]; ok {
			return path.join({base, arg[i + 1:]}, context.temp_allocator)
		}
	}
	dir, _ := filepath.replace_separators(absolute(arg), '/', context.temp_allocator)
	return path.clean(dir, context.temp_allocator)
}

api :: proc(dir: string, name: string) -> int {
	text, ok := server.get_package_api(dir, name)
	if !ok {
		if name == "" {
			fmt.eprintfln("no package at %s", dir)
		} else {
			fmt.eprintfln("no exported symbol %s in %s", name, dir)
		}
		return 1
	}
	fmt.print(text)
	return 0
}

find :: proc(query: string) -> int {
	symbols, _ := server.get_workspace_symbols(query)
	if json_output {
		return print_nonempty(symbols)
	}
	for symbol in symbols {
		file := common.uri_to_path(symbol.location.uri, context.temp_allocator)
		line, col := line_col(file, symbol.location.range.start)
		fmt.printfln("%s:%d:%d: %v %s", file, line, col, symbol.kind, symbol.name)
	}
	return 0 if len(symbols) > 0 else 1
}

Call :: struct {
	name:       string,
	uri:        string,
	range:      common.Range,
	fromRanges: []common.Range,
}

lint :: proc(target: string) -> int {
	entries, ok := collect_lints(target)
	if !ok {
		return 1
	}
	print_entries(entries)
	return 0
}

// Per-file lints, unused imports and unused private declarations of one file or a package directory.
collect_lints :: proc(target: string) -> ([]Entry, bool) {
	files := []string{target}
	if os.is_directory(target) {
		err: os.Error
		files, err = filepath.glob(path.join({target, "*.odin"}, context.temp_allocator), context.temp_allocator)
		if err != nil {
			fmt.eprintfln("cannot list %s: %v", target, err)
			return {}, false
		}
	}

	// document_open runs the per-file lints and the unused import check.
	uris := make(map[string]struct{}, context.temp_allocator)
	document: ^server.Document
	for file in files {
		ok: bool
		document, _, _, ok = open(Target{file = file, start = {1, 1}, end = {1, 1}})
		if !ok {
			return {}, false
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
	return entries[:], true
}

print_entries :: proc(entries: []Entry) {
	slice.sort_by(entries, proc(a, b: Entry) -> bool {
		if a.uri != b.uri do return a.uri < b.uri
		return a.diagnostic.range.start.line < b.diagnostic.range.start.line
	})
	if json_output {
		print(entries)
		return
	}
	for entry in entries {
		file := common.uri_to_path(entry.uri, context.temp_allocator)
		line, col := line_col(file, entry.diagnostic.range.start)
		severity := strings.to_lower(fmt.tprint(entry.diagnostic.severity), context.temp_allocator)
		message, _ := strings.replace_all(entry.diagnostic.message, "\n", "\n\t", context.temp_allocator)
		fmt.printfln("%s:%d:%d: %s: %s [%s]", file, line, col, severity, message, entry.diagnostic.code)
	}
}

apply_edit :: proc(edit: server.WorkspaceEdit) -> int {
	written := make([dynamic]string, context.temp_allocator)
	if changes, has := edit.documentChanges.?; has {
		for change in changes {
			switch c in change {
			case server.CreateFile:
				file := common.uri_to_path(c.uri, context.temp_allocator)
				if !os.exists(file) {
					if err := os.write_entire_file(file, ""); err != nil {
						fmt.eprintfln("cannot create %s: %v", file, err)
						return 1
					}
				}
			case server.TextDocumentEdit:
				if !apply_file_edits(c.textDocument.uri, c.edits, &written) {
					return 1
				}
			}
		}
	}
	for uri, edits in edit.changes {
		if !apply_file_edits(uri, edits, &written) {
			return 1
		}
	}
	if json_output {
		print(written[:])
	} else {
		for file in written {
			fmt.println(file)
		}
	}
	return 0
}

apply_file_edits :: proc(uri: string, edits: []server.TextEdit, written: ^[dynamic]string) -> bool {
	file := common.uri_to_path(uri, context.temp_allocator)
	text, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s: %v", file, err)
		return false
	}
	new_text := common.apply_text_edits(edits, string(text))
	if err := os.write_entire_file(file, transmute([]u8)new_text); err != nil {
		fmt.eprintfln("cannot write %s: %v", file, err)
		return false
	}
	append(written, file)
	return true
}

print_edit :: proc(edit: server.WorkspaceEdit) {
	if json_output {
		print(edit)
		return
	}
	if changes, has := edit.documentChanges.?; has {
		for change in changes {
			switch c in change {
			case server.CreateFile:
				fmt.printfln("%s: create", common.uri_to_path(c.uri, context.temp_allocator))
			case server.TextDocumentEdit:
				print_text_edits(c.textDocument.uri, c.edits)
			}
		}
	}
	for uri, edits in edit.changes {
		print_text_edits(uri, edits)
	}
}

print_text_edits :: proc(uri: string, edits: []server.TextEdit) {
	file := common.uri_to_path(uri, context.temp_allocator)
	for edit in edits {
		line, col := line_col(file, edit.range.start)
		end_line, end_col := line_col(file, edit.range.end)
		fmt.printfln("%s:%d:%d-%d:%d: %q", file, line, col, end_line, end_col, edit.newText)
	}
}

titles :: proc(actions: []server.CodeAction) -> []string {
	result := make([]string, len(actions), context.temp_allocator)
	for action, i in actions {
		result[i] = action.title
	}
	return result
}

print_locations :: proc(locations: []common.Location) -> int {
	if json_output {
		return print_nonempty(locations)
	}
	for location in locations {
		print_location(location)
	}
	return 0 if len(locations) > 0 else 1
}

// FILE:LINE:COL: the source line, prefixed by name when given.
print_location :: proc(location: common.Location, name := "") {
	file := common.uri_to_path(location.uri, context.temp_allocator)
	line, col := line_col(file, location.range.start)
	text := strings.trim_space(line_text(file, location.range.start.line))
	if name != "" {
		fmt.printf("%s ", name)
	}
	fmt.printfln("%s:%d:%d: %s", file, line, col, text)
}

print_symbols :: proc(file: string, symbols: []server.DocumentSymbol, indent: string) {
	for symbol in symbols {
		line, col := line_col(file, symbol.selectionRange.start)
		fmt.printfln("%s%d:%d %v %s", indent, line, col, symbol.kind, symbol.name)
		print_symbols(file, symbol.children, strings.concatenate({indent, "\t"}, context.temp_allocator))
	}
}

// 1-based line and byte column of an LSP position.
line_col :: proc(file: string, position: common.Position) -> (int, int) {
	text := line_text(file, position.line)
	return position.line + 1, common.get_character_offset_u16_to_u8(position.character, transmute([]u8)text) + 1
}

@(private = "file")
file_lines: map[string][]string

line_text :: proc(file: string, line: int) -> string {
	lines, cached := file_lines[file]
	if !cached {
		data, _ := os.read_entire_file(file, context.allocator)
		lines = strings.split_lines(string(data))
		file_lines[file] = lines
	}
	return lines[line] if line < len(lines) else ""
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
