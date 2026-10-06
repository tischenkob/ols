package server

import "base:runtime"

import "core:odin/ast"
import "core:odin/parser"
import "core:path/filepath"
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

@(private = "file")
build_facts :: proc(name, text: string) -> (facts: Build_Facts) {
	facts.named, facts.hidden = file_name_target(filepath.base(name))
	if !strings.contains(text, "+build") && !strings.contains(text, "+ignore") {
		return
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
	facts.tags = parser.parse_file_tags(file, context.temp_allocator)
	return
}

// Whether odin builds the file with these facts for target: its name suffix and its `#+build` tags both
// allow it. A `#+build ignore` file is built nowhere.
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

// Whether the files called name_a and name_b, with tags_a and tags_b, build on the same OS and architecture
// pairs. Two spellings of one constraint, such as `#+build linux` and a `_linux.odin` name, agree.
same_build_targets :: proc(
	name_a: string,
	tags_a: parser.File_Tags,
	name_b: string,
	tags_b: parser.File_Tags,
) -> bool {
	a := Build_Facts {
		tags = tags_a,
	}
	b := Build_Facts {
		tags = tags_b,
	}
	a.named, a.hidden = file_name_target(filepath.base(name_a))
	b.named, b.hidden = file_name_target(filepath.base(name_b))
	for os in runtime.Odin_OS_Type {
		if os == .Unknown do continue
		for arch in runtime.Odin_Arch_Type {
			if arch == .Unknown do continue
			target := parser.Build_Target {
				os   = os,
				arch = arch,
			}
			if facts_build_on(a, target) != facts_build_on(b, target) do return false
		}
	}
	return true
}

// Whether some OS and architecture pair builds both the file called name_a with text_a and the file called
// name_b with text_b.
builds_together :: proc(name_a, text_a, name_b, text_b: string) -> bool {
	a, b := build_facts(name_a, text_a), build_facts(name_b, text_b)
	for os in runtime.Odin_OS_Type {
		if os == .Unknown do continue
		for arch in runtime.Odin_Arch_Type {
			if arch == .Unknown do continue
			target := parser.Build_Target {
				os   = os,
				arch = arch,
			}
			if facts_build_on(a, target) && facts_build_on(b, target) do return true
		}
	}
	return false
}

// Whether odin builds the file called name with the source text for target.
builds_on :: proc(name, text: string, target: parser.Build_Target) -> bool {
	return facts_build_on(build_facts(name, text), target)
}

// The operating systems where a package that imports core:testing does not compile (odin dev-2026-09).
NO_TESTING_OSES :: bit_set[runtime.Odin_OS_Type]{.JS, .WASI, .Orca, .Freestanding}

// The operating systems that odin builds the file called name with the source text for, on some architecture.
build_oses :: proc(name, text: string) -> bit_set[runtime.Odin_OS_Type] {
	return facts_oses(build_facts(name, text))
}

// build_oses for a file whose tags are already parsed.
tags_oses :: proc(name: string, tags: parser.File_Tags) -> bit_set[runtime.Odin_OS_Type] {
	facts := Build_Facts {
		tags = tags,
	}
	facts.named, facts.hidden = file_name_target(filepath.base(name))
	return facts_oses(facts)
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
	facts := build_facts(name, text)
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
