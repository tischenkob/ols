package lib

send_raw :: proc(x: int) {}
send_typed :: proc(x: ^$T) {}
send :: proc{send_raw, send_typed}
