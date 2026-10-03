package p

label :: proc(running: bool) -> string {
	l := "Start"
	if !running {
	} else {
 l = "Pause"
	}
	return l
}
