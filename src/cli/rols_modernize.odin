package cli

import "core:fmt"
import "core:os"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"
import "src:server"

Modernize_Options :: struct {
	rules:                          string, // comma separated rule ids and family names, "" for the defaults
	list, diff, apply, json, check: bool,
}

Modernize_Entry :: struct {
	file:      string,
	line, col: int,
	rule:      string,
	title:     string,
	pass:      int,
}

// Rewrites every file of paths, or of the workspace when there are none. Without --diff or --apply
// it lists the fixes. --diff and --apply go through run_edit as one workspace edit, so they print
// the same diff, write every file or none after odin check, and share the refactor exit codes; the
// list uses them too: 0 with fixes, 1 refused, 2 usage, 3 nothing to change.
modernize :: proc(paths: []string, root: string, options: Modernize_Options) -> int {
	targets := make([dynamic]string, context.temp_allocator)
	for p in paths {
		append(&targets, absolute(p))
	}
	cwd := os.get_working_directory(context.temp_allocator) or_else "."
	root := root
	if root == "" {
		start := cwd
		if len(targets) > 0 {
			start = targets[0] if os.is_directory(targets[0]) else path.dir(targets[0], context.temp_allocator)
		}
		root = find_root(start)
	}
	root = strings.clone(absolute(root))
	// The recipes of ols.json are rules too, so --list and --rule need the config.
	setup(root)

	// A broken recipe is skipped like a file that does not parse; the other rules still run.
	for problem in server.modernize_recipe_errors(&common.config) {
		fmt.eprintfln("%s; skipped", problem)
	}

	if options.list {
		rules := server.modernize_rules(&common.config)
		if options.json {
			print(rules)
			return 0
		}
		for rule in rules {
			fmt.printfln("%s\t%s%s", rule.id, rule.family, rule.default ? "\tdefault" : "")
		}
		return 0
	}

	tokens: []string
	if options.rules != "" {
		tokens = strings.split(options.rules, ",", context.temp_allocator)
	}
	selected, unknown, ok := server.modernize_select(tokens, &common.config, context.allocator)
	if !ok {
		fmt.eprintfln("unknown rule or family %q; `ols query modernize --list` prints them", unknown)
		return 2
	}

	files := modernize_files(targets[:], root)
	entries := make([dynamic]Modernize_Entry)
	// One edit per changed file, replacing its whole text, on the heap: temp is freed per file.
	edit := server.WorkspaceEdit {
		changes = make(map[string][]server.TextEdit),
	}
	reasons := make([dynamic]string)

	for file in files {
		defer {
			server.clear_index_cache()
			free_all(context.temp_allocator)
		}

		document, _, _, _, opened := open(Target{file = file, start = {1, 1}, end = {1, 1}})
		if !opened {
			append(&reasons, fmt.aprintf("cannot open %s", file))
			continue
		}
		defer server.document_close(document.uri.uri)

		result := server.modernize_document(document, selected, &common.config)
		if result.syntax_error {
			fmt.eprintfln("%s: skipped, the file does not parse", file)
		}
		if len(result.failed) > 0 {
			append(
				&reasons,
				fmt.aprintf(
					"%s: a pass of %s produced code that does not parse and was undone",
					file,
					strings.join(result.failed, ", ", context.temp_allocator),
				),
			)
		} else if result.stalled {
			fmt.eprintfln("%s: made no progress, every remaining fix spans the import insertion point", file)
		} else if !result.converged && !result.syntax_error {
			fmt.eprintfln("%s: still changing after the pass limit; run modernize again", file)
		}
		if len(result.applied) == 0 do continue

		original := string(document.text[:document.used_text])
		whole := common.Range {
			end = common.get_relative_token_position(len(original), document.text[:document.used_text], 0),
		}
		edits := make([]server.TextEdit, 1)
		edits[0] = {
			range   = whole,
			newText = strings.clone(result.text),
		}
		edit.changes[strings.clone(document.uri.uri)] = edits

		for a in result.applied {
			append(
				&entries,
				Modernize_Entry{file, a.line, a.col, strings.clone(a.rule), strings.clone(a.title), a.pass},
			)
		}
	}

	// A file that could not be read or a pass that broke the code refuses the whole run.
	if len(reasons) > 0 {
		return refuse("modernize", ..reasons[:])
	}
	if options.diff || options.apply {
		return run_edit("modernize", edit, options.apply, options.check)
	}

	exit_codes := STATUS_EXIT
	if options.json {
		print(entries[:])
	} else if len(entries) == 0 {
		fmt.println("modernize: nothing to change")
	}
	if !options.json {
		for e in entries {
			// A later pass reports positions in the text the pass before it left.
			pass := e.pass > 1 ? fmt.tprintf(" (pass %d)", e.pass) : ""
			fmt.printfln("%s:%d:%d: [%s] %s%s", e.file, e.line, e.col, e.rule, e.title, pass)
		}
	}
	return exit_codes[.Noop] if len(entries) == 0 else exit_codes[.Dry_Run]
}

// Sorted absolute .odin paths, on the heap: the caller frees the temp allocator per file.
// Directories are walked with the workspace filter; files named on the command line are kept. lint walks with it too.
modernize_files :: proc(targets: []string, root: string) -> []string {
	// The workspace walk of the server, which has the root as its only folder.
	targets := len(targets) > 0 ? targets : []string{root}
	found := make([dynamic]string, context.temp_allocator)
	filter := common.workspace_filter_make(root, &common.config, context.temp_allocator)
	for target in targets {
		if os.is_directory(target) {
			common.search_for_odin_files(target, "", server.dir_blacklist, &found, &filter)
		} else {
			append(&found, target)
		}
	}

	slice.sort(found[:])
	files := make([dynamic]string)
	for file in slice.unique(found[:]) {
		append(&files, strings.clone(file))
	}
	return files[:]
}
