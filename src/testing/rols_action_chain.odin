package ols_testing

import "core:log"
import "core:strings"
import "core:testing"

/*
	Applies each action in `titles` in turn, putting the cursor back at the line and column of the
	`{*}` marker of `src.main` between steps. Returns the marker-free input and the final text,
	both in the temp allocator.
*/
apply_action_chain :: proc(t: ^testing.T, src: ^Source, titles: []string) -> (original, final: string) {
	marker := strings.index(src.main, "{*}")
	if marker < 0 {
		log.error("No {*} marker")
		return
	}
	line := strings.count(src.main[:marker], "\n")
	column := marker - (strings.last_index_byte(src.main[:marker], '\n') + 1)
	original, _ = strings.replace(src.main, "{*}", "", 1, context.temp_allocator)

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
		for _ in 0 ..< line {
			at += strings.index_byte(final[at:], '\n') + 1
		}
		at += column
		text = strings.concatenate({final[:at], "{*}", final[at:]}, context.temp_allocator)
	}
	return
}

// Applies the actions in order and compares the result with `expected`.
expect_action_chain :: proc(t: ^testing.T, src: ^Source, titles: []string, expected: string) {
	_, final := apply_action_chain(t, src, titles)
	testing.expectf(t, final == expected, "\nExpected:\n%s\n\nGot:\n%s", expected, final)
}

// Applies the actions in order and expects the input back.
expect_action_round_trip :: proc(t: ^testing.T, src: ^Source, titles: []string) {
	original, final := apply_action_chain(t, src, titles)
	testing.expectf(t, final == original, "\nExpected:\n%s\n\nGot:\n%s", original, final)
}
