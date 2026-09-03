package common

import "core:fmt"
import "core:log"
import "core:slice"

@(private = "file")
AppliedTextEdit :: struct {
	absolute: AbsoluteRange,
	index:    int,
	newText:  string,
}

// T is any struct with `range: Range` and `newText: string`, such as server.TextEdit.
apply_text_edits :: proc(edits: []$T, text: string) -> string {
	applied := make([dynamic]AppliedTextEdit, 0, len(edits), context.temp_allocator)

	for edit, i in edits {
		absolute, ok := get_absolute_range(edit.range, transmute([]u8)text)

		if !ok {
			log.errorf("Failed to get the absolute range of edit %v", edit)
			return text
		}

		append(&applied, AppliedTextEdit{absolute = absolute, index = i, newText = edit.newText})
	}

	//Back to front, with the ties broken so that the array order decides the order of insertions
	//that share a position.
	slice.sort_by(applied[:], proc(a, b: AppliedTextEdit) -> bool {
		if a.absolute.start != b.absolute.start {
			return a.absolute.start > b.absolute.start
		}

		return a.index > b.index
	})

	for a, i in applied {
		for b in applied[i + 1:] {
			if edits_conflict(a.absolute, b.absolute) {
				log.errorf(
					"Overlapping edits, the result depends on the order the client applies them in: %v and %v",
					edits[a.index],
					edits[b.index],
				)
			}
		}
	}

	result := text

	for a in applied {
		result = fmt.tprintf("%s%s%s", result[:a.absolute.start], a.newText, result[a.absolute.end:])
	}

	return result
}

@(private = "file")
edits_conflict :: proc(a, b: AbsoluteRange) -> bool {
	a_is_insert := a.start == a.end
	b_is_insert := b.start == b.end

	//Insertions that share a position are well defined by the order of the edits.
	if a_is_insert && b_is_insert {
		return false
	}

	if a_is_insert {
		return b.start <= a.start && a.start < b.end
	}

	if b_is_insert {
		return a.start <= b.start && b.start < a.end
	}

	return a.start < b.end && b.start < a.end
}
