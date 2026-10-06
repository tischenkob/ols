package odin_printer

import "core:fmt"
import "core:strings"

Document :: union {
	Document_Nil,
	Document_Newline,
	Document_Text,
	Document_Nest,
	Document_Break,
	Document_Group,
	Document_Cons,
	Document_If_Break_Or,
	Document_Align,
	Document_Break_Parent,
	Document_Line_Suffix,
}

Document_Nil :: struct {}

Document_Newline :: struct {
	amount: int,
}

Document_Text :: struct {
	value: string,
}

Document_Line_Suffix :: struct {
	value:     string,
	alignable: bool, //Trailing comments can be aligned; standalone comments cannot.
}

Document_Nest :: struct {
	alignment: int, //Is only used when hanging a document
	negate:    bool,
	document:  ^Document,
}

Document_Break :: struct {
	value:   string,
	newline: bool,
}

Document_If_Break_Or :: struct {
	break_document: ^Document,
	fit_document:   ^Document,
	group_id:       string,
}

Document_Group :: struct {
	document: ^Document,
	mode:     Document_Group_Mode,
	options:  Document_Group_Options,
}

Document_Cons :: struct {
	elements: []^Document,
}

Document_Align :: struct {
	document: ^Document,
}

Document_Group_Mode :: enum {
	Flat,
	Break,
	Fit,
	Fill,
}

Document_Group_Options :: struct {
	// rols: `measure` marks a group that is measured even in a flat region, where only the first group after a newline is
	id:        string,
	measure:   bool,
	// rols: `rest_flat` marks a group that a fit check measures flat when it comes from the rest, and that format passes through
	rest_flat: bool,
}

Document_Break_Parent :: struct {}

empty :: proc(allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Nil{}
	return document
}

text :: proc(value: string, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Text {
		value = value,
	}
	return document
}

newline :: proc(amount: int, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Newline {
		amount = amount,
	}
	return document
}

nest :: proc(nested_document: ^Document, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Nest {
		document = nested_document,
	}
	return document
}

escape_nest :: proc(nested_document: ^Document, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Nest {
		document = nested_document,
		negate   = true,
	}
	return document
}

nest_if_break :: proc(nested_document: ^Document, group_id := "", allocator := context.allocator) -> ^Document {
	return if_break_or_document(nest(nested_document, allocator), nested_document, group_id, allocator)
}

hang :: proc(align: int, hanged_document: ^Document, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Nest {
		alignment = align,
		document  = hanged_document,
	}
	return document
}

enforce_fit :: proc(fitted_document: ^Document, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Group {
		document = fitted_document,
		mode     = .Fit,
	}
	return document
}

fill :: proc(filled_document: ^Document, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Group {
		document = filled_document,
		mode     = .Fill,
	}
	return document
}

enforce_break :: proc(
	fitted_document: ^Document,
	options := Document_Group_Options{},
	allocator := context.allocator,
) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Group {
		document = fitted_document,
		mode     = .Break,
		options  = options,
	}
	return document
}

align :: proc(aligned_document: ^Document, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Align {
		document = aligned_document,
	}
	return document
}

if_break :: proc(value: string, allocator := context.allocator) -> ^Document {
	return if_break_or_document(text(value, allocator), nil, "", allocator)
}

if_break_or :: proc {
	if_break_or_string,
	if_break_or_document,
}

if_break_or_string :: proc(
	break_value: string,
	fit_value: string,
	group_id := "",
	allocator := context.allocator,
) -> ^Document {
	return if_break_or_document(text(break_value, allocator), text(fit_value, allocator), group_id, allocator)
}

if_break_or_document :: proc(
	break_document: ^Document,
	fit_document: ^Document,
	group_id := "",
	allocator := context.allocator,
) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_If_Break_Or {
		break_document = break_document,
		fit_document   = fit_document,
		group_id       = group_id,
	}
	return document
}

break_with :: proc(value: string, newline := true, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Break {
		value   = value,
		newline = newline,
	}
	return document
}

break_parent :: proc(allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Break_Parent{}
	return document
}

line_suffix :: proc(value: string, alignable := false, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Line_Suffix {
		value     = value,
		alignable = alignable,
	}
	return document
}

break_with_space :: proc(allocator := context.allocator) -> ^Document {
	return break_with(" ", true, allocator)
}

break_with_no_newline :: proc(allocator := context.allocator) -> ^Document {
	return break_with(" ", false, allocator)
}

group :: proc(
	grouped_document: ^Document,
	options := Document_Group_Options{},
	allocator := context.allocator,
) -> ^Document {
	document := new(Document, allocator)
	document^ = Document_Group {
		document = grouped_document,
		options  = options,
	}
	return document
}

cons :: proc(elems: ..^Document, allocator := context.allocator) -> ^Document {
	document := new(Document, allocator)
	elements := make([dynamic]^Document, 0, len(elems), allocator)

	for elem in elems {
		append(&elements, elem)
	}

	c := Document_Cons {
		elements = elements[:],
	}
	document^ = c
	return document
}

cons_with_opl :: proc(lhs: ^Document, rhs: ^Document, allocator := context.allocator) -> ^Document {
	if _, ok := lhs.(Document_Nil); ok {
		return rhs
	}

	if _, ok := rhs.(Document_Nil); ok {
		return lhs
	}

	return cons(elems = {lhs, break_with_space(allocator), rhs}, allocator = allocator)
}

cons_with_nopl :: proc(lhs: ^Document, rhs: ^Document, allocator := context.allocator) -> ^Document {
	if _, ok := lhs.(Document_Nil); ok {
		return rhs
	}

	if _, ok := rhs.(Document_Nil); ok {
		return lhs
	}

	return cons(elems = {lhs, break_with_no_newline(allocator), rhs}, allocator = allocator)
}

Tuple :: struct {
	indentation: int,
	alignment:   int,
	mode:        Document_Group_Mode,
	document:    ^Document,
}

list_fits: [dynamic]Tuple

// rols: `rest` is the caller's pending stack, read from its top without a copy, so a fit check costs its width
fits :: proc(width: int, list: ^[dynamic]Tuple, rest: []Tuple) -> bool {
	assert(list != nil)

	rest_index := len(rest)

	start_width := width
	width := width

	if len(list) == 0 && rest_index == 0 {
		return true
	} else if width <= 0 {
		return false
	}

	// rols: the measured content comes first, so once `list` runs dry every later item belongs to the rest
	in_rest := false

	for len(list) != 0 || rest_index > 0 {
		data: Tuple
		if len(list) != 0 {
			data = pop(list)
		} else {
			rest_index -= 1
			data = rest[rest_index]
			// rols: from here on, every item comes from the rest
			in_rest = true
		}

		if width <= 0 {
			return false
		}

		switch v in data.document {
		case Document_Nil:
		case Document_Line_Suffix:
		case Document_Break_Parent:
			return false
		case Document_Newline:
			if v.amount > 0 {
				return true
			}
		case Document_Cons:
			for i := len(v.elements) - 1; i >= 0; i -= 1 {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.elements[i],
						alignment = data.alignment,
					},
				)
			}
		case Document_Align:
			append(
				list,
				Tuple{indentation = 0, mode = data.mode, document = v.document, alignment = start_width - width},
			)

		case Document_Nest:
			if v.alignment != 0 {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.document,
						alignment = data.alignment + v.alignment,
					},
				)

			} else {
				append(
					list,
					Tuple {
						indentation = data.indentation + (v.negate ? -1 : 1),
						mode = data.mode,
						document = v.document,
						alignment = data.alignment + v.alignment,
					},
				)
			}
		case Document_Text:
			width -= len(v.value)
		case Document_Break:
			if data.mode == .Break && v.newline {
				return true
			} else {
				width -= len(v.value)
			}
		case Document_If_Break_Or:
			if data.mode == .Break {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.break_document,
						alignment = data.alignment,
					},
				)
			} else if v.fit_document != nil {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.fit_document,
						alignment = data.alignment,
					},
				)
			}
		case Document_Group:
			// rols: a later `measure` group in a flat region decides its own mode, so its first break may end the measured line
			parent_mode := in_rest && v.options.measure && data.mode == .Flat ? Document_Group_Mode.Break : data.mode
			// rols: a `rest_flat` group in the rest is measured flat, so a statement after a `; ` counts in full.
			// Fit counts its breaks as spaces like Flat, but a `measure` group inside it stays Fit, so the whole line counts.
			if in_rest && v.options.rest_flat {
				parent_mode = .Fit
			}
			append(
				list,
				Tuple {
					indentation = data.indentation,
					// rols: a Fit group measures with its breaks as spaces
					mode = (v.mode == .Break || v.mode == .Fit ? v.mode : parent_mode),
					document = v.document,
					alignment = data.alignment,
				},
			)
		}
	}

	return width > 0
}

format_newline :: proc(indentation: int, alignment: int, consumed: ^int, builder: ^strings.Builder, p: ^Printer) {
	strings.write_string(builder, p.newline)
	for i := 0; i < indentation; i += 1 {
		strings.write_string(builder, p.indentation)
	}
	for i := 0; i < alignment; i += 1 {
		strings.write_string(builder, " ")
	}

	consumed^ = indentation * p.indentation_width + alignment
	p.render_line += 1
	p.line_indentation = indentation
}

flush_line_suffix :: proc(
	builder: ^strings.Builder,
	suffix_builder: ^strings.Builder,
	p: ^Printer,
	code_column: int,
	alignable: bool,
) {
	if len(suffix_builder.buf) == 0 {
		return
	}

	// rols: a comment queued without a space before it still must not touch the code
	column := code_column
	if n := len(builder.buf); n > 0 && builder.buf[n - 1] != ' ' && builder.buf[n - 1] != '\t' && builder.buf[n - 1] != '\n' {
		strings.write_string(builder, " ")
		column += 1
	}

	// Record trailing comments for the alignment post-pass, keyed on the comment's own line.
	if alignable {
		append(
			&p.trailing_comments,
			Trailing_Comment_Record {
				offset = len(builder.buf),
				// rols: the column includes the inserted space
				code_column = column,
				indentation = p.line_indentation,
				line_index = p.render_line,
			},
		)
	}

	strings.write_string(builder, strings.to_string(suffix_builder^))
	strings.builder_reset(suffix_builder)
}

format :: proc(width: int, list: ^[dynamic]Tuple, builder: ^strings.Builder, p: ^Printer) {
	assert(list != nil)
	assert(builder != nil)

	consumed := 0
	recalculate := false

	// Column and kind of the pending line suffix, captured for comment alignment.
	pending_suffix_column := 0
	pending_suffix_alignable := false

	suffix_builder := strings.builder_make()

	list_fits = make([dynamic]Tuple, 0, 100, p.allocator)

	for len(list) != 0 {
		data: Tuple = pop(list)

		switch v in data.document {
		case Document_Nil:
		case Document_Line_Suffix:
			if len(suffix_builder.buf) == 0 {
				pending_suffix_column = consumed
				pending_suffix_alignable = v.alignable
			} else {
				// Suffixes landing on the same output line would otherwise concatenate, and
				// `// a// b` makes the second `//` literal text inside the first comment.
				strings.write_string(&suffix_builder, " ")
			}
			strings.write_string(&suffix_builder, v.value)
		case Document_Break_Parent:
		case Document_Newline:
			if v.amount > 0 {
				flush_line_suffix(builder, &suffix_builder, p, pending_suffix_column, pending_suffix_alignable)
				// ensure we strip any misplaced trailing whitespace
				for len(builder.buf) > 0 && builder.buf[len(builder.buf) - 1] == ' ' {
					pop(&builder.buf)
				}
				for i := 0; i < v.amount; i += 1 {
					strings.write_string(builder, p.newline)
				}
				for i := 0; i < data.indentation; i += 1 {
					strings.write_string(builder, p.indentation)
				}
				for i := 0; i < data.alignment; i += 1 {
					strings.write_string(builder, " ")
				}
				consumed = data.indentation * p.indentation_width + data.alignment
				p.render_line += v.amount
				p.line_indentation = data.indentation

				if data.mode == .Flat {
					recalculate = true
				}
			}
		case Document_Cons:
			for i := len(v.elements) - 1; i >= 0; i -= 1 {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.elements[i],
						alignment = data.alignment,
					},
				)
			}
		case Document_Nest:
			if v.alignment != 0 {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.document,
						alignment = data.alignment + v.alignment,
					},
				)

			} else {
				append(
					list,
					Tuple {
						indentation = data.indentation + (v.negate ? -1 : 1),
						mode = data.mode,
						document = v.document,
						alignment = data.alignment + v.alignment,
					},
				)
			}
		case Document_Align:
			align := consumed - data.indentation * p.indentation_width
			append(
				list,
				Tuple{indentation = data.indentation, mode = data.mode, document = v.document, alignment = align},
			)
		case Document_Text:
			strings.write_string(builder, v.value)
			consumed += len(v.value)
		case Document_Break:
			if data.mode == .Break && v.newline {
				flush_line_suffix(builder, &suffix_builder, p, pending_suffix_column, pending_suffix_alignable)
				format_newline(data.indentation, data.alignment, &consumed, builder, p)
			} else if data.mode == .Fill && consumed < width {
				strings.write_string(builder, v.value)
				consumed += len(v.value)
			} else if data.mode == .Fill && v.newline {
				flush_line_suffix(builder, &suffix_builder, p, pending_suffix_column, pending_suffix_alignable)
				format_newline(data.indentation, data.alignment, &consumed, builder, p)
			} else {
				strings.write_string(builder, v.value)
				consumed += len(v.value)
			}
		case Document_If_Break_Or:
			mode := v.group_id != "" ? p.group_modes[v.group_id] : data.mode
			if mode == .Break {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.break_document,
						alignment = data.alignment,
					},
				)
			} else if v.fit_document != nil {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.fit_document,
						alignment = data.alignment,
					},
				)
			}
		case Document_Group:
			// rols: a `rest_flat` group only changes how a fit check measures it, so it lays out in its parent's mode
			if v.options.rest_flat {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = data.mode,
						document = v.document,
						alignment = data.alignment,
					},
				)
				break
			}
			// rols: a group with `measure` set decides its own mode even after another group on its line
			if data.mode == .Flat && !recalculate && !v.options.measure {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = v.mode,
						document = v.document,
						alignment = data.alignment,
					},
				)
				break
			}

			// rols: list_fits holds only the group; fits reads the pending stack through `rest` (the call below)
			clear(&list_fits)

			append(
				&list_fits,
				Tuple{indentation = data.indentation, mode = .Flat, document = v.document, alignment = data.alignment},
			)

			recalculate = false

			if data.mode == .Fit {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = .Fit,
						document = v.document,
						alignment = data.alignment,
					},
				)
			} else if fits(width - consumed, &list_fits, list[:]) && v.mode != .Break && v.mode != .Fit {
				append(
					list,
					Tuple {
						indentation = data.indentation,
						mode = .Flat,
						document = v.document,
						alignment = data.alignment,
					},
				)
			} else {
				if data.mode == .Fill || v.mode == .Fill {
					append(
						list,
						Tuple {
							indentation = data.indentation,
							mode = .Fill,
							document = v.document,
							alignment = data.alignment,
						},
					)
				} else if v.mode == .Fit {
					append(
						list,
						Tuple {
							indentation = data.indentation,
							mode = .Fit,
							document = v.document,
							alignment = data.alignment,
						},
					)
				} else {
					append(
						list,
						Tuple {
							indentation = data.indentation,
							mode = .Break,
							document = v.document,
							alignment = data.alignment,
						},
					)
				}
			}

			p.group_modes[v.options.id] = list[len(list) - 1].mode
		}
	}
}
