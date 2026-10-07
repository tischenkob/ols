package server

import "base:runtime"

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// The `-target:` values the compile gate tries for a file the base target does not build, in order. One
// default architecture per OS comes first, then the architectures a file name or tag can ask for.
GATE_TARGET_CANDIDATES :: [?]string {
	"windows_amd64",
	"linux_amd64",
	"darwin_arm64",
	"freebsd_amd64",
	"openbsd_amd64",
	"netbsd_amd64",
	"js_wasm32",
	"wasi_wasm32",
	"orca_wasm32",
	"freestanding_wasm32",
	"freestanding_amd64_sysv",
	"linux_arm64",
	"linux_i386",
	"linux_riscv64",
	"windows_i386",
	"darwin_amd64",
	"freestanding_arm64",
	"freestanding_riscv64",
	"freestanding_amd64_win64",
}

// The longest wall-clock budget of one gate run, so a workspace-wide edit cannot block for hours.
GATE_TIMEOUT_CAP :: 10 * time.Minute

// The wall-clock budget of one gate run over packages package directories. `check` runs one process per
// core at a time, so the run gets the 20 s of an editor check for each batch of cores packages, up to
// GATE_TIMEOUT_CAP.
gate_check_timeout :: proc(packages, cores: int) -> time.Duration {
	batches := (max(packages, 1) + max(cores, 1) - 1) / max(cores, 1)
	return min(CHECK_TIMEOUT * time.Duration(batches), GATE_TIMEOUT_CAP)
}

// The `-target:` value for entry, a candidate such as `windows_amd64` or a bare OS name such as
// `windows`, which takes the first candidate of that OS. Other names are not real odin targets, or are
// not ones the gate has verified, such as `darwin_wasm32`.
target_name :: proc(entry: string) -> (name: string, ok: bool) {
	prefix := entry if strings.contains(entry, "_") else strings.concatenate({entry, "_"}, context.temp_allocator)
	exact := prefix == entry
	for candidate in GATE_TARGET_CANDIDATES {
		if candidate == entry || (!exact && strings.has_prefix(candidate, prefix)) {
			return candidate, true
		}
	}
	return "", false
}

// The OS and architecture of an odin `-target:` value such as `windows_amd64` or `freestanding_amd64_sysv`.
parse_target :: proc(name: string) -> (target: parser.Build_Target, ok: bool) {
	parts := strings.split(name, "_", context.temp_allocator)
	if len(parts) < 2 {
		return {}, false
	}
	target.os, _ = parser.get_build_os_from_string(parts[0])
	target.arch = parser.get_build_arch_from_string(parts[1])
	return target, target.os != .Unknown && target.arch != .Unknown
}

// The target `odin check` builds for: the `-target:` of checker_args, else the host.
base_target :: proc(checker_args: string) -> parser.Build_Target {
	target := parser.Build_Target {
		os   = ODIN_OS,
		arch = ODIN_ARCH,
	}
	for word in split_checker_args(checker_args) {
		if named, ok := parse_target(strings.trim_prefix(word, "-target:"));
		   ok && strings.has_prefix(word, "-target:") {
			target = named
		}
	}
	return target
}

// What the gate needs for a file.
Target_Need :: enum {
	None, // the current target builds it, or `#+build ignore` builds it nowhere
	Other, // another target builds it
	Nowhere, // no target of the candidates builds it
}

// The facts of a file that decide where it builds: the target of its name and its tags, parsed once.
@(private = "file")
Build_Facts :: struct {
	named:  parser.Build_Target,
	hidden: bool,
	tags:   parser.File_Tags,
}

// The facts of the file called name with tags.
@(private = "file")
facts_of :: proc(name: string, tags: parser.File_Tags) -> (facts: Build_Facts) {
	facts.tags = tags
	facts.named, facts.hidden = file_name_target(filepath.base(name))
	return
}

@(private = "file")
build_facts :: proc(name, text: string) -> Build_Facts {
	if !strings.contains(text, "+build") && !strings.contains(text, "+ignore") {
		return facts_of(name, {})
	}
	file := ast.File {
		src      = text,
		fullpath = name,
	}
	p := parser.Parser {
		flags = {.Optional_Semicolons},
	}
	context.allocator = context.temp_allocator
	parser.parse_file(&p, &file)
	return facts_of(name, build_tags(file))
}

// The tags of file as the compiler reads them. Each `#+build-project-name` line must hold for the file to build
// (parse_build_project_directory_tag in odin's src/parser.cpp excludes the file on the first false line), while
// parser.match_build_tags passes when any group of any line holds. Here the build_project_name groups become the
// cross product of the lines, so that match_build_tags reads them as the compiler does: `#+build-project-name a, b`
// and `#+build-project-name !b` give the groups `a !b` and `b !b`.
build_tags :: proc(file: ast.File) -> parser.File_Tags {
	tags := parser.parse_file_tags(file, context.temp_allocator)
	if len(tags.build_project_name) == 0 {
		return tags
	}
	// The texts parse_file_tags reads, as `#+` tags. Its parse_tag skips spaces and tabs before the `+` of a
	// `//` comment, so `// +build-project-name a` counts too.
	lines := make([dynamic]string, context.temp_allocator)
	if file.docs != nil {
		for comment in file.docs.list {
			if len(comment.text) < 3 || comment.text[:2] != "//" do continue
			text := strings.trim_left(comment.text[2:], " \t")
			if strings.has_prefix(text, "+build-project-name") {
				append(&lines, strings.concatenate({"#", text}, context.temp_allocator))
			}
		}
	}
	for tag in file.tags {
		if strings.has_prefix(tag.text, "#+build-project-name") do append(&lines, tag.text)
	}
	if len(lines) == 0 {
		return tags
	}
	product := make([][]string, 1, context.temp_allocator)
	for line in lines {
		one := ast.File {
			tags = make([dynamic]tokenizer.Token, 1, context.temp_allocator),
		}
		one.tags[0].text = line
		groups := parser.parse_file_tags(one, context.temp_allocator).build_project_name
		next := make([dynamic][]string, context.temp_allocator)
		for done in product {
			for group in groups {
				append(&next, slice.concatenate([][]string{done, group}, context.temp_allocator))
			}
		}
		product = next[:]
	}
	tags.build_project_name = product
	return tags
}

// Whether odin builds the file with these facts for target: its name suffix and its `#+build` tags both
// allow it. A `#+build ignore` file is built nowhere. An empty target.project_name matches every
// `#+build-project-name` tag.
@(private = "file")
facts_build_on :: proc(facts: Build_Facts, target: parser.Build_Target) -> bool {
	named := facts.named
	if facts.hidden ||
	   (named.os != .Unknown && named.os != target.os) ||
	   (named.arch != .Unknown && named.arch != target.arch) {
		return false
	}
	return !facts.tags.ignore && parser.match_build_tags(facts.tags, target)
}

// Whether the files called name_a and name_b, with tags_a and tags_b, build on the same OS, architecture and
// project name triples. Two spellings of one constraint, such as `#+build linux` and a `_linux.odin` name, or
// `#+build-project-name a, b` and `#+build-project-name b, a`, agree.
same_build_targets :: proc(
	name_a: string,
	tags_a: parser.File_Tags,
	name_b: string,
	tags_b: parser.File_Tags,
) -> bool {
	a, b := facts_of(name_a, tags_a), facts_of(name_b, tags_b)
	for target in candidate_targets(a, b) {
		if facts_build_on(a, target) != facts_build_on(b, target) do return false
	}
	return true
}

// Whether some OS, architecture and project name builds both the file called name_a with tags_a and the file
// called name_b with tags_b, and can take both the `when` branch of at_a and that of at_b. The tags come from
// build_tags.
builds_together :: proc(
	name_a: string,
	tags_a: parser.File_Tags,
	name_b: string,
	tags_b: parser.File_Tags,
	at_a: When_Site = {},
	at_b: When_Site = {},
) -> bool {
	a, b := facts_of(name_a, tags_a), facts_of(name_b, tags_b)
	for target in candidate_targets(a, b) {
		if facts_build_on(a, target) &&
		   facts_build_on(b, target) &&
		   site_possible_on(at_a, target) &&
		   site_possible_on(at_b, target) {
			return true
		}
	}
	return false
}

// Every OS and architecture pair with each of project_names(a, b).
@(private = "file")
candidate_targets :: proc(a, b: Build_Facts) -> []parser.Build_Target {
	targets := make([dynamic]parser.Build_Target, context.temp_allocator)
	for project in project_names(a, b) {
		for os in runtime.Odin_OS_Type {
			if os == .Unknown do continue
			for arch in runtime.Odin_Arch_Type {
				if arch != .Unknown do append(&targets, parser.Build_Target{os, arch, project})
			}
		}
	}
	return targets[:]
}

// A project name that no `#+build-project-name` tag can list, since a tag name never holds a space.
@(private = "file")
UNLISTED_PROJECT :: " "

// The project names that can tell where a and b build apart: each name their `#+build-project-name` tags
// list, with or without `!`, and UNLISTED_PROJECT for every other name. A build always has a project name,
// the name of its output, so the empty name, which matches every tag, is not one of them.
@(private = "file")
project_names :: proc(a, b: Build_Facts) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	append(&names, UNLISTED_PROJECT)
	for facts in ([2]Build_Facts{a, b}) {
		for group in facts.tags.build_project_name {
			for name in group do append(&names, strings.trim_prefix(name, "!"))
		}
	}
	return names[:]
}

// A position in a parsed file, whose enclosing `when` branches decide whether a target builds it. A nil file
// stands for no position: every target can take it.
When_Site :: struct {
	file:   ^ast.File,
	offset: int,
}

@(private = "file")
site_possible_on :: proc(site: When_Site, target: parser.Build_Target) -> bool {
	return site.file == nil || branch_possible_on(site.file^, site.offset, target)
}

// Whether target can take every `when` branch around offset in file: no condition on the way is known to rule
// it out. Only comparisons of ODIN_OS or ODIN_ARCH with an implicit selector such as `.Linux`, the literals
// true and false, `!`, `&&`, `||` and parentheses are known. Any other condition can go either way.
branch_possible_on :: proc(file: ast.File, offset: int, target: parser.Build_Target) -> bool {
	for stmt in file.decls {
		if !stmt_possible_on(stmt, offset, target) do return false
	}
	return true
}

// The first of GATE_TARGET_CANDIDATES that builds file and can take every `when` branch around offset, when base
// cannot take one of them. A candidate of base's OS comes first, so an ODIN_ARCH branch keeps the OS. ok is false
// when base can take them all or no candidate can. A branch whose condition branch_possible_on cannot read, such
// as `when FLAG`, is possible on base, so it has no target here.
branch_target :: proc(
	file: ast.File,
	offset: int,
	base: parser.Build_Target,
) -> (
	target: parser.Build_Target,
	ok: bool,
) {
	if branch_possible_on(file, offset, base) do return {}, false
	facts := facts_of(file.fullpath, build_tags(file))
	for same_os in ([2]bool{true, false}) {
		for candidate in GATE_TARGET_CANDIDATES {
			parsed, _ := parse_target(candidate)
			if (parsed.os == base.os) != same_os do continue
			if facts_build_on(facts, parsed) && branch_possible_on(file, offset, parsed) do return parsed, true
		}
	}
	return {}, false
}

@(private = "file")
stmt_possible_on :: proc(stmt: ^ast.Stmt, offset: int, target: parser.Build_Target) -> bool {
	if stmt == nil || offset < stmt.pos.offset || offset >= stmt.end.offset do return true
	#partial switch s in stmt.derived {
	case ^ast.When_Stmt:
		value := condition_on(s.cond, target)
		if s.body != nil && s.body.pos.offset <= offset && offset < s.body.end.offset {
			return value != .False && stmt_possible_on(s.body, offset, target)
		}
		if s.else_stmt != nil && s.else_stmt.pos.offset <= offset && offset < s.else_stmt.end.offset {
			return value != .True && stmt_possible_on(s.else_stmt, offset, target)
		}
	case ^ast.Block_Stmt:
		for inner in s.stmts {
			if !stmt_possible_on(inner, offset, target) do return false
		}
	case ^ast.Foreign_Block_Decl:
		return stmt_possible_on(s.body, offset, target)
	case ^ast.Value_Decl:
		// A `when` among the statements and plain blocks of a procedure body. One in an `if`, `for` or `switch` is not.
		for value in s.values {
			if lit, ok := value.derived.(^ast.Proc_Lit); ok && !stmt_possible_on(lit.body, offset, target) do return false
		}
	}
	return true
}

@(private = "file")
Condition :: enum {
	Unknown,
	False,
	True,
}

// The value of a `when` condition on target, as far as branch_possible_on knows it.
@(private = "file")
condition_on :: proc(expr: ^ast.Expr, target: parser.Build_Target) -> Condition {
	if expr == nil do return .Unknown
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		return condition_on(e.expr, target)
	case ^ast.Ident:
		switch e.name {
		case "true":
			return .True
		case "false":
			return .False
		}
	case ^ast.Unary_Expr:
		if e.op.kind == .Not {
			negated := [Condition]Condition {
				.Unknown = .Unknown,
				.False   = .True,
				.True    = .False,
			}
			return negated[condition_on(e.expr, target)]
		}
	case ^ast.Binary_Expr:
		#partial switch e.op.kind {
		case .Cmp_And:
			left, right := condition_on(e.left, target), condition_on(e.right, target)
			if left == .False || right == .False do return .False
			if left == .True && right == .True do return .True
		case .Cmp_Or:
			left, right := condition_on(e.left, target), condition_on(e.right, target)
			if left == .True || right == .True do return .True
			if left == .False && right == .False do return .False
		case .Cmp_Eq, .Not_Eq:
			equal, known := target_comparison(e.left, e.right, target)
			if !known {
				equal, known = target_comparison(e.right, e.left, target)
			}
			if known {
				return .True if equal == (e.op.kind == .Cmp_Eq) else .False
			}
		}
	}
	return .Unknown
}

// Whether the target's OS or architecture, named by the identifier constant, equals the implicit selector value.
@(private = "file")
target_comparison :: proc(constant, value: ^ast.Expr, target: parser.Build_Target) -> (equal, known: bool) {
	ident := constant.derived.(^ast.Ident) or_return
	selector := value.derived.(^ast.Implicit_Selector_Expr) or_return
	name := selector.field.name
	switch ident.name {
	case "ODIN_OS":
		os, _ := parser.get_build_os_from_string(name)
		return os == target.os, os != .Unknown
	case "ODIN_ARCH":
		arch := parser.get_build_arch_from_string(name)
		return arch == target.arch, arch != .Unknown
	}
	return false, false
}

// Whether odin builds the file called name with the source text for target.
builds_on :: proc(name, text: string, target: parser.Build_Target) -> bool {
	return facts_build_on(build_facts(name, text), target)
}

// The operating systems where a package that imports core:testing does not compile (odin dev-2026-09).
NO_TESTING_OSES :: bit_set[runtime.Odin_OS_Type]{.JS, .WASI, .Orca, .Freestanding}

// The operating systems that odin builds the file called name with tags for, on some architecture.
tags_oses :: proc(name: string, tags: parser.File_Tags) -> bit_set[runtime.Odin_OS_Type] {
	return facts_oses(facts_of(name, tags))
}

@(private = "file")
facts_oses :: proc(facts: Build_Facts) -> (oses: bit_set[runtime.Odin_OS_Type]) {
	for os in runtime.Odin_OS_Type {
		if os == .Unknown do continue
		for arch in runtime.Odin_Arch_Type {
			if arch != .Unknown && facts_build_on(facts, {os = os, arch = arch}) {
				oses += {os}
				break
			}
		}
	}
	return
}

// Whether odin builds the file with the source text for target when the command line names it with -file: only
// its `#+build` tags count, not its name.
tags_build_on :: proc(name, text: string, target: parser.Build_Target) -> bool {
	facts := build_facts(name, text)
	facts.named, facts.hidden = {}, false
	return facts_build_on(facts, target)
}

// The `-target:` value to check the file called name with the source text on, when base does not build
// it: the first candidate that does, as Other. Nowhere when none does and the file is not `#+build ignore`.
target_for_file :: proc(name, text: string, base: parser.Build_Target) -> (target: string, need: Target_Need) {
	return facts_target(build_facts(name, text), base)
}

// target_for_file for a parsed file, without parsing its text again.
parsed_target_for_file :: proc(file: ast.File, base: parser.Build_Target) -> (target: string, need: Target_Need) {
	return facts_target(facts_of(file.fullpath, build_tags(file)), base)
}

@(private = "file")
facts_target :: proc(facts: Build_Facts, base: parser.Build_Target) -> (target: string, need: Target_Need) {
	if facts_build_on(facts, base) || facts.tags.ignore {
		return "", .None
	}
	for candidate in GATE_TARGET_CANDIDATES {
		parsed, _ := parse_target(candidate)
		if facts_build_on(facts, parsed) {
			return candidate, .Other
		}
	}
	return "", .Nowhere
}

// For each of targets, whether it builds the file called name with the source text and can take a `when` branch
// of it that base does not take. Only a condition that names ODIN_OS or ODIN_ARCH counts. It differs when
// condition_on reads it differently on the target and on base, or cannot read it, at a place that
// branch_possible_on allows on the target. A constant that holds such a condition, as in `when IS_WASM`, does
// not count. The text is parsed once for every target.
other_branch_targets :: proc(name, text: string, base: parser.Build_Target, targets: []parser.Build_Target) -> []bool {
	Data :: struct {
		file:    ^ast.File,
		base:    parser.Build_Target,
		targets: []parser.Build_Target,
		takes:   []bool,
		// A target that does not build the file takes none of its branches.
		skip:    []bool,
		left:    int,
	}
	data := Data {
		base    = base,
		targets = targets,
		takes   = make([]bool, len(targets), context.temp_allocator),
		skip    = make([]bool, len(targets), context.temp_allocator),
	}
	if !strings.contains(text, "ODIN_OS") && !strings.contains(text, "ODIN_ARCH") do return data.takes
	facts := build_facts(name, text)
	for target, i in targets {
		data.skip[i] = !facts_build_on(facts, target)
		if !data.skip[i] do data.left += 1
	}
	if data.left == 0 do return data.takes
	file := ast.File {
		src      = text,
		fullpath = name,
	}
	p := parser.Parser {
		flags = {.Optional_Semicolons},
	}
	context.allocator = context.temp_allocator
	parser.parse_file(&p, &file)
	data.file = &file
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.left == 0 do return nil
			s, ok := node.derived.(^ast.When_Stmt)
			if !ok || s.cond == nil do return visitor
			cond := data.file.src[s.cond.pos.offset:s.cond.end.offset]
			if !strings.contains(cond, "ODIN_OS") && !strings.contains(cond, "ODIN_ARCH") do return visitor
			on_base := condition_on(s.cond, data.base)
			for target, i in data.targets {
				if data.skip[i] || data.takes[i] do continue
				on_target := condition_on(s.cond, target)
				if (on_target == .Unknown || on_target != on_base) &&
				   branch_possible_on(data.file^, s.pos.offset, target) {
					data.takes[i] = true
					data.left -= 1
				}
			}
			return visitor
		},
	}
	for decl in file.decls {
		ast.walk(&visitor, decl)
	}
	return data.takes
}
