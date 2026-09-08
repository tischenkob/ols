#+private file

package server

import "core:fmt"
import "core:odin/ast"

// Labels the loop whose header the cursor sits in. Existing unlabeled `break`/`continue` inside
// the body keep targeting whatever they targeted before.
@(private = "package")
add_loop_label_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_loop_label {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	loop: ^ast.Node
	body: ^ast.Stmt
	#reverse for at in nodes_at({function.body}, ctx.range.start) {
		#partial switch n in at.node.derived {
		case ^ast.For_Stmt:
			if n.label != nil {
				return
			}
			loop, body = n, n.body
		case ^ast.Range_Stmt:
			if n.label != nil {
				return
			}
			loop, body = n, n.body
		case:
			continue
		}
		break
	}
	if loop == nil || body == nil || ctx.range.start >= body.pos.offset {
		return
	}

	base := "loop"
	if contains_loop(body) {
		base = "outer"
	}
	append_insert(
		ctx,
		loop.pos.offset,
		"Add loop label",
		"refactor.rewrite",
		fmt.tprintf("%s: ", fresh_name(ctx, base, loop.pos)),
	)
}

contains_loop :: proc(body: ^ast.Stmt) -> bool {
	found := false
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch _ in node.derived {
			case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return found
}
