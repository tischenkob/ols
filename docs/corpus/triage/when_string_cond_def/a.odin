package p

E_NAME :: "gl"
when E_NAME == "gl" {
	E :: 1
} else {
	E :: 2
}
use :: proc() -> int { return E }
