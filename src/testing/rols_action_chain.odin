package ols_testing

import "core:log"
import "core:strings"
import "core:testing"

/*
	Applies each action in `titles` in turn, putting the cursor back between steps: at the start of
	`cursors[i]` in the text left by step `i` when one is given, else at the line and column of the
	`{*}` or `{[` marker of `src.main`. Returns the marker-free input and the final text, both in
	the temp allocator.
*/
apply_action_chain :: proc(
	t: ^testing.T,
	src: ^Source,
	titles: []string,
	cursors: []string = nil,
) -> (
	original, final: string,
) {
	marker := strings.index(src.main, "{*}")
	if marker < 0 {
		marker = strings.index(src.main, "{[")
	}
	if marker < 0 {
		log.error("No {*} or {[ marker")
		return
	}
	line := strings.count(src.main[:marker], "\n")
	column := marker - (strings.last_index_byte(src.main[:marker], '\n') + 1)

	original = src.main
	for m in ([?]string{"{*}", "{[", "]}"}) {
		original, _ = strings.replace_all(original, m, "", context.temp_allocator)
	}

	text := src.main
	for title, i in titles {
		step := Source {
			main        = text,
			files       = src.files,
			packages    = src.packages,
			collections = src.collections,
			config      = src.config,
		}

		ok: bool
		final, ok = apply_action(t, &step, title)
		if !ok {
			return
		}

		if i + 1 >= len(titles) {
			break
		}

		at := 0
		if i < len(cursors) && cursors[i] != "" {
			at = strings.index(final, cursors[i])
			if at < 0 {
				log.errorf("No `%s` in\n%s", cursors[i], final)
				return
			}
		} else {
			for _ in 0 ..< line {
				at += strings.index_byte(final[at:], '\n') + 1
			}
			at += column
		}
		text = strings.concatenate({final[:at], "{*}", final[at:]}, context.temp_allocator)
	}
	return
}

// Applies the actions in order and compares the result with `expected`.
expect_action_chain :: proc(t: ^testing.T, src: ^Source, titles: []string, expected: string, cursors: []string = nil) {
	_, final := apply_action_chain(t, src, titles, cursors)
	testing.expectf(t, final == expected, "\nExpected:\n%s\n\nGot:\n%s", expected, final)
}

// Applies the actions in order and expects the input back.
expect_action_round_trip :: proc(t: ^testing.T, src: ^Source, titles: []string, cursors: []string = nil) {
	original, final := apply_action_chain(t, src, titles, cursors)
	testing.expectf(t, final == original, "\nExpected:\n%s\n\nGot:\n%s", original, final)
}
