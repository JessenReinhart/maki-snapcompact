local M = {}

-- Zero-width ink toggles understood by native renderer (shift-out/in)
M.DIM_ON = "\14"   -- \u{000e}
M.DIM_OFF = "\15"  -- \u{000f}

-- Solid full block printed in place of newline runs
M.NEWLINE_GLYPH = "\226\150\136" -- UTF-8 for \u{2588}

-- Budgets
M.MAX_FRAMES_DEFAULT = 80
M.HQ_EDGE_FRAMES = 3
M.FRAME_DATA_BYTES_BUDGET = 3000000
M.FRAME_DATA_BYTES_ESTIMATE = 170000
M.TOOL_RESULT_MAX_CHARS = 2000
M.TOOL_ARG_MAX_CHARS = 500
M.TOOL_CALL_MAX_CHARS = 2000
M.TRUNCATE_HEAD_RATIO = 0.6
M.TEXT_EDGE_PAGES = 1
M.DOC_GUTTER = 3

M.PRESERVE_KEY = "snapcompact"

return M
