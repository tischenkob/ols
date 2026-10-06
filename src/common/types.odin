package common

import "core:odin/ast"
import "core:odin/tokenizer"

Error :: enum {
	None                 = 0,
	ParseError           = -32700,
	InvalidRequest       = -32600,
	MethodNotFound       = -32601,
	InvalidParams        = -32602,
	InternalError        = -32603,
	serverErrorStart     = -32099,
	serverErrorEnd       = -32000,
	ServerNotInitialized = -32002,
	UnknownErrorCode     = -32001,
	RequestCancelled     = -32800,
	ContentModified      = -32801,
	// rols: the LSP code for a valid request that failed, which a refused import rename answers with
	RequestFailed        = -32803,
}

WorkspaceFolder :: struct {
	name: string,
	uri:  string,
}

parser_warning_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
}
