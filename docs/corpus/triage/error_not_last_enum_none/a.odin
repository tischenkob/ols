package p

Kind :: enum { None, Box }
pick :: proc() -> (Kind, int) { return .Box, 1 }
