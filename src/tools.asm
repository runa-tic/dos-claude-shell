; ============================================================
; tools.asm - the actions Claude may take (phase 7). For now it
; is offered none.
; ============================================================
        section .text

; tools_json: the "tools" member of the request, at ES:DI.
tools_json:
        ret

; tool_use: the tool_use block at block_at in the answer.
tool_use:
        ret

; tools_done: after all the blocks: the results into the conversation.
tools_done:
        ret
