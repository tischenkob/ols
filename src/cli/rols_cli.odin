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

USAGE :: `usage: ols query <command> [--root DIR] [--json] [--help]
  def     FILE:LINE:COL                    where the symbol is declared
  refs    FILE:LINE:COL                    every use across the workspace
  impl    FILE:LINE:COL                    members of a proc group, or the groups a proc belongs to
  callers FILE:LINE:COL                    procedures calling the one at the position
  callees FILE:LINE:COL                    procedures it calls
  hover   FILE:LINE:COL                    signature and doc comment
  symbols FILE                             outline of one file
  actions FILE:LINE:COL[-LINE:COL] [--apply TITLE [--no-check]]
                                           refactorings at a position or selection; --apply writes one by title
  rename  TARGET NEW [--apply [--no-check]]
  reorder-params TARGET --order 2,0,1 [--apply [--no-check]]
  move    TARGET --to FILE.odin [--apply [--no-check]]
  rename-package DIR NEW [--apply [--no-check]]
                                           renames the package in DIR: its package clauses, the import paths
                                           and unaliased old.x qualifiers of every importer, and DIR itself
  check   [DIR...]                         odin check errors plus lints, no build or run; run after every edit;
                                           exits 1 on an error. Without DIR: the cwd package, else the packages
                                           below the root that an ols.json defines
  lint    FILE|DIR... [--fail-on CODE,...] lints only, works on code that does not compile; paths in order,
                                           a DIR with every package below it, as check walks them; --fail-on
                                           exits 1 when a listed code is reported
  tests   [DIR|FILE...]                    list @(test) procedures that odin test runs on this target; without
                                           an argument as check does
  test    DIR [NAME,...]                   odin test with the collections and defines of ols.json; NAME is
                                           pkg.name or name, several separated by commas
  api     PKG [NAME]                       exported symbols of a package (a directory or core:strings), one per line;
                                           with NAME the full signature and doc comment
  find    QUERY                            fuzzy symbol search over the workspace
  attr add TARGET KEY[=VALUE] [--apply [--no-check]]
                                           adds KEY to the last @(…) group of the declaration, or a new
                                           @(KEY) line above it; VALUE must parse as an Odin expression
  attr remove TARGET KEY [--apply [--no-check]]
  attr remove --all KEY [DIR] [--apply [--no-check]]
                                           removes KEY from one declaration, or from every declaration in DIR
                                           or the workspace; an emptied group goes, with its line when alone
  attr rename OLD NEW [DIR] [--apply [--no-check]]
                                           renames the attribute key OLD to NEW, keeping its value, in DIR or
                                           the workspace
  modernize [PATH...] [--rule ID,...] [--list] [--diff] [--apply [--no-check]]
                                           rewrites every file with the exact idiom rules, or the rules and
                                           families --rule names, until nothing changes; without --diff or
                                           --apply prints FILE:LINE:COL: [rule] title. PATH defaults to the
                                           workspace. --diff and --apply work as for rename, exit codes included
Output is one line per result, FILE:LINE:COL: TEXT; --json prints the LSP objects instead.
Lines and columns are 1-based, columns in bytes, as odin check prints them.
--root defaults to the nearest directory with an ols.json above the file, else the cwd.
TARGET is FILE:LINE:COL or a symbol path PKG.Name[.Member]: PKG is a directory or a collection path like
core:strings, and Member a struct field, enum member or bit_field field. .Name and ./Name name a symbol
of the package in the cwd. move --to and every other path are relative to the cwd.
rename, reorder-params, move, rename-package and attr without --apply print a unified diff and a summary line.
--apply writes every file or none, after odin check on each touched package; new errors restore every
file. rename-package writes the files first and renames DIR last; a rollback renames it back first.
--no-check skips odin check. With --json they print {"status", "edit", "summary", "reasons"}.
DIR is a directory or a collection path; --root defaults to the nearest ols.json above it, or the cwd.
Refactor exit codes: 0 applied or previewed, 1 refused, 2 usage, 3 nothing to change, 4 rolled back
after odin check reported new errors.
`

// Line and column are 1-based, the column in bytes.
Target :: struct {
	file:       string,
	start, end: [2]int,
}

// --json: print LSP objects instead of lines.
@(private)
json_output: bool

run :: proc(args: []string) -> int {
	// The server logs what an editor log would show, such as a file the indexer cannot parse; the commands
	// report what matters to them on stderr themselves. setup logs the config and builtin folder errors.
	context.logger = log.nil_logger()

	root, apply_title, order_text, move_to := "", "", "", ""
	fail_on := ""
	apply, check_edit, all := false, true, false
	modernize_options: Modernize_Options
	rest := make([dynamic]string, context.temp_allocator)

	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--root":
			i += 1
			if i == len(args) {
				return usage()
			}
			// A relative root would make the workspace folder a relative uri, and searches miss other files.
			root = absolute(args[i])
		case "--order":
			i += 1
			if i == len(args) {
				return usage()
			}
			order_text = args[i]
		case "--fail-on":
			i += 1
			if i == len(args) {
				return usage()
			}
			fail_on = args[i]
		case "--to":
			i += 1
			if i == len(args) {
				return usage()
			}
			move_to = args[i]
		case "--help", "-h":
			// With any command: a requested usage text is an answer, so it goes to stdout and exits 0.
			fmt.print(USAGE)
			return 0
		case "--json":
			json_output = true
		case "--all":
			all = true
		case "--no-check":
			check_edit = false
		case "--rule":
			i += 1
			if i == len(args) {
				return usage()
			}
			modernize_options.rules = args[i]
		case "--list":
			modernize_options.list = true
		case "--diff":
			modernize_options.diff = true
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
	// --all belongs to attr remove, which checks it.
	if all && command != "attr" {
		return usage()
	}

	if command == "modernize" {
		modernize_options.apply, modernize_options.json, modernize_options.check = apply, json_output, check_edit
		return modernize(rest_args, root, modernize_options)
	}

	if command == "attr" {
		return attr(rest_args, root, all, apply, check_edit)
	}

	cwd := os.get_working_directory(context.temp_allocator) or_else "."
	// Without an argument, check and tests cover the package in the cwd, else the packages of the root.
	if len(rest_args) == 0 && (command == "check" || command == "tests") {
		cwd = absolute(cwd)
		root_dir := root if root != "" else find_root(cwd)
		setup(root_dir)
		defined := root != "" || os.exists(path.join({root_dir, "ols.json"}, context.temp_allocator))
		dirs, found := default_packages(cwd, defined)
		if !found {
			return 1
		}
		return check(dirs) if command == "check" else tests(dirs)
	}

	// check, lint and tests take several paths, test takes one; the root comes from the first path.
	if command == "check" || command == "lint" || command == "tests" || command == "test" {
		if len(rest_args) == 0 {
			return usage()
		}
		targets := make([]string, len(rest_args), context.temp_allocator)
		for arg, i in rest_args {
			targets[i] = absolute(arg)
		}
		first := targets[0]
		root_dir :=
			root if root != "" else find_root(first if os.is_directory(first) else path.dir(first, context.temp_allocator))
		setup(root_dir)
		switch command {
		case "check":
			return check(targets)
		case "lint":
			return lint(targets, fail_on, root_dir)
		case "tests":
			return tests(targets)
		case:
			return test(first, strings.join(rest_args[1:], ",", context.temp_allocator))
		}
	}

	if command == "api" || command == "find" {
		if len(rest_args) < 1 || len(rest_args) > (2 if command == "api" else 1) {
			return usage()
		}
		setup(root if root != "" else find_root(cwd))
		if command == "find" {
			return find(rest_args[0])
		}
		return api(resolve_package(rest_args[0]), rest_args[1] if len(rest_args) > 1 else "")
	}

	if command == "rename-package" {
		if len(rest_args) != 2 {
			return usage()
		}
		if root == "" {
			root = find_root(absolute(rest_args[0]))
		}
		setup(root)
		dir := resolve_package(rest_args[0])
		edit, warnings, reasons, ok := server.rename_package(dir, rest_args[1], &common.config)
		if !ok {
			return refuse(command, ..reasons)
		}
		// An unaliased import binds the directory name, so check errors name the package by it.
		return run_edit(command, edit, apply, check_edit, warnings, {path.base(dir), rest_args[1]})
	}

	// rename takes TARGET NEW, every other command here one target; an extra argument is a usage error.
	if len(rest_args) != (2 if command == "rename" else 1) {
		return usage()
	}

	refactor := command == "rename" || command == "reorder-params" || command == "move"
	document, target, position, range, code, opened := open_target(
		command,
		rest_args[0],
		root,
		symbol_paths = refactor,
		whole_file = command == "symbols",
		refuse_unopened = refactor || (command == "actions" && apply),
	)
	if !opened {
		return code
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
		// A file without declarations has an empty outline, which is an answer, not a failure.
		symbols := sorted_symbols(server.get_document_symbols(document))
		if json_output {
			print(symbols)
		} else {
			print_symbols(target.file, symbols)
		}
		return 0
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
				return run_edit("actions", action.edit, true, check_edit)
			}
		}
		return refuse("actions", fmt.tprintf("no action %q, available: %v", apply_title, titles(actions)))
	case "rename":
		new_name := rest_args[1]
		reasons, warnings := server.check_rename(document, position, new_name, config)
		if len(reasons) > 0 {
			return refuse("rename", ..reasons)
		}
		edit, ok := server.get_rename(document, new_name, position)
		if !ok || len(edit.changes) == 0 {
			return refuse("rename", "no symbol to rename at the position")
		}
		// Every edit replaces an occurrence of the old name; the target document has at least one.
		names: [2]string
		if edits := edit.changes[document.uri.uri]; len(edits) > 0 {
			text := document.text[:document.used_text]
			if r, r_ok := common.get_absolute_range(edits[0].range, text);
			   r_ok && r.start <= r.end && r.end <= len(text) {
				names = {string(text[r.start:r.end]), new_name}
			}
		}
		return run_edit("rename", edit, apply, check_edit, warnings, names)
	case "reorder-params":
		order, order_ok := parse_order(order_text)
		if !order_ok {
			fmt.eprintln("--order takes comma separated parameter indices, like 2,0,1")
			return 2
		}
		edit, reason, ok := server.reorder_params(document, position, order)
		if !ok {
			return refuse("reorder-params", reason)
		}
		return run_edit("reorder-params", edit, apply, check_edit)
	case "move":
		if move_to == "" {
			fmt.eprintln("--to names the target file")
			return 2
		}
		// Like every path argument, --to is relative to the cwd. The directory resolves symlinks, as the
		// declaration's does, and the file itself may not exist yet.
		move_to = absolute_new(move_to)
		edit, reason, ok := server.move_declaration(
			document,
			position,
			common.create_uri(move_to, context.temp_allocator).uri,
		)
		if !ok {
			return refuse("move", reason)
		}
		return run_edit("move", edit, apply, check_edit)
	}

	return usage()
}

// Sets up the workspace for spec and opens the file of target, the position spec names. spec is
// FILE:LINE:COL, or a symbol path when symbol_paths is set; with whole_file it is a file, opened at 1:1.
// On failure the cause is printed and code is the exit code: 2 when spec is neither, 1 otherwise. The commands
// that write set refuse_unopened, so a file that cannot be opened goes through refuse.
open_target :: proc(
	name, spec, root: string,
	symbol_paths := false,
	whole_file := false,
	refuse_unopened := false,
) -> (
	document: ^server.Document,
	target: Target,
	position: common.Position,
	range: common.Range,
	code: int,
	ok: bool,
) {
	target_ok: bool
	target, target_ok = parse_target(spec)
	symbol_path := spec if !target_ok && symbol_paths else ""
	if whole_file {
		target, target_ok = Target {
				file  = absolute(spec),
				start = {1, 1},
				end   = {1, 1},
			}, true
	}
	if !target_ok && symbol_path == "" {
		fmt.eprintfln("cannot parse position %q", spec)
		return nil, {}, {}, {}, 2, false
	}

	root := root
	if root == "" {
		root =
			symbol_path_root(symbol_path) if symbol_path != "" else find_root(path.dir(target.file, context.temp_allocator))
	}
	setup(root)
	// An outline reads no diagnostics, and opening the file would lint it, which resolves every node.
	if whole_file do common.config.enable_diagnostics = false
	if symbol_path != "" {
		reason: string
		target, reason, target_ok = resolve_symbol_path(symbol_path)
		if !target_ok {
			return nil, {}, {}, {}, refuse(name, reason), false
		}
	}

	opened: bool
	reason: string
	document, position, range, reason, opened = open(target)
	if !opened {
		if refuse_unopened {
			return nil, {}, {}, {}, refuse(name, reason), false
		}
		fmt.eprintln(reason)
		return nil, {}, {}, {}, 1, false
	}
	return document, target, position, range, 0, true
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

// p against the cwd for a file that may not exist: its directory resolves symlinks, as absolute does for one that does.
absolute_new :: proc(p: string) -> string {
	cwd := os.get_working_directory(context.temp_allocator) or_else "."
	full := p if filepath.is_abs(p) else path.join({cwd, p}, context.temp_allocator)
	full, _ = filepath.replace_separators(full, '/', context.temp_allocator)
	full = path.clean(full, context.temp_allocator)
	return path.join({server.canonical_dir(path.dir(full, context.temp_allocator)), path.base(full)}, context.temp_allocator)
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

// The root for a symbol path: the nearest ols.json above the longest prefix that is a directory, else
// above the cwd. Collection prefixes resolve only after setup reads the collections.
symbol_path_root :: proc(spec: string) -> string {
	for i := len(spec) - 1; i > 0; i -= 1 {
		if spec[i] == '.' && os.is_directory(absolute(spec[:i])) {
			return find_root(absolute(spec[:i]))
		}
	}
	return find_root(os.get_working_directory(context.temp_allocator) or_else ".")
}

// PKG.Name or PKG.Name.Member, where PKG is the longest prefix before a `.` that names a directory with
// .odin files, so package directories may contain dots. `.Name` and `./Name` have the cwd as PKG. reason says
// why the path does not resolve.
resolve_symbol_path :: proc(spec: string) -> (target: Target, reason: string, ok: bool) {
	for i := len(spec) - 1; i >= 0; i -= 1 {
		if spec[i] != '.' {
			continue
		}
		dir := resolve_package(spec[:i] if i > 0 else ".")
		matches, _ := filepath.glob(path.join({dir, "*.odin"}, context.temp_allocator), context.temp_allocator)
		if len(matches) == 0 {
			continue
		}
		found, find_reason, found_ok := server.find_symbol_path(dir, strings.trim_prefix(spec[i + 1:], "/"))
		if !found_ok {
			return {}, find_reason, false
		}
		at := [2]int{found.line, found.column}
		return {file = found.fullpath, start = at, end = at}, "", true
	}
	return {},
		fmt.tprintf("`%s` is neither FILE:LINE:COL nor PKG.Name with PKG a directory of .odin files", spec),
		false
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

	// Config errors and a missing builtin folder reach stderr; the rest of the server's log does not.
	logger := context.logger
	context.logger = log.create_console_logger(.Error)
	root_uri := common.create_uri(root, context.allocator)
	config.workspace_folders = make([dynamic]common.WorkspaceFolder)
	append(&config.workspace_folders, common.WorkspaceFolder{uri = root_uri.uri})

	read_ols_json(path.join({root, "ols.json"}, context.temp_allocator), root_uri)

	if base, ok := config.collections["base"]; ok {
		server.indexer.runtime_package = path.join({base, "runtime"})
		append(&server.indexer.builtin_packages, server.indexer.runtime_package)
	}

	config.builtin_path = server.get_builtin_path()
	context.logger = logger
	server.setup_index(config.builtin_path)
	for pkg in server.indexer.builtin_packages {
		server.try_build_package(pkg)
	}
	server.find_all_package_aliases(config)
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
	reason: string,
	ok: bool,
) {
	text, err := os.read_entire_file(target.file, context.allocator)
	if err != nil {
		reason = fmt.tprintf("cannot read %s: %v", target.file, err)
		return
	}

	uri := common.create_uri(target.file, context.temp_allocator)
	if server.document_open(uri.uri, string(text), &common.config, nil) != .None {
		reason = fmt.tprintf("cannot parse %s", target.file)
		return
	}
	document = server.document_get(uri.uri)

	// or_return would drop the reason: it assigns only the last value on failure.
	range.start, reason, ok = to_position(target.start, text)
	if !ok do return
	range.end, reason, ok = to_position(target.end, text)
	if !ok do return
	return document, range.start, range, "", true
}

to_position :: proc(line_col: [2]int, text: []u8) -> (common.Position, string, bool) {
	line_start, ok := common.get_absolute_position({line = line_col.x - 1}, text)
	if !ok {
		return {}, fmt.tprintf("line %d is past the end of the file", line_col.x), false
	}
	return {line_col.x - 1, common.get_character_offset_u8_to_u16(line_col.y - 1, text[line_start:])}, "", true
}

// Whether dir holds .odin files.
has_odin_files :: proc(dir: string) -> bool {
	matches, _ := filepath.glob(path.join({dir, "*.odin"}, context.temp_allocator), context.temp_allocator)
	return len(matches) > 0
}

// The packages for check and tests without an argument: the cwd when it holds .odin files, else every package
// below the workspace root, but only when an ols.json or --root defines that root.
default_packages :: proc(cwd: string, root_defined: bool) -> (dirs: []string, ok: bool) {
	missing := cwd
	if has_odin_files(cwd) {
		return slice.clone([]string{cwd}, context.temp_allocator), true
	}
	if root_defined {
		dirs = server.workspace_package_dirs(&common.config)
		if len(dirs) > 0 {
			return dirs, true
		}
		missing = common.uri_to_path(common.config.workspace_folders[0].uri, context.temp_allocator)
	}
	fmt.eprintfln("error: no package in %s", missing)
	return nil, false
}

// Whether every directory among targets holds .odin files. The first one that does not is named on stderr.
all_packages :: proc(targets: []string) -> bool {
	for target in targets {
		if os.is_directory(target) && !has_odin_files(target) {
			fmt.eprintfln("error: no package in %s", target)
			return false
		}
	}
	return true
}

// Checks the package directories (or files) targets, prints the diagnostics and returns 1 when one has the
// error severity, or when odin did not run to its JSON.
check :: proc(targets: []string) -> int {
	if !all_packages(targets) {
		return 1
	}
	// resolve_check_paths checks the directory of each path, and a trailing slash keeps DIR itself.
	check_paths := make([]string, len(targets), context.temp_allocator)
	for target, i in targets {
		check_paths[i] =
			target if !os.is_directory(target) else strings.concatenate({target, "/"}, context.temp_allocator)
	}
	server.check_run = {}
	server.check(
		.Saved,
		check_paths,
		&common.config,
		server.gate_check_timeout(len(targets), os.get_processor_core_count()),
	)
	// No package to check (checker_skip_packages) is not a failure; a check that did not run to JSON is.
	if server.check_run.failure != "" {
		fmt.eprintfln("error: %s", server.check_run.failure)
		return 1
	}

	entries := make([dynamic]Entry, context.temp_allocator)
	for uri, diagnostics in server.get_merged_diagnostics() {
		for diagnostic in diagnostics {
			append(&entries, Entry{uri, diagnostic})
		}
	}
	for target in targets {
		if os.is_directory(target) {
			lints, ok := collect_lints(target)
			if !ok {
				return 1
			}
			append(&entries, ..lints)
		}
	}
	print_entries(entries[:])
	for entry in entries {
		if entry.diagnostic.severity == .Error {
			return 1
		}
	}
	return 0
}

// Lists the @(test) procedures of the package directories or files targets.
tests :: proc(targets: []string) -> int {
	if !all_packages(targets) {
		return 1
	}
	found := make([dynamic]server.Test_Proc, context.temp_allocator)
	for target in targets {
		append(&found, ..server.find_tests(target, &common.config))
	}
	slice.sort_by(found[:], proc(a, b: server.Test_Proc) -> bool {
		return a.file < b.file if a.file != b.file else a.line < b.line
	})
	// A file inside a directory that is also a target lists its tests once.
	unique := slice.unique(found[:])
	if json_output {
		return print_nonempty(unique)
	}
	for test in unique {
		fmt.printfln("%s:%d:%d: %s", test.file, test.line, test.col, test.name)
	}
	return 0 if len(unique) > 0 else 1
}

// Runs odin test on dir. A name that no test of dir has is refused, since odin only reports it and exits 0.
test :: proc(dir: string, names: string) -> int {
	if names != "" {
		found := server.find_tests(dir, &common.config)
		for name in strings.split(names, ",", context.temp_allocator) {
			name := strings.trim_space(name)
			matches := false
			for test in found {
				matches ||= name == test.name || name == fmt.tprintf("%s.%s", test.pkg, test.name)
			}
			if !matches {
				fmt.eprintfln("error: no test %q in %s", name, dir)
				return 1
			}
		}
	}
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

// The declarations of the workspace that match query, private ones and those of other targets included; the
// text output marks them with (private) and (other platform).
find :: proc(query: string) -> int {
	symbols := server.find_symbols(query, &common.config)
	if json_output {
		return print_nonempty(symbols)
	}
	for symbol in symbols {
		file := common.uri_to_path(symbol.location.uri, context.temp_allocator)
		line, col := line_col(file, symbol.location.range.start)
		fmt.printf("%s:%d:%d: %v %s", file, line, col, symbol.kind, symbol.name)
		if symbol.private || symbol.otherPlatform {
			marks := make([dynamic]string, context.temp_allocator)
			if symbol.private do append(&marks, "private")
			if symbol.otherPlatform do append(&marks, "other platform")
			fmt.printf(" (%s)", strings.join(marks[:], ", ", context.temp_allocator))
		}
		fmt.println()
	}
	return 0 if len(symbols) > 0 else 1
}

Call :: struct {
	name:       string,
	uri:        string,
	range:      common.Range,
	fromRanges: []common.Range,
}

// Lints each of targets in order, and a file that two targets share once. A directory covers the packages below
// it that check walks. fail_on lists diagnostic codes, comma separated; any of them in the output makes the exit
// code 1.
lint :: proc(targets: []string, fail_on: string, root: string) -> int {
	// Temp memory is freed after each package, so whatever outlives one lives on the heap.
	targets := slice.clone(targets)
	for &target in targets {
		target = strings.clone(target)
	}
	root := strings.clone(root)
	entries := make([dynamic]Entry)
	for target in targets {
		packages := []string{target}
		if os.is_directory(target) {
			packages = server.package_dirs_below(target, root, &common.config, context.allocator)
			if len(packages) == 0 {
				fmt.eprintfln("error: no package in %s", target)
				return 1
			}
		}
		first := len(entries)
		for dir in packages {
			lints, ok := collect_lints(dir, context.allocator, note_unparsed = true)
			server.clear_index_cache()
			free_all(context.temp_allocator)
			if !ok {
				return 1
			}
			append(&entries, ..lints)
		}
		sort_entries(entries[first:])
	}
	print_entries(entries[:], sorted = true)
	if fail_on == "" {
		return 0
	}
	codes := strings.split(fail_on, ",", context.temp_allocator)
	for entry in entries {
		if slice.contains(codes, entry.diagnostic.code) {
			return 1
		}
	}
	return 0
}

// The uris collect_lints linted, so a later target skips them.
@(private)
linted: map[string]struct{}

// The workspace filter of the run, built on the first collect_lints call, on the heap.
@(private)
lint_filter: Maybe(common.Workspace_Filter)

// Per-file lints, unused imports and unused private declarations of one file or a package directory, in
// allocator. A file an earlier call linted is left out, and so is a file of the directory that the workspace
// filter skips, unless the filter skips the directory itself, which only a directory named on the command line
// can be. The documents are closed again. With note_unparsed, a file that does not parse is noted on stderr and its
// diagnostics are left out.
collect_lints :: proc(target: string, allocator := context.temp_allocator, note_unparsed := false) -> ([]Entry, bool) {
	files := []string{target}
	if os.is_directory(target) {
		err: os.Error
		files, err = filepath.glob(path.join({target, "*.odin"}, context.temp_allocator), context.temp_allocator)
		if err != nil {
			fmt.eprintfln("cannot list %s: %v", target, err)
			return {}, false
		}
		if lint_filter == nil && len(common.config.workspace_folders) > 0 {
			root := common.uri_to_path(common.config.workspace_folders[0].uri, context.temp_allocator)
			lint_filter = common.workspace_filter_make(root, &common.config, context.allocator)
		}
		if filter, ok := &lint_filter.?; ok && !common.workspace_filter_skip_dir(filter, target) {
			kept := make([dynamic]string, context.temp_allocator)
			for file in files {
				if !common.workspace_filter_skip_file(filter, file) do append(&kept, file)
			}
			files = kept[:]
		}
	}

	// document_open runs the per-file lints; the unused import check runs per open, as didOpen does. The
	// documents live in a map that moves as it grows, so a ^Document is good only until the next open.
	opened := make([dynamic]string, context.temp_allocator)
	defer for uri in opened {
		server.document_close(uri)
	}
	unparsed := make(map[string]struct{}, context.temp_allocator)
	document: ^server.Document
	for file in files {
		uri := common.create_uri(file, context.temp_allocator).uri
		if uri in linted do continue
		reason: string
		ok: bool
		document, _, _, reason, ok = open(Target{file = file, start = {1, 1}, end = {1, 1}})
		if !ok {
			fmt.eprintln(reason)
			return {}, false
		}
		append(&opened, strings.clone(document.uri.uri, context.temp_allocator))
		if note_unparsed && document.ast.syntax_error_count > 0 {
			fmt.eprintfln("%s: skipped, the file does not parse", file)
			unparsed[opened[len(opened) - 1]] = {}
		}
		server.check_unused_imports(document, &common.config)
		linted[strings.clone(uri)] = {}
	}
	if document != nil {
		server.lint_unused_declarations(document, &common.config)
	}

	entries := make([dynamic]Entry, allocator)
	for opened_uri in opened {
		if opened_uri in unparsed do continue
		uri := strings.clone(opened_uri, allocator)
		for type in ([]server.DiagnosticType{.Lint, .Unused, .Unused_Decl}) {
			for diagnostic in server.diagnostics_of(type, uri, allocator) {
				append(&entries, Entry{uri, diagnostic})
			}
		}
	}
	return entries[:], true
}

sort_entries :: proc(entries: []Entry) {
	slice.sort_by(entries, proc(a, b: Entry) -> bool {
		if a.uri != b.uri do return a.uri < b.uri
		return a.diagnostic.range.start.line < b.diagnostic.range.start.line
	})
}

// Prints entries by file and line, or in their given order when sorted is set.
print_entries :: proc(entries: []Entry, sorted := false) {
	if !sorted {
		sort_entries(entries)
	}
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

// The symbols by position, then name, and their children the same way: the server collects the top level
// from a map, whose order changes between runs.
sorted_symbols :: proc(symbols: []server.DocumentSymbol) -> []server.DocumentSymbol {
	sorted := slice.clone(symbols, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: server.DocumentSymbol) -> bool {
		a_at, b_at := a.selectionRange.start, b.selectionRange.start
		if a_at.line != b_at.line do return a_at.line < b_at.line
		if a_at.character != b_at.character do return a_at.character < b_at.character
		return a.name < b.name
	})
	for &symbol in sorted {
		symbol.children = sorted_symbols(symbol.children)
	}
	return sorted
}

// FILE:LINE:COL: KIND NAME, a member indented by two spaces below the symbol it belongs to.
print_symbols :: proc(file: string, symbols: []server.DocumentSymbol, indent := "") {
	for symbol in symbols {
		line, col := line_col(file, symbol.selectionRange.start)
		fmt.printfln("%s:%d:%d: %s%v %s", file, line, col, indent, symbol.kind, symbol.name)
		print_symbols(file, symbol.children, strings.concatenate({indent, "  "}, context.temp_allocator))
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
