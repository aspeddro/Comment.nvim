local U = require('Comment.utils')
local A = vim.api

local O = {}

---Opfunc options
---@class OpFnParams
---@field cfg Config
---@field cmode CMode
---@field lines table List of lines
---@field rcs string RHS of commentstring
---@field lcs string LHS of commentstring
---@field srow number Starting row
---@field erow number Ending row
---@field scol number Starting column
---@field ecol number Ending column

---Common operatorfunc callback
---@param cfg Config Plugin config
---@param vmode string VIM mode - line|char
---@param cmode CMode Comment mode
---@param ctype CType Type of the commentstring (line/block)
---@param cmotion CMotion Motion type
function O.opfunc(cfg, vmode, cmode, ctype, cmotion)
    -- comment/uncomment logic
    --
    -- 1. type == line
    --      * decide whether to comment or not, if all the lines are commented then uncomment otherwise comment
    --      * also, store the minimum indent from all the lines (exclude empty line)
    --      * if comment the line, use cstr LHS and also considering the min indent
    --      * if uncomment the line, remove cstr LHS from lines
    --      * update the lines
    -- 2. type == block
    --      * check if the first and last is commented or not with cstr LHS and RHS respectively.
    --      * if both lines commented
    --          - remove cstr LHS from the first line
    --          - remove cstr RHS to end of the last line
    --      * if both lines uncommented
    --          - add cstr LHS after the leading whitespace and before the first char of the first line
    --          - add cstr RHS to end of the last line
    --      * update the lines

    cmotion = cmotion == U.cmotion._ and U.cmotion[vmode] or cmotion

    local srow, erow, lines, scol, ecol = U.get_lines(vmode, ctype)

    local same_line = srow == erow
    local partial_block = cmotion == U.cmotion.char or cmotion == U.cmotion.v
    local block_x = partial_block and same_line

    ---@type Ctx
    local ctx = {
        cmode = cmode,
        cmotion = cmotion,
        ctype = block_x and U.ctype.block or ctype,
    }

    local lcs, rcs = U.parse_cstr(cfg, ctx)

    if block_x then
        ctx.cmode = O.blockwise_x({
            cfg = cfg,
            cmode = cmode,
            lines = lines,
            lcs = lcs,
            rcs = rcs,
            srow = srow,
            erow = erow,
            scol = scol,
            ecol = ecol,
        })
    elseif ctype == U.ctype.block and not same_line then
        ctx.cmode = O.blockwise({
            cfg = cfg,
            cmode = cmode,
            lines = lines,
            lcs = lcs,
            rcs = rcs,
            srow = srow,
            erow = erow,
            scol = scol,
            ecol = ecol,
        }, partial_block)
    else
        ctx.cmode = O.linewise({
            cfg = cfg,
            cmode = cmode,
            lines = lines,
            lcs = lcs,
            rcs = rcs,
            srow = srow,
            erow = erow,
        })
    end

    -- We only need to restore cursor if both sticky and position are available
    -- As this function is also called for visual mapping where we are not storing the position
    --
    -- And I found out that if someone presses `gc` but doesn't provide operators and
    -- does visual comments then cursor jumps to previous stored position. Thus the check for visual modes
    if cfg.sticky and cfg.___pos and cmotion ~= U.cmotion.v and cmotion ~= U.cmotion.V then
        A.nvim_win_set_cursor(0, cfg.___pos)
        cfg.___pos = nil
    end

    U.is_fn(cfg.post_hook, ctx, srow, erow, scol, ecol)
end

---Linewise commenting
---@param p OpFnParams
---@return integer CMode
function O.linewise(p)
    local lcs_esc, rcs_esc = U.escape(p.lcs), U.escape(p.rcs)
    local pattern = U.get_pattern(p.cfg.ignore)
    local padding, pp = U.get_padding(p.cfg.padding)
    local is_commented = U.is_commented(lcs_esc, rcs_esc, pp)

    -- While commenting a block of text, there is a possiblity of lines being both commented and non-commented
    -- In that case, we need to figure out that if any line is uncommented then we should comment the whole block or vise-versa
    local cmode = U.cmode.uncomment

    -- When commenting multiple line, it is to be expected that indentation should be preserved
    -- So, When looping over multiple lines we need to store the indentation of the mininum length (except empty line)
    -- Which will be used to semantically comment rest of the lines
    local min_indent = nil

    -- If the given comde is uncomment then we actually don't want to compute the cmode or min_indent
    if p.cmode ~= U.cmode.uncomment then
        for _, line in ipairs(p.lines) do
            -- I wish lua had `continue` statement [sad noises]
            if not U.ignore(line, pattern) then
                if cmode == U.cmode.uncomment and p.cmode == U.cmode.toggle then
                    local is_cmt = is_commented(line)
                    if not is_cmt then
                        cmode = U.cmode.comment
                    end
                end

                -- If the internal cmode changes to comment or the given cmode is not uncomment, then only calculate min_indent
                -- As calculating min_indent only makes sense when we actually want to comment the lines
                if not U.is_empty(line) and (cmode == U.cmode.comment or p.cmode == U.cmode.comment) then
                    local indent = U.grab_indent(line)
                    if not min_indent or #min_indent > #indent then
                        min_indent = indent
                    end
                end
            end
        end
    end

    -- If the comment mode given is not toggle than force that mode
    if p.cmode ~= U.cmode.toggle then
        cmode = p.cmode
    end

    local uncomment = cmode == U.cmode.uncomment
    for i, line in ipairs(p.lines) do
        if not U.ignore(line, pattern) then
            if uncomment then
                p.lines[i] = U.uncomment_str(line, lcs_esc, rcs_esc, pp)
            else
                p.lines[i] = U.comment_str(line, p.lcs, p.rcs, padding, min_indent)
            end
        end
    end
    A.nvim_buf_set_lines(0, p.srow - 1, p.erow, false, p.lines)

    return cmode
end

---Full/Partial Blockwise commenting
---@param p OpFnParams
---@param partial boolean Whether to do a partial or full comment
---@return integer CMode
function O.blockwise(p, partial)
    -- Block wise, only when there are more than 1 lines
    local sln, eln = p.lines[1], p.lines[2]
    local lcs_esc, rcs_esc = U.escape(p.lcs), U.escape(p.rcs)
    local padding, pp = U.get_padding(p.cfg.padding)

    -- These string should be checked for comment/uncomment
    local sln_check = sln
    local eln_check = eln
    if partial then
        sln_check = sln:sub(p.scol + 1)
        eln_check = eln:sub(0, p.ecol + 1)
    end

    -- If given mode is toggle then determine whether to comment or not
    local cmode
    if p.cmode == U.cmode.toggle then
        local s_cmt = U.is_commented(lcs_esc, nil, pp)(sln_check)
        local e_cmt = U.is_commented(nil, rcs_esc, pp)(eln_check)
        cmode = (s_cmt and e_cmt) and U.cmode.uncomment or U.cmode.comment
    else
        cmode = p.cmode
    end

    local l1, l2

    if cmode == U.cmode.uncomment then
        l1 = U.uncomment_str(sln_check, lcs_esc, nil, pp)
        l2 = U.uncomment_str(eln_check, nil, rcs_esc, pp)
    else
        l1 = U.comment_str(sln_check, p.lcs, nil, padding)
        l2 = U.comment_str(eln_check, nil, p.rcs, padding)
    end

    if partial then
        l1 = sln:sub(0, p.scol) .. l1
        l2 = l2 .. eln:sub(p.ecol + 2)
    end

    A.nvim_buf_set_lines(0, p.srow - 1, p.srow, false, { l1 })
    A.nvim_buf_set_lines(0, p.erow - 1, p.erow, false, { l2 })

    return cmode
end

---Blockwise (left-right/x-axis motion) commenting
---@param p OpFnParams
---@return integer CMode
function O.blockwise_x(p)
    local line = p.lines[1]
    local first = line:sub(0, p.scol)
    local mid = line:sub(p.scol + 1, p.ecol + 1)
    local last = line:sub(p.ecol + 2)

    local padding, pp = U.get_padding(p.cfg.padding)

    local yes, _, stripped = U.is_commented(U.escape(p.lcs), U.escape(p.rcs), pp)(mid)

    local cmode
    if p.cmode == U.cmode.toggle then
        cmode = yes and U.cmode.uncomment or U.cmode.comment
    else
        cmode = p.cmode
    end

    if cmode == U.cmode.uncomment then
        A.nvim_set_current_line(first .. (stripped or mid) .. last)
    else
        local lcs = p.lcs and p.lcs .. padding or ''
        local rcs = p.rcs and padding .. p.rcs or ''
        A.nvim_set_current_line(first .. lcs .. mid .. rcs .. last)
    end

    return cmode
end

---Toggle line comment with count
---Example: `10gl` will comment 10 lines
---@param cfg Config
function O.count(cfg)
    ---@type Ctx
    local ctx = {
        cmode = U.cmode.toggle,
        cmotion = U.cmotion.line,
        ctype = U.ctype.line,
    }
    local lcs, rcs = U.parse_cstr(cfg, ctx)
    local srow, erow, lines = U.get_count_lines(vim.v.count)
    ctx.cmode = O.linewise({
        cfg = cfg,
        cmode = ctx.cmode,
        lines = lines,
        lcs = lcs,
        rcs = rcs,
        srow = srow,
        erow = erow,
    })
    U.is_fn(cfg.post_hook, ctx, srow, erow)
end

return O
