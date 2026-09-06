package server

import "core:fmt"
import "core:sync"

WriterFn :: proc(_: rawptr, _: []byte) -> (int, int)

Writer :: struct {
	writer_fn:      WriterFn,
	writer_context: rawptr,
	writer_mutex:   sync.Mutex,
}

make_writer :: proc(writer_fn: WriterFn, writer_context: rawptr) -> Writer {
	writer := Writer {
		writer_context = writer_context,
		writer_fn      = writer_fn,
	}
	return writer
}

// Header and body go out under one lock: the checker thread writes to the same stdout,
// and a frame split across two writes lets its output land between them.
write_message :: proc(writer: ^Writer, data: []byte) -> bool {
	header := fmt.tprintf("Content-Length: %v\r\n\r\n", len(data))

	sync.mutex_lock(&writer.writer_mutex)
	defer sync.mutex_unlock(&writer.writer_mutex)

	_, err := writer.writer_fn(writer.writer_context, transmute([]u8)header)
	if err == 0 {
		_, err = writer.writer_fn(writer.writer_context, data)
	}
	return err == 0
}
