package p

Shape :: union { int, f32 }
make_shape :: proc() -> (s: Shape, changed: bool) { return 1, true }
