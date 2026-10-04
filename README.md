# ols

Language server for Odin. This project is still in early development.

Note: This project is made to be up to date with the master branch of Odin.



## Table Of Contents

-   [Installation](#installation)
	-   [Configuration](#Configuration)
-   [Features](#features)
-   [Command line queries](#command-line-queries)
-   [Clients](#clients)
	-   [Vs Code](#vs-code)
	-   [Sublime](#sublime)
	-   [Vim](#vim)
	-   [Neovim](#neovim)
	-   [Emacs](#emacs)
	-   [Helix](#helix)
	-   [Micro](#micro)
	-   [Claude Code](#claude-code)

## Installation

```bash
cd ols

# for windows
./build.bat
# To install the odinfmt formatter
./odinfmt.bat

# for linux and macos
./build.sh
# To install the odinfmt formatter
./odinfmt.sh
```

In order for `ols` to find symbols for builtin types and procedures, the `builtin` folder in the repo needs to be located next to the `ols` binary. Alternatively you can specify the path to this folder using the `OLS_BUILTIN_FOLDER` environment variable.

### Configuration

In order for the language server to index your files, it must know about your collections.

To do that you can either configure ols via an `ols.json` file (it should be located at the root of your workspace).

Or you can provide the configuration via your editor of choice.


Example of `ols.json`:

```json
{
	"$schema": "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json",
	"collections": [
		{ "name": "custom_collection", "path": "c:/path/to/collection" }
	],
	"enable_semantic_tokens": false,
	"enable_document_symbols": true,
	"enable_hover": true,
	"enable_snippets": true,
	"profile": "default",
	"profiles": [
		{ "name": "default", "checker_path": ["src"], "defines": { "ODIN_DEBUG": "false" }},
		{ "name": "linux_profile", "os": "linux", "checker_path": ["src/main.odin"], "defines": { "ODIN_DEBUG": "false" }},
		{ "name": "mac_profile", "os": "darwin", "arch": "arm64", "defines": { "ODIN_DEBUG": "false" }},
		{ "name": "windows_profile", "os": "windows", "checker_path": ["src"], "defines": { "ODIN_DEBUG": "false" }}
	]
}
```

Options:

- `enable_format`: Turns on formatting with `odinfmt`. _(Enabled by default)_

- `enable_range_format`: Format only the declarations that the selection touches. Defaults to true.

- `enable_hover`: Enables hover feature. _(Enabled by default)_

- `enable_hover_layout`: Show the memory layout (size, alignment, field offsets and padding) of types on hover. Computed by ols from the resolved types, for the configured `profile` arch. This feature is experimental and the reported layout may not always match the compiler. _(Disabled by default)_

- `enable_document_symbols`: Turns on outline of all your global declarations in your document. _(Enabled by default)_

- `enable_fake_methods`: Turn on fake methods completion. This is currently highly experimental and requires client snippet support.

- `enable_overload_resolution`: Enable go-to-definition to resolve overloaded procedures from procedure groups based on call arguments.

- `enable_references`: Turns on finding references for a symbol. _(Enabled by default)_

- `enable_document_highlights`: Turns on highlighting of symbol references in file. _(Enabled by default)_

- `enable_document_links`: Follow links when opening documentation. This is usually done via `<ctrl+click>` and will open the documentation in a browser (or similar). _(Enabled by default)_

- `enable_completions`: Enables completion results. _(Enabled by default)_

- `enable_completion_matching`: Attempt to match types and pointers when passing arguments to procedures. _(Enabled by default)_

- `enable_unused_imports_reporting`: Turn on reporting of unused imported packages. _(Enabled by default)_

- `enable_unused_imports_on_change`: Report unused imported packages after each document change. This can slow editing in large files. _(Disabled by default)_

- `enable_inlay_hints_params`: Turn on inlay hints for (non-default) parameters.

- `enable_inlay_hints_default_params`: Turn on inlay hints for default parameters.

- `enable_inlay_hints_implicit_return`: Turn on inlay hints for implicit return values.

- `enable_inlay_hints_variable_types`: Turn on inlay hints for inferred variable types. Defaults to true.

- `enable_inlay_hints_comp_lit_fields`: Turn on inlay hints for struct field names in positional composite literals. Defaults to true.

- `enable_inlay_hints_range_types`: Turn on inlay hints for the types of range loop variables. Defaults to true.

- `enable_inlay_hints_constant_values`: Turn on inlay hints for the folded value of constant expressions. Defaults to false.

- `enable_inlay_hints_optional_result`: Adds inlay hints for unhandled optional result value. (#optional_ok and #optional_allocator_error)

- `enable_semantic_tokens`: Turns on syntax highlighting.

- `enable_snippets`: Turns on builtin snippets

- `enable_procedure_snippet`: Use snippets when completing procedures—adds parenthesis after the name. This requires client snippet support. _(Enabled by default)_

- `enable_checker_only_saved`: Turns on only calling the checker on the package being saved. _(Enabled by default)_

- `enable_checker_workspace_diagnostics`: Turns on running all workspace diagnostics using odin check. This is currently experimental and may cause problems. A better option is using the `checker_path` feature to explicity tell `ols` the projects that it should check. (experimental).

- `enable_auto_import`: Automatically import packages that aren't in your import on completion.

- `enable_auto_import_skip_hidden_paths`: Skip hidden directories when discovering packages for auto-import. _(Enabled by default)_

- `enable_comp_lit_signature_help`: Provide signature help for comp lits such as when instantiating structs. Will not display correctly on some editors such as vscode. Inside a comp literal passed to a call, the comp literal signature comes before the procedure signature. _(Enabled by default in rols)_

- `enable_comp_lit_signature_help_use_docs`: Put signature help for comp lits in the documentation. This will allow it to be rendered nicely using markdown in editors that render the label without colour on one line.

- `enable_code_action_invert_if`: Enables the code actions to invert if statements and to rewrite them as early returns. Defaults to true.

- `enable_code_action_extract_variable`: Enables the code action to extract an expression into a local variable. Defaults to true.

- `enable_code_action_inline_variable`: Enables the code action to inline a local variable into its uses. Defaults to true.

- `enable_code_action_extract_procedure`: Enables the code action to extract selected statements into a new procedure. Defaults to true.

- `enable_code_action_add_explicit_type`: Enables the code action to add the inferred type to a `:=` declaration. Defaults to true.

- `enable_code_action_ternary`: Enables the code actions converting between an if/else and a ternary expression. Defaults to true.

- `enable_code_action_unwrap`: Enables the code actions to unwrap a block, if or loop body and to remove a redundant else. Defaults to true.

- `enable_code_action_do_block`: Enables the code actions converting a one-statement block to a `do` body and back. Defaults to true.

- `enable_code_action_fill_struct`: Enables the code action filling the missing fields of a struct literal with zero values. Defaults to true.

- `enable_code_action_if_to_switch`: Enables the code action converting an if/else-if chain of equality tests to a switch. Defaults to true.

- `enable_code_action_result_handling`: Enables the code actions adding `or_return`, `or_else`, an `if` on the ok/error result, or discarding the results of a call. Defaults to true.

- `enable_code_action_generate_proc`: Enables the code action generating a stub for a called procedure that does not exist. Defaults to true.

- `enable_code_action_named_results`: Enables the code action naming the results of a procedure. Defaults to true.

- `enable_code_action_add_ok_result`: Enables the code action adding a `bool` result to a procedure, with `, _` added at each caller. Defaults to true.

- `enable_code_action_result_union`: Enables the quick fix changing the last result type of a procedure to a union of the types its `return` statements and `or_return` calls produce. With several results, it also names the unnamed ones, since `or_return` needs named results. Defaults to true.

- `enable_code_action_defer_delete`: Enables the code action adding a `defer` that frees an allocation. Defaults to true.

- `enable_code_action_extract_constant`: Enables the code action extracting a constant expression into a file-scope constant. Defaults to true.

- `enable_code_action_inline_proc`: Enables the code action inlining a procedure call. Defaults to true.

- `enable_code_action_introduce_param`: Enables the code action turning a constant expression into a parameter passed by every caller. Defaults to true.

- `enable_code_action_remove_param`: Enables the code action removing an unused parameter from a procedure and its callers. Defaults to true.

- `enable_code_action_move_decl`: Enables the code action moving a top-level declaration to another file of the package, or to a new file when the client can create files. Defaults to true.

- `enable_code_action_generate_test`: Enables the code action generating a `@(test)` stub for the procedure at the cursor in `<file>_test.odin` of the same package, created when the client can create files. Defaults to true.

- `enable_code_action_expand`: Expand an array scalar, `or_else`, `or_return` or a range loop back to the long form. Defaults to true.

- `enable_code_action_checker_fix`: Enables quick fixes for `odin check` errors: dropping an unused variable and removing a cast to the same type. Defaults to true.

- `enable_code_action_comment`: Enables the code actions adding a doc comment above the top-level declaration at the cursor, and converting the selected comments between `//` lines and a `/* */` block. Defaults to true.

- `enable_code_action_literal`: Enables the code actions on the literal at the cursor: converting a string to and from a raw string, converting an integer between hexadecimal, decimal and binary, and adding or removing digit separators. Defaults to true.

- `enable_code_action_loop_label`: Enables the code action adding a label to the loop at the cursor, so nested `break` and `continue` can target it. Defaults to true.

- `enable_code_action_merge_cases`: Enables the code actions to merge a switch case with the next one when their bodies match, and to split a multi-value case into one case per value. Defaults to true.

- `enable_code_action_split_merge_if`: Enables the code actions to split an if on `&&` and to merge nested ifs. Defaults to true.

- `enable_code_action_rewrite_expression`: Enables the code actions to flip a comparison, apply De Morgan's law and convert between compound and plain assignment. Defaults to true.

- `enable_organize_imports_on_save`: Removes unused imports and adds missing ones on save through `workspace/applyEdit`. Defaults to true.

- `struct_fields_underscore_visibility`: Controls visibility of struct fields starting with `_`:
  - `""` (default): no hiding, all fields are visible
  - `"file"`: hide fields when accessed from outside the declaring file 
  - `"package"`: hide fields when accessed from outside the declaring package

- `enable_parser_errors`: Enable real-time diagnostics from `core:odin/parser`. _(Enabled by default)_

- `enable_diagnostics`: Enable real-time diagnostics from the lsp. _(Enabled by default)_

- `odin_command`: Specify the location to your Odin executable, rather than relying on the environment path.

- `odin_root_override`: Allows you to specify a custom `ODIN_ROOT` that `ols` will use to look for `odin` core libraries when implementing custom runtimes.

- `checker_args`: Pass custom arguments to `odin check`, split on spaces. Odin rejects a repeated flag, so a flag here replaces the same flag that rols adds itself: `-no-entry-point`, `-json-errors`, a `-vet-*` flag that its `enable_checker_vet_*` key turns on, and a `-collection:NAME=` or `-define:NAME=` of the same NAME. `-custom-attribute` and `-sanitize` may repeat in Odin, so they are never dropped.

- `enable_checker_vet_shadowing`: Pass `-vet-shadowing` to `odin check` and report shadowed declarations as warnings. Defaults to true.

- `enable_hover_struct_size`: Show the byte size and alignment of a struct, and the offset and size of a struct field, on hover. Defaults to true.

- `enable_checker_vet_unused_variables`: Pass `-vet-unused-variables` to `odin check`. Report variables that are declared but never used, as warnings. Odin rejects a variable without this flag when it is the only statement of an `if`, `else` or `for` body, for example `if c { x := 1 }`; that one stays an error. Defaults to true.

- `enable_checker_vet_cast`: Pass `-vet-cast` to `odin check`. Report casts and transmutes to a type the value already has. Defaults to true.

- `enable_checker_vet_style`: Pass `-vet-style` to `odin check`. Report style violations, such as a missing trailing comma before a closing brace on its own line. Defaults to true.

- `enable_checker_vet_semicolon`: Pass `-vet-semicolon` to `odin check`. Report unneeded semicolons. Defaults to true.

- `enable_checker_vet_tabs`: Pass `-vet-tabs` to `odin check`. Report source lines that are not indented with tabs. Defaults to true.

- `enable_checker_strict_style`: Pass `-strict-style` to `odin check`. Report style violations as hard errors; subsumes `-vet-style` and `-vet-semicolon`. Defaults to false.

- `enable_workspace_gitignore`: Skip paths that git reports as ignored when walking the workspace. Does nothing outside a git repository or when `git` is not on PATH. Defaults to true. Workspace walks feed workspace symbols; references, rename, change signature, incoming calls and code lens; the CLI `find`, `refs`, `rename` and `callers` queries; and the package list for workspace diagnostics from `odin check`. Workspace symbols filter directories only and index whole packages, so a file glob such as `*_gen.odin` has no effect there. Imported packages and collections are never filtered. Rename and change signature do not edit git-ignored files either, so list ignored code that still compiles in `workspace_include`.

- `workspace_exclude`: Globs relative to each workspace root. Workspace walks skip matching files and directories, and everything below a matching directory. `*`, `?` and `[...]` match within one path segment, `**` spans any number of segments, a glob without `/` matches a name at any depth, and a leading `/` anchors a glob to the root. Defaults to empty.

- `workspace_include`: Globs relative to each workspace root, with the same syntax. Workspace walks keep matching paths even when git ignores them. `workspace_exclude` wins over `workspace_include`. Defaults to empty.

- `modernize_recipes`: Your own rewrite rules for `ols query modernize`. Each recipe becomes the rule `recipe/<name>` of family `recipe`, which is in the default set. Editors never show them. Defaults to empty. Example:

  ```json
  "modernize_recipes": [
    {"name": "sort-slice", "match": "sort.quick_sort($s)", "replace": "slice.sort($s)",
     "imports": ["core:slice"], "where": [{"var": "s", "kind": "slice"}]}
  ]
  ```

  - `name`: letters, digits, `-`, `_` and `.`; unique.
  - `match`: Odin code. `$name` is a metavariable that matches any expression; a second `$name` matches only the same text, spaces ignored. One expression matches any expression in the code. Anything else, such as several statements, matches that many consecutive statements of a block. Parentheses never matter. Other names must be the same in the code. A plain `pkg.name` means a package: it matches only code whose `pkg` part names an import, under any alias, with an import path that ends in `pkg`, and only where no local declaration shadows that import. Use `$x.name` for a field of any value. A metavariable cannot stand for a field name, as in `$x.$f` or `.$f`, and a lone name or metavariable is not a valid `match`. A `match` that uses a construct the matcher does not handle, such as a procedure literal, a `switch` or a typed declaration, is reported and skipped.
  - `replace`: Odin code with the `$name` metavariables of `match`. Each one becomes the code it matched, in parentheses when it is a compound expression used as an operand. When `match` is one expression, `replace` must be one expression too. Lines after the first take the indentation of the matched code, so a string literal in `replace` must not span lines. `$` in strings, runes and comments stays as is.
  - `imports`: import paths the replacement needs. A missing one is added. When the file imports the path under an alias, a `pkg.` qualifier of `replace` is written with the alias, and a qualifier of `match` keeps the name the code used. A fix whose package name means something else in the file is skipped.
  - `where`: `{"var": "s", "kind": "slice"}` entries. `kind` is `slice`, `dynamic_array`, `fixed_array`, `map`, `string` or `pointer`. Only a metavariable that matched a name or a selector such as `a.b` has a resolved type; any other match, such as `xs[:]` or a call, fails the constraint.

  A metavariable that matched an expression with a call, `or_return`, `or_break` or `or_continue` is rewritten only when `match` and `replace` each use it once, and only one metavariable of a match may contain one. Any other case could change how often or in which order the calls run or the control flow happens. A match is also skipped when a comment inside the matched code lies outside every metavariable that `replace` writes, because the rewrite would delete it. A recipe with a parse error, an unknown `where` kind, a `$name` in `replace` or `where` that `match` does not bind, or a repeated name is printed on stderr as `recipe <name>: <problem>; skipped`. The other rules still run. The match is syntactic apart from `where`, so check the result with `odin check`, which `--apply` does.

- `enable_lint_self_assignment`: Warn when a variable is assigned to itself. Defaults to true.

- `enable_lint_identical_branches`: Warn when the if and else branches, or both ternary branches, are identical. Defaults to true.

- `enable_lint_unreachable_code`: Mark statements after `return`, `break`, `continue`, `fallthrough`, `panic` or `unreachable` as unnecessary. Defaults to true.

- `enable_lint_simplify`: Mark code that has a shorter equivalent (array literal with identical elements, `x == true`, `if c { return true } else { return false }`, redundant parentheses, `s[0:len(s)]`, C-style counting loops, nested ifs, manual `or_else`/`or_return`/`or_break`/`or_continue` patterns) as unnecessary and offer the rewrite as a quick fix. Defaults to true.

- `enable_lint_float_equality`: Report `==` and `!=` comparisons on floats. A comparison with the literal `0`, `0.0`, `1` or `1.0` is not reported. Defaults to true.

- `enable_lint_printf`: Check `fmt` and `log` format strings: unknown verbs, argument count, argument type, and format directives passed to the non-formatting `print` procedures. Defaults to true.

- `enable_lint_ignored_result`: Warn when a call statement discards a `bool`, union or error result that is not marked `#optional_ok` or `#optional_allocator_error`. Defaults to true.

- `enable_lint_unused_parameter`: Mark procedure parameters that are never used in the body as unnecessary. A procedure that its own file uses as a value (an argument, an assignment, a composite literal element or a parameter default) is skipped, and so is a procedure literal passed to a call, stored in a composite literal, assigned, or declared with an explicit type. Defaults to true.

- `enable_lint_unused_variable`: Mark local variables and constants that are declared but never used as unnecessary. Defaults to true.

- `enable_lint_naming`: Report names that do not follow Odin conventions: snake_case procedures and variables, Ada_Case types and enum members, SCREAMING_SNAKE_CASE constants. Constants inside a procedure, declarations in `foreign` blocks and with `@(link_name)` or `@(export)`, and struct fields with a tag string are not checked. Defaults to true.

- `enable_lint_bool_logic`: Report boolean and comparison mistakes: identical operands, conditions that are always true or false, and `if` or `switch` branches that repeat an earlier one. Defaults to true.

- `enable_lint_no_op`: Report code that does nothing: arithmetic with an identity operand (`x + 0`, `x * 1`), integer division of literals that is always 0, comparing an address to `nil`, empty `if` or loop bodies, and `append` with no values. Defaults to true.

- `enable_lint_loops`: Report loop mistakes: a body that always exits on the first iteration, a condition nothing in the body changes, an empty infinite loop (`for {}`), a range that runs one past the end (`0 ..= len(x)`), and a range over a map lookup whose value is a dynamic array, map or fixed array (`for x in m[k]`), which reads through a nil slot for a missing key. Defaults to true.

- `enable_lint_dead_store`: Report a value stored in a variable that is overwritten before anything reads it, and writes to fields of a struct copy taken from an index, selector or range value. Defaults to true.

- `enable_lint_allocator`: Report a value allocated with an explicit allocator and then freed with the context allocator, and `make([dynamic]T, n)` whose elements `append` adds after. Defaults to true.

- `enable_lint_sync`: Report synchronisation mistakes: a lock released on the next line, a deferred lock, an atomic result assigned back to its own target, a lock struct passed or copied by value, and cleanup deferred before the error is checked. Defaults to true.

- `enable_lint_deprecated`: Report uses of a declaration marked with the `@(deprecated)` attribute. Defaults to true.

- `enable_lint_core_misuse`: Report misuses of core procedures: `time.sleep` with a bare integer, `strings.replace` with `n = 0` or `n = -1`, a `math` rounding procedure on a converted integer, and an invalid `regex` pattern literal. Defaults to true.

- `enable_lint_integer_range`: Report integer range mistakes: a shift by at least the operand's bit width, an unsigned value compared against a negative literal or zero, and an integer division converted to a float afterwards. Defaults to true.

- `enable_lint_recursion`: Report a procedure whose body calls itself before any branch, loop or early return. Defaults to true.

- `enable_lint_test_attribute`: Report a procedure taking `^testing.T` without an `@(test)` attribute, and an `@(test)` procedure whose signature is not `proc(t: ^testing.T)`. Defaults to true.

- `enable_lint_unused_declaration`: On save, mark private declarations that nothing in their package references as unnecessary. Defaults to true.

- `enable_lint_imports`: Report an import repeated in the same file, and an import whose package directory does not exist. Defaults to true.

- `enable_lint_invisible_characters`: Report a string literal containing a literal zero-width, bidirectional or control character. Defaults to true.

- `enable_lint_result_order`: Report a procedure whose error-like result is followed by another result, so `or_return` cannot be used. A `bool` counts as an error result only when unnamed or named `ok`. An enum with a `None` member counts as an error only when its name contains `Err` or another member name contains `err`, `fail`, `invalid` or `bad`. Defaults to true.

- `enable_lint_switch`: Report a `#partial` switch that already lists every case, and a `break` at the end of a case. Defaults to true.

- `enable_lint_call_arity`: Report a call that passes too few or too many arguments to a resolved procedure. Defaults to true.

- `enable_lint_struct_literal`: Report a struct literal that sets the same field twice or names a field the struct does not have. Defaults to true.

- `enable_lint_pure_call`: Report a call to a core package procedure, such as `strings.to_upper`, whose result is discarded. Defaults to true.

- `enable_lint_use_stdlib`: Mark hand-written loops and comparisons that a core library procedure or builtin already does (`slice.contains`, `slice.linear_search`, `strings.contains`, `strings.has_prefix`/`has_suffix`, `min`/`max`/`abs`/`clamp`, `copy`, `slice.fill`, `math.sum`) as unnecessary and offer the rewrite as a quick fix. Defaults to true.

- `enable_code_lens_references`: Show a reference count above every top-level declaration. Defaults to true.

- `enable_selection_range`: Expand the selection outwards through the syntax tree. Defaults to true.

- `checker_skip_packages`: Paths to packages that should not be checked by `odin check` when using `enable_checker_workspace_diagnostics`.

- `completion_exclude_attributes`: Filter procedures that include the provided attributes from completions. For example `@(test)`.

- `verbose`: Logs warnings instead of just errors.

- `profile`: What profile to currently use.

- `profiles`: List of different profiles that describe the environment ols is running under. This allows you to define different operating systems, architectures and defines for `ols` to use during development, easily switching between them using the `profile` configuration.

### Odinfmt configurations

Odinfmt reads configuration through `odinfmt.json`.

Example:

```json
{
	"$schema": "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/odinfmt.schema.json",
	"character_width": 80,
	"tabs": true,
	"tabs_width": 4
}
```

Options:

- `character_width`: How many characters it takes before it line breaks it.

- `spaces`: How many spaces is in one indentation.

- `newline_limit`: The limit of newlines between statements and declarations.

- `tabs`: Tabs or spaces.

- `tabs_width`: How many characters one tab represents.

- `convert_do`: Convert all do statements to brace blocks.

- `brace_style`: Style of braces. One of `_1TBS`, `Allman`, `Stroustrup`, `K_And_R`.

- `indent_cases`: Indent case statements within a switch.

- `newline_style`: Line endings to use. One of `CRLF`, `LF`.

- `sort_imports`: A boolean that defaults to true, which can be set to false to disable sorting imports.

- `inline_single_stmt_case`: When statement in the clause contains one simple statement, it will inline the case and statement in one line.

- `spaces_around_colons`: Put a space on both sides of a single colon during variable/field declaration, such as `foo : bar`

- `space_single_line_blocks`: Put spaces around braces of single-line blocks: `{return 0}` => `{ return 0 }`

- `align_struct_fields`: Align the types of struct fields so they all start at the same column.

- `align_struct_values`: Align the values of struct fields when assigning a struct value to a variable so they all start at the same column.

- `align_comments`: Align trailing line comments on consecutive lines so they all start at the same column. The alignment resets on a blank line, a line without a trailing comment, or a change in indentation. Standalone comment lines and `/* */` block comments are not aligned.

- `multiline_composite_literals`: When enabled, composite literals that were written across multiple lines are kept multiline.

- `preserve_struct_blank_lines`: Preserve blank lines between struct fields, up to `newline_limit`.

## Features

Support Language server features:

-   Completion
-   Go to definition
-   Semantic tokens
-   Document symbols
-   Rename
-   References
-   Signature help
-   Hover

## Command line queries

`ols query <command>` prints one line per result as `file:line:col: text`; `--json` prints the LSP objects instead. Positions are `file:line:col`, 1-based, columns in bytes, in both input and output. `--root DIR` sets the workspace, default: the nearest directory with an `ols.json` above the file, else the cwd.

- `def`, `refs`, `hover`, `impl` `FILE:LINE:COL`
- `callers`, `callees` `FILE:LINE:COL`: the call hierarchy of the procedure at the position, as `[{name, uri, range, fromRanges}]`
- `symbols FILE`
- `actions FILE:LINE:COL[-LINE:COL] [--apply TITLE [--no-check]]`: `--apply` picks one action by its exact title. Two actions at one position that share a title get the first line of the code they change in parentheses, such as `Merge nested if (if a {)`, and a numeric suffix like ` #2` when that does not tell them apart. Titles that occur once stay unchanged.
- `rename TARGET NEW [--apply [--no-check]]`: refused, before any edit is computed, when `NEW` is not a valid identifier, is a keyword, or a builtin name such as `len` or `int` (fields and enum members may use builtin names, which Odin allows); when `NEW` is already declared in the declaring scope (the package, the type, or the local scope; a package declaration in a `when` branch counts, and its cause says so); when a reference would resolve to another declaration named `NEW`, or a use of `NEW` would resolve to the renamed local, each with its `file:line:col`; when the declaration is in `core:`, `vendor:`, `base:` or outside the workspace folders; and on a package qualifier or an import, which `rename-package` renames. `NEW` equal to the old name exits `3`. A `warning:` line names up to 10 workspace files, then a count, that the gitignore, `workspace_exclude` or `workspace_include` filter skipped but that contain the old name as a whole word, since the rename does not change them
- `reorder-params TARGET --order 2,0,1 [--apply [--no-check]]`: position on a procedure name; `--order` lists the new parameter order by old index. Callers are updated. Refused when the procedure is used as a value or a caller names or omits arguments
- `move TARGET --to FILE.odin [--apply [--no-check]]`: position on a top-level declaration name; `--to` names a file of the same directory, created when missing. Refused for file-private declarations and those using file-private symbols
- `rename-package DIR NEW [--apply [--no-check]]`: renames the package in `DIR`, a directory or a collection path like `shared:util`, to `NEW`. It rewrites the `package` clause of every `.odin` file in `DIR`, for every platform, with `package old_test` becoming `package NEW_test`; every import path in the workspace that steps into `DIR` or a package below it, keeping its collection prefix or relative form and each `/` or `\` separator (a relative path inside `DIR` that leaves it with `..` stays as it is); the `old.x` qualifiers that resolve to the package in each importer that imports it without an alias (an aliased import, `import old "…"` included, only changes its path); and finally renames `DIR` to the sibling directory `NEW`. Odin names an unaliased import after its directory, not its `package` clause. Refused, with one `error:` line per cause, when `DIR` is not a directory of `.odin` files, is the workspace root, lies outside the workspace folders or in `core:`, `vendor:` or `base:`, or holds the root of a collection; when a file's `package` clause, ignoring `_test`, differs from the directory name; when `NEW` is not a valid identifier, is a keyword or a builtin name; when the sibling `NEW` exists; when an importer already binds `NEW`, through another import, a declaration in its package, or a local visible at a rewritten qualifier, each as `file:line:col`; and when an import resolves into `DIR`, symlinks resolved, but no segment of its path names `DIR`, such as a path through a symlink, which it cannot rewrite; a relative path from a file in `DIR` is exempt only when its segments, followed without resolving symlinks, stay in `DIR`. `NEW` equal to the current name exits `3`. `warning:` lines name the files the workspace filter skipped that mention the old import path or qualifier, up to 10 comments, foreign import paths (in `when` blocks too) and `#load`, `#load_hash`, `#load_directory` or `#config` strings that mention the old name, then a count, and each `old.x` in an unaliased importer that does not resolve, since the rename does not change them. The dry-run diff of `rename-package` is a git-style preview for reading: it is not guaranteed to work with `git apply`. The check after the write matches an existing error whose message names the old package against the same message with the new name, so such an error does not roll the rename back
- `attr add TARGET KEY[=VALUE]`, `attr remove TARGET KEY`, `attr remove --all KEY [DIR]` and `attr rename OLD NEW [DIR]`, each with `[--apply [--no-check]]`: edit `@(…)` attributes where the source writes them. A declaration is a value declaration, a foreign block, a foreign import or an import, at any depth: in `when` blocks, foreign blocks and procedure bodies too. `TARGET` names the declaration by a position in its attributes, names or type, or by a symbol path; a struct field, enum member or bit_field field is refused, since attributes go on declarations. `add` appends `KEY[=VALUE]` to the last group (`@(a)` becomes `@(a, KEY)`, and `@a` becomes `@(a, KEY)`), or inserts `@(KEY)` on its own line above a declaration without attributes, at its indentation. It is refused when `KEY` is not an identifier, when the declaration already has `KEY` in any group, and when `VALUE` does not parse as one Odin expression. `remove` drops each `KEY` element with its comma, keeping the comments of the elements that stay; an emptied group goes, with its line when the line holds nothing else; a missing `KEY` exits `3`. `remove --all` removes `KEY` from every declaration in `DIR`, a directory or a collection path, or in the workspace, which is walked with the workspace filter; `rename` renames the key and keeps its value across the same scope, and is refused at each declaration that already has `NEW`, as `file:line:col`. `DIR` in `core:`, `vendor:` or `base:`, or outside the workspace folders, is refused, and so is a `TARGET` there. A file that mentions `KEY` but does not parse is skipped with a `warning:`, as are the files below `DIR`, or in the workspace, that the workspace filter skipped and that mention it. `--all` on any other command is a usage error. The compile gate of `--apply` rolls back an attribute that `odin check` rejects, such as an unknown key
- `api PKG [NAME]`: the exported symbols of a package, one per line with the first line of the doc comment, sorted by name. `PKG` is a directory or a collection path like `core:strings`. With `NAME`, the full signature and doc comment of one symbol
- `find QUERY`: fuzzy symbol search over the workspace, as `file:line:col: kind name`
- `check [DIR]`: `odin check` errors and the lints below, without building or running. When `odin` does not start, times out, exits with an error and no output, or prints something other than its JSON error list, it prints `error: …` on stderr and exits `1`, so a check that did not run is not a clean check. When there is no package to check (the directory is in `checker_skip_packages`), odin does not start, and `check` prints the lints and exits `0`
- `lint FILE|DIR [--fail-on CODE,…]`: per-file lints, unused imports and unused private declarations, without running the compiler. `--fail-on` exits 1 when any listed code is reported, for CI gates
- `tests [DIR|FILE]`: the `@(test)` procedures, as `file:line:col: name`
- `test DIR [NAME,…]`: runs `odin test DIR` with the collections, defines and `checker_args` of `ols.json` and plain output; names select tests as `-define:ODIN_TEST_NAMES` does, `pkg.name` or `name`
- `modernize [PATH…] [--rule ID,…] [--list] [--diff] [--apply [--no-check]]`: rewrites each file with the quick fixes of the simplify, use_stdlib and lint rules, pass after pass until nothing changes (at most 8 passes). Without `PATH` it walks the workspace with the workspace filter, `.gitignore` included; a directory `PATH` is walked with the same filter. The default rules are the exact, behavior-preserving ones (families `idiom` and `migration`) and your own `recipe/<name>` rules from the `modernize_recipes` config key. The `migration` rules rewrite deprecated or removed Odin forms into the current ones with the same meaning: `base-imports` (`core:runtime`, `core:intrinsics` and `core:builtin` to `base:`), `os2-import` (`core:os/os2` to `os2 "core:os"`, skipped when the file already imports `core:os`), `field-align` (`#field_align` to `#min_field_align`), `align-parens` (`#align N`, `#min_field_align N` and `#max_field_align N` to `#align(N)` and so on), `for-blank` (`for in x` to `for _ in x`), `switch-blank` (`switch in u` to `switch _ in u`), `partial-dup` (`#partial #partial switch` to one `#partial`), `optimization-mode` (`"minimal"` to `"none"`, `"size"` and `"speed"` to `"favor_size"`, as the compiler messages name them), `proc-do-body` (`proc() do stmt` to a braced body), `strconv-itoa` and `strconv-ftoa` (deprecated `strconv.itoa(buf, i)` to `strconv.write_int(buf, i64(i), 10)` and `ftoa` to `write_float`, through any import alias), and `feature-tags` (adds `#+feature using-stmt` for a `using` statement or parameter, and `#+feature dynamic-literals` for a typed `map` or `[dynamic]` literal with elements). `file-tags` turns `//+build`, `//+private` and the other old tag comments into `#+` tags; it is a `review` rule because the compiler ignores the comment form, so the rewrite brings back the build filter and changes which files build. Rules that delete code or can change behavior (family `review`, such as `unused-variable/remove`, `use-stdlib/copy-loop`, `use-stdlib/clamp-if` and the `max`, `min` and `abs` rules, which differ on floats) run only when `--rule` names them or their family. `redundant-else` is an `idiom` rule because it fires only when the if-branch ends in `return`, `break` or `continue`, the `if` has no label, is not part of an `else if` chain, and is the last statement of a block that is not a `when` body. The else must also declare no name that an earlier statement of that block mentions. `--list` prints every rule with its family and whether it is a default. The default output is `file:line:col: [rule] title` per fix; a fix from a later pass is marked `(pass N)` and its position is in the text the previous pass left. `--diff` and `--apply` treat every changed file as one edit and behave as for `rename` below: `--diff` prints the unified diff and summary line, `--apply` writes every file or none after `odin check`, and `--json` prints the same object. All modes use the refactor exit codes below: `0` when there are fixes (listed, previewed or applied), `3` when nothing changes, `2` for an unknown rule, and `1` refused, with nothing written, when a file cannot be read or a pass was undone because its result did not parse; each cause is an `error:` line. A file still changing after 8 passes, or one whose remaining fixes all span the place where imports go, is reported on stderr without changing the exit code. A file that does not parse is skipped with a note on stderr. A rule runs only while its lint is enabled in the config; the `migration` rules have no lint and always run. Imports the fixes need are added; nothing is reformatted

`TARGET` is `FILE:LINE:COL` or a symbol path `PKG.Name` or `PKG.Name.Member`. `PKG` is a directory, relative to the cwd, or a collection path like `core:strings`: the longest prefix before a `.` that is a directory of `.odin` files, so `core:path/slashpath.join` and directories with dots work. `Member` is a struct field, an enum member or a `bit_field` field. A symbol path that is not found, is declared more than once (in `when` branches, say) or names a member of a type without members is refused, for example `ols query rename src/game.Player.hp health`.

Without `--apply`, `rename`, `reorder-params`, `move`, `rename-package` and `attr` print a dry run: a unified diff of every changed file (`--- a/PATH`, `+++ b/PATH`, paths relative to the root, a created file diffed from `/dev/null`) and a summary line such as `rename: 7 edits in 3 files`. A renamed directory gets a git-style header first (`diff --git a/OLD b/NEW`, `rename from OLD`, `rename to NEW`), and the files in it are diffed from their old path to their new one. `--apply`, there and on `actions`, writes every file or none:

1. Every new file text is computed in memory first. An invalid or overlapping edit range refuses the edit.
2. `odin check` runs on each package directory the edit touches and on each workspace package that imports one directly, found with the workspace filter. The check passes the collections, defines, `-file` or `-no-entry-point`, `-json-errors` and your `checker_args`, but none of the `enable_checker_vet_*` and `enable_checker_strict_style` flags: `-vet-style` turns a missing trailing comma into a Syntax Error that stops checking, which would blind the gate. It also passes `-max-error-count:100000`, unless `checker_args` has its own `-max-error-count`, because Odin otherwise stops at 36 errors and reports a different subset on each run. Then the files are written, and `odin check` runs again. The summary line ends with the number of packages checked, such as `rename: 7 edits in 3 files written, 4 packages checked`. Every package shares the 20-second timeout of one check, so a workspace with many importers can time out, which refuses the edit; `--no-check` skips the check. Only the current build target is checked: a file that `#+build` or a file name suffix such as `_windows.odin` or `_js.odin` excludes from this platform escapes the check.
3. A file that changed on disk between the edit's computation and the write refuses the edit.
4. An error that was not there before restores every file byte for byte and deletes the files the edit created. Errors are matched by the first line of their message, in any of the checked packages, and every `Different package name, expected …` error counts as one kind, since Odin swaps the names by parse order. For `rename` and `rename-package`, an existing error that is not matched as it is also matches with the old name replaced by the new one as a whole word, so an error that names the renamed symbol or package is not new.
5. A check that cannot run (no `odin`, a timeout, output that is not its JSON, a failing exit with no output) refuses the edit. A failed write restores the files it wrote, including the one that failed.
6. A directory rename (an LSP `RenameFile`) runs after every file is written, and the check after it runs on the new path. A directory that disappeared, or a target that appeared, since the edit was computed refuses the edit. A rollback renames the directory back first, then restores the files; a rename that fails restores every file.

When every package to check is missing or listed in `checker_skip_packages`, a `warning:` line on stderr (a `reasons` entry in JSON) says so and the edit is written without a check. When the check before the write already reports errors in a directory, a `warning:` line names it: a parse error stops `odin check` there, and so does a `-max-error-count` in `checker_args`, so the check cannot see new errors that hide behind them. `--no-check` skips both checks. With `--json` these commands print one object, `{"status", "edit", "summary", "reasons"}`, where `status` is `applied`, `dry_run`, `refused`, `noop` or `check_failed` and `edit` is the LSP `WorkspaceEdit`. In text mode each refusal cause is an `error: …` line on stderr.

Exit codes of the refactor commands: `0` applied or previewed, `1` refused with nothing written, `2` usage error, `3` nothing to change, `4` rolled back after `odin check` reported new errors. When a rollback cannot restore a file or rename a directory back, the command exits `1` with status `refused`, and each file that remains modified or directory that remains renamed gets its own `error:` line. Read-only queries keep their own codes.

## Clients

### VS Code

Install the extension https://marketplace.visualstudio.com/items?itemName=DanielGavin.ols

### Sublime

Install the package https://github.com/sublimelsp/LSP

Configuration of the LSP:

```jsonc
{
	"clients": {
		"odin": {
			"command": [
				"/path/to/ols"
			],
			"enabled": false, // true for globally-enabled, but not required due to 'Enable In Project' command
			"selector": "source.odin",
			"initializationOptions": {
				"collections": [
					{
						"name": "collection_a",
						"path": "/path/to/collection_a"
					}
				],
				"enable_semantic_tokens": true,
				"enable_document_symbols": true,
				"enable_hover": true,
				"enable_snippets": true,
				"enable_format": true,
			}
		}
	}
}
```

### Vim

Install [Coc](https://github.com/neoclide/coc.nvim).

Configuration of the LSP:

```json
{
	"languageserver": {
		"odin": {
			"command": "ols",
			"filetypes": ["odin"],
			"rootPatterns": ["ols.json"]
		}
	}
}
```

### Neovim

Neovim has a builtin support for LSP.

There is a plugin that makes the setup easier, called [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig). You can install it with your preferred package manager.

A simple configuration that uses the default `ols` settings would be like this:

```lua
require'lspconfig'.ols.setup {}
```

And here is an example of a configuration with a couple of settings applied:

```lua
require'lspconfig'.ols.setup {
	init_options = {
		checker_args = "-strict-style",
		collections = {
			{ name = "shared", path = vim.fn.expand('$HOME/odin-lib') }
		},
	},
}
```

* use an explicit `cmd` for `ols` when using a custom build

Neovim can run Odinfmt on save using the [conform](https://github.com/stevearc/conform.nvim) plugin. Here is a sample configuration using the [lazy.nvim](https://github.com/folke/lazy.nvim) package manager:

```lua
local M = {
   "stevearc/conform.nvim",
   opts = {
      notify_on_error = false,
      -- Odinfmt gets its configuration from odinfmt.json. It defaults
      -- writing to stdout but needs to be told to read from stdin.
      formatters = {
         odinfmt = {
            -- Change where to find the command if it isn't in your path.
            command = "odinfmt",
            args = { "-stdin" },
            stdin = true,
         },
      },
      -- and instruct conform to use odinfmt.
      formatters_by_ft = {
         odin = { "odinfmt" },
      },
   },
}
return M
```

#### LazyVim + Mason

If you use LazyVim with Mason, `cmd = { "ols" }` may resolve to Mason's shim instead of your custom `ols` binary. OLS already documents editor-provided configuration and `odin_command`, so when using a custom OLS build it is safer to disable Mason only for OLS and set explicit paths.

```lua
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ols = {
          mason = false,
          cmd = { "/path/to/ols" },
          settings = {
            odin_command = "/path/to/odin",
          },
        },
      },
    },
  },
}
```

Notes:

* put `ols` inside `opts.servers`
* keep Mason enabled for other language servers if you want
### Emacs

For Emacs, there are two packages available for LSP; lsp-mode and eglot.

The latter is built-in, spec-compliant and favours built-in Emacs functionality and the former offers richer UI elements and automatic installation for some of the servers.

In either case, you'll also need an associated major mode.

Pick either of the below, the former is likely to be more stable but the latter will allow you to take advantage of tree-sitter and other packages that integrate with it.

The `use-package` statements below assume you're using a package manager like Straight or Elpaca and as such should be taken as references rather than guaranteed copy/pasteable. If you're using `package.el` or another package manager then you'll have to look into instructions for that yourself.

```elisp
;; Enable odin-mode and configure OLS as the language server
(use-package odin-mode
  :ensure (:host github :repo "mattt-b/odin-mode")
  :mode ("\\.odin\\'" . odin-mode))

;; Or use the WIP tree-sitter mode
(use-package odin-ts-mode
  :ensure (:host github :repo "Sampie159/odin-ts-mode")
  :mode ("\\.odin\\'" . odin-ts-mode))
```

If you are using Emacs 29 or above you can use `package-vc-install`.

```elisp
(package-vc-install
 '(odin-mode :url "https://github.com/mattt-b/odin-mode.git"))

(package-vc-install
 '(odin-ts-mode :url "https://github.com/Sampie159/odin-ts-mode.git"))
```

And then choose either the built-in `eglot` or `lsp-mode` packages below. Both should work very similarly.

#### lsp-mode

As of lsp-mode pull request [4818](https://github.com/emacs-lsp/lsp-mode/pull/4818) ols is included as a pre-configured client. You will need to install lsp-mode from source until version 9.1 has been released. Just `M-x lsp-install-server` and select ols. This will download and install the latest version of ols from the releases. Then start lsp-mode with `M-x lsp` or add hook on the below package

```elisp
;; Pull the lsp-mode package from elpa
(use-package lsp-mode
  :commands (lsp lsp-deferred))

;; OR Pull lsp-mode from source using Straight this snippet has the install instructions for installing straight.el
(defvar straight-use-package-by-default t)
(defvar straight-recipes-repo-clone-depth 1)
(defvar straight-enable-github-repos t)
(defvar bootstrap-version)
(let ((bootstrap-file
       (expand-file-name
        "straight/repos/straight.el/bootstrap.el"
        (or (bound-and-true-p straight-base-dir)
            user-emacs-directory)))
      (bootstrap-version 7))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

;; Configure straight.el
(straight-use-package 'use-package)

(use-package lsp-mode
  :straight (lsp-mode :host github :repo "emacs-lsp/lsp-mode")
  :commands (lsp lsp-deferred))

;; Add a hook to autostart OLS
(add-hook 'odin-mode-hook #'lsp-deferred)
(add-hook 'odin-ts-mode-hook #'lsp-deferred) ;; If you're using the TS mode
```

#### eglot

```elisp
;; Add OLS to the list of available programs
;; NOTE: As of Emacs 30, this is not needed.
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '((odin-mode odin-ts-mode) . ("ols"))))

;; Add a hook to autostart OLS
(add-hook 'odin-mode-hook #'eglot-ensure)
(add-hook 'odin-ts-mode-hook #'eglot-ensure) ;; If you're using the TS mode
```

### Helix

Helix supports Odin and OLS by default. It is already enabled in the [default languages.toml](https://github.com/helix-editor/helix/blob/master/languages.toml). 

If `ols` or `odinfmt` are not on your PATH environment variable, you can enable them like this:
```toml
# Optional. The default configration requires OLS in PATH env. variable. If not,
# you can set path to the executable like so:
# [language-server.ols]
# command = "path/to/executable"
```

### Micro

Install the [LSP plugin](https://github.com/AndCake/micro-plugin-lsp)

Configure the plugin in micro's settings.json:

```json
{
	"lsp.server": "c=clangd,go=gopls,odin=ols"
}
```
### Claude Code

`misc/claude-plugin` is a Claude Code plugin: it registers `ols` as the LSP server for `.odin` files and ships the `ols` skill, which tells the agent to find code through the LSP tool, learn packages with `ols query api`, run `ols query check` after edits and apply refactorings and tests with `ols query`. Add the directory holding it as a local marketplace, or copy it to `~/.claude/local-plugins/odin-lsp` as `install.sh` does.

### Kate

First, make sure you have the LSP plugin enabled. Then, you can find LSP settings for Kate in Settings -> Configure Kate -> LSP Client -> User Server Settings.

You may have to set the folders for your Odin home path directly, like in the following example:
```jsonc
{
    "servers": {
        "odin": {
            "command": [
                "ols"
            ],
            "filetypes": [
                "odin"
            ],
            "url": "https://github.com/DanielGavin/ols",
            "root": "%{Project:NativePath}",
            "highlightingModeRegex": "^Odin$",
            "initializationOptions": {
                "collections": [
                    {
                        "name": "core",
                        "path": "/path/to/Odin/core"
                    },
                    {
                        "name": "vendor",
                        "path": "/path/to/Odin/vendor"
                    },
                    {
                        "name": "shared",
                        "path": "/path/to/Odin/shared"
                    },
                    {
                        "name": "src", // If your project has src-collection in root folder, 
                        "path": "src"  // this will add it as a collection
                    },
                    {
                        "name": "collection_a",
                        "path": "/path/to/collection_a"
                    }
                ],
                "odin_command": "path/to/Odin",
                "verbose": true,
                "enable_document_symbols": true,
                "enable_hover": true
            }
        }
    }
}
```
Kate can infer inlay hints on its own when enabled in LSP settings, so enabling it separately in the server config
can cause some weird behavior.
