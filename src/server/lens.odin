package server

// rols: imports for the reference sweep
import "base:runtime"

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:os"
import "core:slice"

import "src:common"

CodeLensClientCapabilities :: struct {
	dynamicRegistration: bool,
}

CodeLensOptions :: struct {
	resolveProvider: bool,
}

// rols: code lens request params
CodeLensParams :: struct {
	textDocument: TextDocumentIdentifier,
}

CodeLens :: struct {
	range:   common.Range,
	command: Command,
}

// rols: budget and bookkeeping for the reference sweep
// The sweep costs about 0.3 ms per workspace file that does not mention a declaration and a full
// resolve per file that does; past this many files it blocks the request thread for seconds.
@(private = "file")
MAX_LENS_FILES :: 2000

@(private = "file")
Lens_Key :: struct {
	uri:   string,
	range: common.Range,
}

@(private = "file")
Lens_Candidate :: struct {
	range:  common.Range,
	offset: int,
	count:  int,
}

// rols: textDocument/codeLens handler
request_code_lens :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	if _, ok := params.(json.Object); !ok do return .ParseError

	lens_params: CodeLensParams
	if unmarshal(params, lens_params, context.temp_allocator) != nil do return .ParseError

	document := document_get(lens_params.textDocument.uri)
	if document == nil do return .InternalError

	response := make_response_message(params = get_code_lenses(document, config), id = id)
	send_response(response, writer)

	return .None
}

// rols: reference counts as lenses
// Reference counts on the document's top-level declarations. The title carries the count and the
// command is left empty: OLS has no workspace/executeCommand, and Zed shows such a lens as plain text.
// files replaces the workspace walk, which is compiled out under ODIN_TEST.
get_code_lenses :: proc(document: ^Document, config: ^common.Config, files: []Package_File = {}) -> []CodeLens {
	if !config.enable_code_lens_references do return {}

	uri := document.uri.uri
	src := string(document.text[:document.used_text])
	candidates := make([dynamic]Lens_Candidate, context.temp_allocator)
	index := make(map[Lens_Key]int, context.temp_allocator)
	names := make(map[string]struct{}, context.temp_allocator)
	for decl in top_level_decls(document.ast) {
		for name in decl.names {
			ident := name.derived.(^ast.Ident) or_continue
			if ident.name == "_" do continue
			range := common.get_token_range(ident, src)
			index[{uri, range}] = len(candidates)
			names[ident.name] = {}
			append(&candidates, Lens_Candidate{range = range, offset = ident.pos.offset})
		}
	}
	if len(candidates) == 0 do return {}

	sources := workspace_odin_files(document.fullpath, files)
	if len(sources) > MAX_LENS_FILES {
		log.infof("code lens skipped: %d workspace files", len(sources))
		return {}
	}

	arena: runtime.Arena
	_ = runtime.arena_init(&arena, mem.Megabyte * 8, runtime.default_allocator())
	defer runtime.arena_destroy(&arena)

	tally :: proc(source: ^Document, index: map[Lens_Key]int, candidates: []Lens_Candidate) {
		for _, hit in resolve_entire_file_for_references(source, context.allocator, .Identifier, "") {
			i := index[{hit.symbol.uri, hit.symbol.range}] or_continue
			if hit.symbol.uri == source.uri.uri && hit.node.pos.offset == candidates[i].offset do continue
			candidates[i].count += 1
		}
	}

	context.allocator = runtime.arena_allocator(&arena)
	tally(document, index, candidates[:])
	runtime.arena_free_all(&arena)

	for source in sources {
		context.allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_free_all(&arena)

		text := source.text
		if open := &document_storage.documents[source.fullpath]; open != nil && open.client_owned {
			text = string(open.text[:open.used_text])
		} else if text == "" {
			data, err := os.read_entire_file(source.fullpath, context.allocator)
			if err != nil do continue
			text = string(data)
		}
		if !mentions_any(text, names) do continue

		parsed := parse_package_file({source.fullpath, text}, config) or_continue
		in_pkg := parsed.package_name == document.package_name
		for imp in parsed.imports do in_pkg ||= imp.name == document.package_name
		if !in_pkg do continue

		tally(&parsed, index, candidates[:])
	}

	lenses := make([]CodeLens, len(candidates), context.temp_allocator)
	for candidate, i in candidates {
		title: string
		switch candidate.count {
		case 0:
			title = "no references"
		case 1:
			title = "1 reference"
		case:
			title = fmt.tprintf("%d references", candidate.count)
		}
		lenses[i] = {range = candidate.range, command = {title = title}}
	}
	slice.sort_by(lenses, proc(a, b: CodeLens) -> bool {
		return a.range.start.line < b.range.start.line ||
			(a.range.start.line == b.range.start.line && a.range.start.character < b.range.start.character)
	})
	return lenses
}

// rols: cheap prefilter before parsing a file
// Whether text contains one of names as a whole identifier.
@(private = "file")
mentions_any :: proc(text: string, names: map[string]struct{}) -> bool {
	is_ident_byte :: proc(c: u8) -> bool {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
			return true
		}
		return c >= 0x80
	}

	i := 0
	for i < len(text) {
		if !is_ident_byte(text[i]) {
			i += 1
			continue
		}
		start := i
		for i < len(text) && is_ident_byte(text[i]) do i += 1
		if text[start:i] in names do return true
	}
	return false
}
