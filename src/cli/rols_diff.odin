package cli

import "core:fmt"
import "core:slice"
import "core:strings"

DIFF_CONTEXT :: 3

@(private = "file")
Diff_Op :: enum u8 {
	Equal,
	Delete,
	Insert,
}

// One line of the edit script: old and new are the 0-based line indices before the op consumes its line.
@(private = "file")
Diff_Line :: struct {
	op:       Diff_Op,
	old, new: int,
	text:     string,
}

// Writes a unified diff of old into new to b. old_label and new_label follow `---` and `+++`, such as
// a/main.odin or /dev/null. Writes nothing when the texts are equal.
write_unified_diff :: proc(b: ^strings.Builder, old_label, new_label, old, new: string) {
	if old == new {
		return
	}
	a, c := split_lines_keep(old), split_lines_keep(new)
	script := edit_script(a, c)

	fmt.sbprintfln(b, "--- %s", old_label)
	fmt.sbprintfln(b, "+++ %s", new_label)
	for i := 0; i < len(script); {
		if script[i].op == .Equal {
			i += 1
			continue
		}
		start := max(0, i - DIFF_CONTEXT)
		// Extend over runs of changes whose separating context would overlap.
		end := i
		for {
			for end < len(script) && script[end].op != .Equal {
				end += 1
			}
			gap := end
			for gap < len(script) && script[gap].op == .Equal {
				gap += 1
			}
			if gap < len(script) && gap - end <= 2 * DIFF_CONTEXT {
				end = gap
				continue
			}
			break
		}
		stop := min(len(script), end + DIFF_CONTEXT)
		write_hunk(b, script[start:stop])
		i = stop
	}
}

@(private = "file")
write_hunk :: proc(b: ^strings.Builder, lines: []Diff_Line) {
	old_count, new_count := 0, 0
	for line in lines {
		if line.op != .Insert do old_count += 1
		if line.op != .Delete do new_count += 1
	}
	// An empty side names the line before the hunk, 0 at the start of the file.
	old_start := lines[0].old + (1 if old_count > 0 else 0)
	new_start := lines[0].new + (1 if new_count > 0 else 0)
	fmt.sbprintfln(b, "@@ -%s +%s @@", hunk_range(old_start, old_count), hunk_range(new_start, new_count))
	for line in lines {
		marker := " " if line.op == .Equal else "-" if line.op == .Delete else "+"
		strings.write_string(b, marker)
		strings.write_string(b, line.text)
		if !strings.has_suffix(line.text, "\n") {
			strings.write_string(b, "\n\\ No newline at end of file\n")
		}
	}
}

@(private = "file")
hunk_range :: proc(start, count: int) -> string {
	return fmt.tprintf("%d", start) if count == 1 else fmt.tprintf("%d,%d", start, count)
}

// The lines of text with their newlines, so a missing final newline is a difference.
@(private = "file")
split_lines_keep :: proc(text: string) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	for rest := text; len(rest) > 0; {
		n := strings.index_byte(rest, '\n')
		if n < 0 {
			append(&lines, rest)
			break
		}
		append(&lines, rest[:n + 1])
		rest = rest[n + 1:]
	}
	return lines[:]
}

// The shortest edit script from a to b: the common prefix and suffix, and Myers' O(ND) diff between them.
@(private = "file")
edit_script :: proc(a, b: []string) -> []Diff_Line {
	prefix := 0
	for prefix < len(a) && prefix < len(b) && a[prefix] == b[prefix] {
		prefix += 1
	}
	suffix := 0
	for suffix < len(a) - prefix && suffix < len(b) - prefix && a[len(a) - 1 - suffix] == b[len(b) - 1 - suffix] {
		suffix += 1
	}

	script := make([dynamic]Diff_Line, 0, len(a) + len(b), context.temp_allocator)
	for i in 0 ..< prefix {
		append(&script, Diff_Line{.Equal, i, i, a[i]})
	}
	middle := myers(a[prefix:len(a) - suffix], b[prefix:len(b) - suffix])
	for op in middle {
		append(&script, Diff_Line{op.op, op.old + prefix, op.new + prefix, op.text})
	}
	for k in 0 ..< suffix {
		i, j := len(a) - suffix + k, len(b) - suffix + k
		append(&script, Diff_Line{.Equal, i, j, a[i]})
	}
	return script[:]
}

// Keeps the frontier of every round for the backtrack, O(D²) memory for D changed lines.
@(private = "file")
myers :: proc(a, b: []string) -> []Diff_Line {
	n, m := len(a), len(b)
	script := make([dynamic]Diff_Line, 0, n + m, context.temp_allocator)
	if n == 0 || m == 0 {
		for i in 0 ..< n {
			append(&script, Diff_Line{.Delete, i, 0, a[i]})
		}
		for j in 0 ..< m {
			append(&script, Diff_Line{.Insert, n, j, b[j]})
		}
		return script[:]
	}

	limit := n + m
	offset := limit + 1
	v := make([]int, 2 * limit + 3, context.temp_allocator)
	// trace[d] holds v[-d..d] as it was before round d.
	trace := make([dynamic][]int, context.temp_allocator)
	search: for d in 0 ..= limit {
		append(&trace, slice.clone(v[offset - d:offset + d + 1], context.temp_allocator))
		for k := -d; k <= d; k += 2 {
			x: int
			if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
				x = v[offset + k + 1]
			} else {
				x = v[offset + k - 1] + 1
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x += 1
				y += 1
			}
			v[offset + k] = x
			if x >= n && y >= m {
				break search
			}
		}
	}

	x, y := n, m
	for d := len(trace) - 1; d > 0; d -= 1 {
		before := trace[d]
		k := x - y
		prev_k := k - 1
		if k == -d || (k != d && before[k - 1 + d] < before[k + 1 + d]) {
			prev_k = k + 1
		}
		prev_x := before[prev_k + d]
		prev_y := prev_x - prev_k
		for x > prev_x && y > prev_y {
			x -= 1
			y -= 1
			append(&script, Diff_Line{.Equal, x, y, a[x]})
		}
		if x == prev_x {
			y -= 1
			append(&script, Diff_Line{.Insert, x, y, b[y]})
		} else {
			x -= 1
			append(&script, Diff_Line{.Delete, x, y, a[x]})
		}
	}
	for x > 0 && y > 0 {
		x -= 1
		y -= 1
		append(&script, Diff_Line{.Equal, x, y, a[x]})
	}
	slice.reverse(script[:])
	return script[:]
}
