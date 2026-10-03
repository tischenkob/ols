// Corpus: examples raylib/tetroid/raylib_tetroid.odin:342, see docs/corpus-validation.md.
package odinfmt_test

Cell :: enum {
	Empty,
	Moving,
}

f :: proc(r: int) -> [4][4]Cell {
	incoming: [4][4]Cell
	switch r {
	case 0:
		incoming[1][1] = .Moving; incoming[2][1] = .Moving
		incoming[1][2] = .Moving
		incoming[2][2] = .Moving //Cube
	}
	return incoming
}
