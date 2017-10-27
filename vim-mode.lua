--            MIT Copyright 2017 Paul Reilly (https://opensource.org/licenses/MIT)
--   
--   
--     ::::::::: :::::::::   ::::::::                :::     ::: ::::::::::: ::::    ::::  
--          :+:  :+:    :+: :+:    :+:               :+:     :+:     :+:     +:+:+: :+:+:+ 
--         +:+   +:+    +:+ +:+                      +:+     +:+     +:+     +:+ +:+:+ +:+ 
--        +#+    +#++:++#+  +#++:++#++ +#++:++#++:++ +#+     +:+     +#+     +#+  +:+  +#+ 
--       +#+     +#+    +#+        +#+                +#+   +#+      +#+     +#+       +#+ 
--      #+#      #+#    #+# #+#    #+#                 #+#+#+#       #+#     #+#       #+# 
--     ######### #########   ########                    ###     ########### ###       ### 
--    
--                  zbs-vim adds a useful subset of Vim-like editing to ZBS
--                     and the ability to open current document in Vim
--   
--                                        Commands
--                                        --------
--   
--         normal mode:
--                [num]h, j, k, l, yy, G, dd, dw, db, cc, cw, cb, x, b, w, p, {, }, f, F
--                $, ^, 0, gg, gt, gT, z., zz, zt, zb, d^, d0, d$, c^, c0, c$, m, '
--                i, I, a, A (not stored in buffers for repeating)
--                supports 'i' for inside, eg ci" or di" for change/delete text inside quotes
--                # - opens current document in real instance of Vim
--                m# - deletes all markers
--   
--         visual mode, visual block mode
--   
--         command line mode:
--                w, q
--   
--   
--         '-' remapped as '$' so '0' = HOME, '-' = END
--   
--   
----------------------------------------------------------------------------------------------------
local DEBUG = false
local _DBG -- (...) for console output, definition at EOF

-- forward declarations of function variables
local hasSelection
local selectCurrentLine
local setCaret
local resetCmd
local cmds = {}
local markers = {}

local editMode = nil
-- bound repetitions of some functions to this value
-- to avoid pasting stuff 100,000 times or whatever
local _MAX_REPS = 50 
local curEditor = nil -- set in onEditorKeyDown
local selectionAnchor = 0

local cmd -- initialised in onRegister
local cmdLast

----------------------------------------------------------------------------------------------------
local keymap = {}

-- remap any keys you want here
keymap.user = { ["-"] = "$" }             

-- Table mapping number keys to their shifted characters. You might need to edit this to suit
-- your locale
keymap.shift = {["0"] = ")", ["1"] = "!", ["2"]  = "\"", ["3"] = "£", ["4"] = "$", 
                ["5"] = "%", ["6"] = "^", ["7"]  = "&" , ["8"] = "*", ["9"] = "(",
                [";"] = ":", ["'"] = "@", ["#"]  = "~" , ["["] = "{", ["]"] = "}",
                ["-"] = "_", ["="] = "+", ["\\"] = "|" , [","] = "<", ["."] = ">",
                ["/"] = "?"
}

keymap.sys = {["8"]   = "BS",   ["9"]   = "TAB",   ["92"]  = "\\",   ["127"] = "DEL",     
              ["312"] = "END",  ["313"] = "HOME",  ["314"] = "LEFT", ["315"] = "UP",   
              ["316"] = "RIGHT",["317"] = "DOWN",  ["366"] = "PGUP", ["367"] = "PGDOWN"}

-- convert keyDown event key number to real char
keymap.keyNumToChar = function(keyNum)
  local number
  if keyNum >= 48 and keyNum <= 57 then
    number = keyNum - 48
    if not wx.wxGetKeyState(wx.WXK_SHIFT) then
      return number
    else
      return keymap.shift[tostring(number)]
    end
  else
    if keyNum >= 32 and keyNum <= 126 then
      key = string.char(keyNum)
      if not wx.wxGetKeyState(wx.WXK_SHIFT) then 
        return key:lower()
      else
        if keymap.shift[key] then return keymap.shift[key] else return key end
      end
    end
  end
  return (keymap.sys[tostring(keyNum)] or tostring(keyNum))
end

keymap.isKeyModifier = function(keyNum)
  return ( keyNum >= 306 and keyNum <= 308 )
end

keymap.hotKeysToOverride = {
  { sc = "Ctrl+r", act = function() curEditor:Redo() end,                                 id = nil },
  { sc = "Ctrl+v", act = function() cmds.general.execute("v+Ctrl", curEditor, false) end, id = nil }
}

keymap.overrideHotKeys = function(overrideNotRestore)
  if overrideNotRestore then
    for k, v in pairs(keymap.hotKeysToOverride) do
      local sc -- shortcut
      if v.id == nil then 
        v.id, sc = ide:GetHotKey(v.sc) 
        if v.id == nil then ide:Print("Could not get hot key.") return end
      end
      local ret = ide:SetHotKey(v.act, v.sc)
      if ret == nil then ide:Print("Cannot set shortcut: ".. v.sc) end
    end
  else
    for k, v in pairs(keymap.hotKeysToOverride) do
      local ret = ide:SetHotKey(v.id, v.sc)
      if ret == nil then ide:Print("Cannot set shortcut: ".. v.sc) end
    end
  end
end

----------------------------------------------------------------------------------------------------
local kEditMode = { normal = "Normal", visual = "Visual", visualBlock = "Visual - Block",
                    visualLine = "Visual - Line",
                    insert = "Insert - ZeroBrane", commandLine = "Command Line" }

-- for the Lua equivalent of brace matching with 'end's at some point
local luaSectionKeywords = { ["local function"] = "local function", ["function"] = "function", 
                             ["while"] = "while", ["for"] = "for", ["if"] = "if", 
                             ["repeat"] = "repeat" }

local m_brace   = { left = "{", right = "}" }
local m_bracket = { left = "(", right = ")" }
local m_square  = { left = "[", right = "]" }
local m_angle   = { left = "<", right = ">" }
local match = { ["{"] = m_brace,  ["}"] = m_brace,  ["("] = m_bracket, [")"] = m_bracket, 
                ["["] = m_square, ["]"] = m_square, ["<"] = m_angle,   [">"] = m_angle }


----------------------------------------------------------------------------------------------------
function shallowcopy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in pairs(orig) do
      copy[orig_key] = orig_value
    end
  else -- number, string, boolean, etc
    copy = orig
  end
  return copy
end

-- must have vim in path
local function openRealVim(ed)
  local doc = ide:GetDocument(ed)
  if doc ~= nil then
    doc:Save()
    local pos = ed:GetCurrentPos()
    local lineNumber = ed:LineFromPosition(pos)
    -- open in separate process, so it doesn't block ZBS
    os.execute("start cmd /c vim +".. (lineNumber + 1) .." \"".. doc:GetFilePath().. "\"")
  end
end

local function isModeVisual(mode)
  return ( mode == kEditMode.visual or mode == kEditMode.visualBlock or 
           mode == kEditMode.visualLine )
end

local function setMode(mode, overtype)
  if not curEditor then editMode = mode return end
  local pos = curEditor:GetCurrentPos()
  if isModeVisual(mode) and isModeVisual(editMode) then
    editMode = kEditMode.normal
    curEditor:SetEmptySelection(pos)
    selectionAnchor = nil
  else
    if isModeVisual(mode) then
      selectionAnchor = pos
      curEditor:SetAnchor(pos)
      
      if mode == kEditMode.visualBlock then 
        -- this works with multiple selections
        curEditor:SetSelectionStart(selectionAnchor)
        curEditor:SetSelectionMode(wxstc.wxSTC_SEL_RECTANGLE)
        curEditor:SetRectangularSelectionAnchor(pos)
        curEditor:SetRectangularSelectionCaret(pos)
        
      elseif mode == kEditMode.visual then curEditor:SetSelectionMode(wxstc.wxSTC_SEL_STREAM)
        
      elseif mode == kEditMode.visualLine then 
        -- TODO: make this work with wx line select mode
        local line = curEditor:GetCurrentLine()
        local lineStart = curEditor:PositionFromLine(line)
        curEditor:SetRectangularSelectionAnchor(lineStart)
        curEditor:SetRectangularSelectionAnchor(lineStart)
        curEditor:SetCurrentPos(lineStart)
        curEditor:SetSelectionMode(wxstc.wxSTC_SEL_LINES)
        curEditor:SetSelectionStart(lineStart)
        curEditor:SetAnchor(lineStart)
        
        selectionAnchor = lineStart
      end
    else
      keymap.overrideHotKeys(mode ~= kEditMode.insert)
      selectionAnchor = nil
    end
    editMode = mode
    if editMode == kEditMode.normal then curEditor:SetEmptySelection(pos) end
  end
  ide:SetStatus("Vim mode: "..mode)
  setCaret(curEditor)
  curEditor:SetOvertype(overtype)
end

----------------------------------------------------------------------------------------------------
-- text editing functions
----------------------------------------------------------------------------------------------------
function setCaret(editor)
  editor:SetCaretStyle(editMode == kEditMode.insert and 1 or 2)
end

-- some wxStyledTextCtrl methods have Extend versions
-- so this saves a bit of duplication for working
-- in visual mode
local function callExtendableFunc(obj, name, reps, canRectExtend)
  cmd.origPos = curEditor:GetCurrentPos()
  local extend = ""
  if isModeVisual(editMode) then
    if editMode == (kEditMode.visualBlock or editMode == kEditMode.visualLine) and canRectExtend then
      extend = "RectExtend"
    else
      extend = "Extend"
    end
  end
  reps = reps or 1
  for i = 1, reps do
    obj[name .. extend](obj)
  end
  return canRectExtend
end

function setSelectionFromPositions(ed, pos1, pos2)
  local min = math.min(pos1, pos2)
  ed:SetSelectionStart(min)
  ed:SetSelectionEnd(math.max(pos1, pos2))
  -- SetSelectionStart also sets anchor, but we want to preserve ours
  -- in visual mode
  if isModeVisual(editMode) then
    ed:SetAnchor(selectionAnchor)
  end
end

-- called before executing a cmd, so that selection is correct
-- for wx Cut/Copy methods
function setCmdSelection(ed, cmd, wordwise, linewise)
  if linewise then cmds.motions.execute("j", ed, math.max(0,cmd.count1 - 1)) end
  setSelectionFromPositions(ed, ed:GetCurrentPos(), cmd.origPos)
  if linewise then
    ed:SetSelectionStart(ed:PositionFromLine(ed:LineFromPosition(ed:GetSelectionStart())))
    local finalLine = ed:LineFromPosition(ed:GetSelectionEnd())
    local lineStart = ed:PositionFromLine(finalLine)
    local lineEnd = lineStart + ed:LineLength(finalLine)
    ed:SetSelectionEnd(lineEnd)
  elseif wordwise then
    local char = ed:GetCharAt(ed:GetSelectionEnd() - 1)
    if cmd.keepSpaces == nil then
      while char == 32 do
        ed:SetSelectionEnd(ed:GetSelectionEnd() - 1)
        char = ed:GetCharAt(ed:GetSelectionEnd() - 1)
      end
    end
  end
end

-- set caret at position, extending the selection in visual modes
local function gotoPosition(ed, pos)
  if isModeVisual(editMode) then
    setSelectionFromPositions(ed, selectionAnchor, pos)
    ed:SetCurrentPos(pos)
  else
    ed:GotoPos(pos)
  end
end

local searchForAndGoto

local function find(ed, text, searchBackwards, redo)
  local extend = isModeVisual(editMode)
  local flags = wxstc.wxSTC_FIND_MATCHCASE -- wxstc.wxSTC_FIND_WHOLEWORD  
  minPos = redo == nil and ed:GetCurrentPos() or redo
  local maxPos = searchBackwards and 0 or ed:GetLength()
  local pos = ed:FindText(minPos, maxPos, text, flags)
  if pos ~= wxstc.wxSTC_INVALID_POSITION then
    if pos == minPos then 
      -- we're already at the beginning of the text, search again from after text
      if redo == nil then 
        find(ed, text, searchBackwards, minPos + #text)
        return pos
      end
    end
  end
  return pos
end
  
-- used with f and F cmds so far 
function searchForAndGoto(ed, text, nth, searchBackwards, redo)
  local pos = 0
  nth = nth or 1
  for i = 1, nth do
    pos = find(ed, text, searchBackwards, redo)
    if pos == wxstc.wxSTC_INVALID_POSITION then 
      return wxstc.wxSTC_INVALID_POSITION
    end
  end
  gotoPosition(ed, pos)
  return pos
end

function hasSelection(editor)
  return (editor:GetSelectionStart() ~= editor:GetSelectionEnd())
end

local function cancelSelection(ed)
  ed:SetEmptySelection(ed:GetCurrentPos())
  setMode(kEditMode.normal)
end

-- in visualBLock mode, wx uses per line multiple selections so we
-- remove any carets that are not within a block selection
local function setBlockCaret(ed)
  if editMode == kEditMode.visualBlock or editMode == kEditMode.visualLine then
    local anchorColumn = ed:GetColumn(selectionAnchor)
    local posColumn = ed:GetColumn(ed:GetCurrentPos())
    local caretRHS = posColumn >= anchorColumn
    local numSelections = ed:GetSelections()
    for i = ed:GetSelections() - 1, 0, -1 do
      local sel = ed:GetColumn(ed:GetSelectionNCaret(i))
      -- only keep lines selected that have content within the block here
      if (i ~= ed:GetMainSelection()) and ((caretRHS and (sel < anchorColumn)) 
                            or (not caretRHS and (sel < posColumn))) then
        ed:DropSelectionN(i)
      end
    end
  end
end



----------------------------------------------------------------------------------------------------
-- vim commands and logic
----------------------------------------------------------------------------------------------------
cmds = {}

-- rough copies of structures used by neovim to keep things extendable
-- only cmd used just now, but any future direction should be towards these.
local kMT = { 
  CharWise = 0,     --< character-wise movement/register
  LineWise = 1,     --< line-wise movement/register
  BlockWise = 2,    --< block-wise movement/register
  Unknown = -1      --< Unknown or invalid motion type
} -- MotionType

cmds.newOperator = function()
  local op = {
    op_type = "",                  -- current pending operator type
    regname = 0,                   -- register to use for the operator
    motion_type = kMT.CharWise,    -- type of the current cursor motion
    motion_force = "",             -- force motion type: 'v', 'V' or CTRL-V
    use_reg_one = false,           -- true if delete uses reg 1 even when not
                                   -- linewise
    inclusive = false,             -- true if char motion is inclusive (only
                                   -- valid when motion_type is kMTCharWise)
    end_adjusted = false,          -- backuped b_op_end one char (only used by
                                   -- do_format())
    startPos = 0,                  -- start of the operator
    endPos = 0,                    -- end of the operator
    cursor_start = 0,              -- cursor position before motion for "gw"
    line_count = 0,                -- number of lines from op_start to op_end
                                   -- (inclusive)
    empty = false,                 -- op_start and op_end the same (only used by
                                   -- op_change())
    isVisual = false,              -- operator on Visual area
    --start_vcol = 0,              -- start col for block mode operator
    --end_vcol = 0,                -- end col for block mode operator
    prev_opcount = 0,              -- ca.opcount saved for K_EVENT
    prev_count0 = 0                -- ca.count0 saved for K_EVENT
  }
  return op
end

cmds.newCommand = function(searchbuf)
  local cmd = {
    op = cmds.newOperator(),   -- operator arguments
    prechar = "",              -- prefix character (optional, always 'g')
    cmdchar = "",              -- command character
    nchar = "",                -- next command character (optional)
    ncharC1 = "",              -- first composing character (optional) 
    ncharC2 = "",              -- second composing character (optional)
    extrachar = "",            -- yet another character (optional) 
    opcount = 0,               -- count before an operator
    count1 = 0,                -- count before command, default 0
    count2 = 0,                -- count before command, default 1
    arg = "",                  -- extra argument from nv_cmds[]
    retval = nil,              -- return: CA_* values
    searchbuf = {},            -- return: pointer to search pattern or NULL
    origPos = nil              -- pos in document before execution
  }
  return cmd
end

-- doesn't validate cmd, call validateAndExecute if not sure
cmds.execute = function(cmd, cmdReps, editor, motionReps, linewise, doMotion)
  if doMotion then 
    if cmd.arg == "" and cmds.motions.needArgs[cmd.nchar] then 
      cmds.motions.requireNextChar = true 
      return false 
    end
  end
  if not isModeVisual(editMode) then 
    cmd.origPos = editor:GetCurrentPos() 
  else
    cmd.origPos = selectionAnchor  
  end
  editor:BeginUndoAction()
  local iters = math.max(cmdReps, 1)
  local final = false
  for i = 1, iters do
    if doMotion then cmds.motions[cmd.nchar](editor, motionReps) end
    if i == iters then
      cmds.operators[cmd.cmdchar](editor, linewise)
    end
  end
  editor:EndUndoAction()
end

cmds.cmdNeedsSecondChar = function(cmdKey)
  if isModeVisual(editMode) then return false end
  return cmdKey == "c" or cmdKey == "d" or cmdKey == "z" or
         cmdKey == "y" or cmdKey == "f" or cmdKey == "F" or
         cmdKey == "i"
end

-- these commands treat numbers as chars, so check with this
cmds.cmdTakesNumberAsChar = function(cmdKey)
  return cmdKey == "f" or cmdKey == "F" or cmdKey == "m" or cmdKey == "'"
end

-- called from key event, calls execute when cmd has valid structure
cmds.validateAndExecute = function(editor, cmd)
  if cmd.cmdchar ~= "" then 
    if cmd.nchar == "" then
      if cmds.motions[cmd.cmdchar] and cmd.cmdchar ~= "i" then
        if cmds.motions.needArgs[cmd.cmdchar] and cmd.arg == "" then 
          cmds.motions.requireNextChar = true 
          return false 
        end
        cmds.motions.execute(cmd.cmdchar, editor, math.max(1, cmd.count1))
        return true
      --is not motion
      elseif not cmds.cmdNeedsSecondChar(cmd.cmdchar) or isModeVisual(editMode)
                or cmd.cmdchar == "i" then
        if cmds.operators[cmd.cmdchar] then
          cmds.execute(cmd, cmd.count1, editor, nil, false, false)
        else
          _DBG("Performed from command table!")
          cmds.general.execute(cmd.prechar .. cmd.cmdchar, editor, cmd.count1)
        end
        return true
      end
    else
      -- we have an operator and a 2nd char eg motion or linewise (dd, cc)
      if cmds.operators[cmd.cmdchar] then
        -- check if marker or find cmd 
        if cmds.motions.needArgs[cmd.cmdchar] then
          cmds.execute(cmd, cmd.count1, editor, nil, false, false)
          return true
        elseif cmds.motions[cmd.nchar] then
          if cmds.motions.needArgs[cmd.nchar] and cmd.arg == "" then
            cmds.motions.requireNextChar = true 
            return false
          end
          cmds.execute(cmd, cmd.count1, editor, math.max(cmd.count2, 1), false, true)
          return true
        else
          if cmd.nchar == cmd.cmdchar then
            cmds.execute(cmd, cmd.count1, editor, nil, true, false)
            return true
          end
        end
      end
      cmds.general.execute(cmd.prechar .. cmd.cmdchar .. cmd.nchar, editor, cmd.count1)
      return true
    end
  end
    
  return false
end

----------------------------------------------------------------------------------------------------
cmds.cmdLine = {
    ["w"]       = function(ed) ide:GetDocument(ed):Save() end,
    ["q"]       = function(ed) ide:GetDocument(ed):Close() end
}

cmds.cmdLine.execute = function(editor)
  for i = 1, #cmd.cmdchar do
    if cmds.cmdLine[cmd.cmdchar:sub(i,i)] then
      cmds.cmdLine[cmd.cmdchar:sub(i,i)](editor)
    end
  end
end

----------------------------------------------------------------------------------------------------
cmds.motions = {
  ["PGUP"]    = function(ed, reps) callExtendableFunc(ed, "PageUp"  , reps) end,
  ["d+Ctrl"]  = function(ed, reps) callExtendableFunc(ed, "PageUp"  , reps) end,
  ["PGDOWN"]  = function(ed, reps) callExtendableFunc(ed, "PageDown", reps) end,
  ["f+Ctrl"]  = function(ed, reps) callExtendableFunc(ed, "PageDown", reps) end,
  ["}"]       = function(ed, reps) cmds.motions.execute("DOWN", ed)
                                   callExtendableFunc(ed, "ParaDown", reps) 
                                   cmds.motions.execute("UP", ed)
                                   end,
  ["{"]       = function(ed, reps) callExtendableFunc(ed, "ParaUp"   , reps) 
                                cmds.motions.execute("UP", ed) end,
  ["END"]     = function(ed, reps) callExtendableFunc(ed, "LineEnd"  , reps) end,
  ["$"]       = function(ed, reps) callExtendableFunc(ed, "LineEnd"  , reps) end,
  ["HOME"]    = function(ed, reps) callExtendableFunc(ed, "Home"     , reps) end,
  ["0"]       = function(ed, reps) callExtendableFunc(ed, "Home"     , reps) end,
  ["^"]       = function(ed, reps) callExtendableFunc(ed, "VCHome"   , reps) end,
  ["b"]       = function(ed, reps) callExtendableFunc(ed, "WordLeft" , reps) end,
  ["w"]       = function(ed, reps) callExtendableFunc(ed, "WordRight", reps) end,
  ["h"]       = function(ed, reps) callExtendableFunc(ed, "CharLeft" , reps, true) end, 
  ["BS"]      = function(ed, reps) callExtendableFunc(ed, "CharLeft" , reps, true) end,
  ["LEFT"]    = function(ed, reps) callExtendableFunc(ed, "CharLeft" , reps, true) end,
  ["j"]       = function(ed, reps) callExtendableFunc(ed, "LineDown" , reps, true) end,
  ["DOWN"]    = function(ed, reps) callExtendableFunc(ed, "LineDown" , reps, true) end,
  ["k"]       = function(ed, reps) callExtendableFunc(ed, "LineUp"   , reps, true) end,
  ["UP"]      = function(ed, reps) callExtendableFunc(ed, "LineUp"   , reps, true) end,
  ["l"]       = function(ed, reps) callExtendableFunc(ed, "CharRight" ,reps, true) end, 
  ["RIGHT"]   = function(ed, reps) callExtendableFunc(ed, "CharRight" ,reps, true) end,
  ["f"]       = function(ed, reps) searchForAndGoto(ed, cmd.arg, reps, false) end,
  ["F"]       = function(ed, reps) searchForAndGoto(ed, cmd.arg, reps, true) end,
  ["m"]       = function(ed, reps) if cmd.arg == "'" then return end -- ' is special marker
                                   if cmd.arg == "#" then ed:MarkerDeleteAll(86) return end
                                   local pos = ed:GetCurrentPos()
                                   markers[cmd.arg] = ed:MarkerAdd(ed:LineFromPosition(pos), 86) 
                                   ed:MarkerDefine(86, wxstc.wxSTC_MARK_DOTDOTDOT) end,
  ["'"]       = function(ed, reps) if cmd.arg == "'" or markers[cmd.arg] == nil then return end
                                   local line = ed:MarkerLineFromHandle(markers[cmd.arg])
                                   gotoPosition(ed, ed:PositionFromLine(line)) end,
  ["i"]       = function(ed, reps) local m = match[cmd.arg] ; local left, right
                                   left = m and m.left or cmd.arg
                                   right = m and m.right or cmd.arg                            
                                   cmd.origPos = find(ed, left, true) + 1
                                   local dest = find(ed, right, false)
                                   gotoPosition(ed, dest) -- TODO: make 'i' motion work with visual mode
                                   cmd.keepSpaces = true
                                   end
}

cmds.motions.needArgs = {
  ["f"] = true, ["F"] = true, ["m"] = true, ["'"] = true, ["i"] = true
}

-- this is checked for in onEditorKeyDown - cmd.arg gets the next char
-- when true
cmds.motions.requireNextChar = false

cmds.motions.execute = function(motion, ed, reps) 
  if cmds.motions.needArgs[motion] then
    if cmd.arg == "" then 
      cmds.motions.requireNextChar = true
      return false
    end
  end
  ed:BeginUndoAction()
  cmds.motions[motion](ed, reps)
  setBlockCaret(ed)
  ed:EndUndoAction()
end

----------------------------------------------------------------------------------------------------

cmds.operators = {
  ["d"]  = function(ed, linewise) setCmdSelection(ed, cmd, true, linewise)
                                  ed:Cut() cancelSelection(ed) ; end,
  ["c"]  = function(ed, linewise) setCmdSelection(ed, cmd, true, linewise)
                                  ed:Cut() 
                                  if linewise then
                                    cmds.general.execute("O", ed, 1)
                                  else 
                                    setMode(kEditMode.insert) 
                                  end ; end,
  ["y"]  = function(ed, linewise) setCmdSelection(ed, cmd, true, linewise)
                                  ed:Copy() cancelSelection(ed) ; end,
  ["x"]  = function(ed, linewise) setCmdSelection(ed, cmd, true, linewise)
                                  ed:Cut() ; cancelSelection(ed) ; end,
}  

----------------------------------------------------------------------------------------------------
cmds.general = {
  ["v"]      = function(ed, num) setMode(kEditMode.visual, false) end,
  ["V"]      = function(ed, num) setMode(kEditMode.visualLine, false) end,
  ["v+Ctrl"] = function(ed, num) setMode(kEditMode.visualBlock, false) end,
  ["i"]      = function(ed, num) setMode(kEditMode.insert, false) end,
  ["I"]      = function(ed, num) ed:Home() ; setMode(kEditMode.insert, false) end,
  ["a"]      = function(ed, num) setMode(kEditMode.insert, false) end,
  ["A"]      = function(ed, num) ed:LineEnd() ; setMode(kEditMode.insert, false) end,
  ["R"]      = function(ed, num) setMode(kEditMode.insert, true) end,
  ["gg"]     = function(ed, num) callExtendableFunc(ed, "DocumentStart", 1) end,
  ["gt"]     = function(ed, num) ide.frame:AddPendingEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED,
                                  ID.NOTEBOOKTABNEXT)) end,
  ["gT"]     = function(ed, num) ide.frame:AddPendingEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED,
                                  ID.NOTEBOOKTABPREV)) end,
  ["G"]      = function(ed, num) if num > 0 then
                                   gotoPosition(ed, ed:PositionFromLine(num - 1))
                                 else
                                   callExtendableFunc(ed, "DocumentEnd", 1)
                                 end ; end,
  ["o"]      = function(ed, num) ed:InsertText(ed:GetLineEndPosition(ed:GetCurrentLine()), "\13\10") 
                                 ed:LineDown() ; setMode(kEditMode.insert, false) ; end,
  ["O"]      = function(ed, num) ed:LineUp()
                                 ed:InsertText(ed:GetLineEndPosition(ed:GetCurrentLine()), "\13\10") 
                                 ed:LineDown() ; setMode(kEditMode.insert, false) ; end,
  ["Y"]      = function(ed, num) cmd.cmdchar = "y"
                                 cmds.execute(cmd, num, ed, nil, true, false) end,
  ["p"]      = function(ed, num) for i=1, math.min(math.max(num, 1), _MAX_REPS) do 
                                   ed:Paste() 
                                 end ; end,
  ["u"]      = function(ed, num) for i=1, math.max(num, 1) do ed:Undo() end ; end,
  ["zz"]     = function(ed, num) ed:VerticalCentreCaret() end,
  ["z."]     = function(ed, num) ed:VerticalCentreCaret() end,
  ["zt"]     = function(ed, num) ed:SetFirstVisibleLine(ed:GetCurrentLine()) ; end,
  ["zb"]     = function(ed, num) local pos = ed:GetCurrentLine() - ed:LinesOnScreen() + 1
                                 ed:SetFirstVisibleLine(math.max(0, pos)) ; end,
  ["r+Ctrl"] = function(ed, num) ed:Redo() end,
  ["."]      = function(ed, num) if cmdLast ~= nil then
                                   cmd = cmdLast
                                   cmds.validateAndExecute(ed, cmd)
                                 end ; end,
  ["DEL"]    = function(ed, num) if hasSelection(ed) then ed:Cut() else pos = ed:GetCurrentPos()
                                 ed:DeleteRange(pos, math.min(math.max(num, 1), _MAX_REPS)) end end,
  ["x"]      = function(ed, num) if hasSelection(ed) then ed:Cut() else pos = ed:GetCurrentPos()
                                 ed:DeleteRange(pos, math.min(math.max(num, 1), _MAX_REPS)) end end,
  ["#"]      = function(ed, num) openRealVim(ed) end,
}

cmds.general.execute = function(key, editor, num)
  local retVal
  if cmds.general[key] ~= nil then
    editor:BeginUndoAction()
    retVal = cmds.general[key](editor, num)
    editor:EndUndoAction()
  end
  -- retVal could be nil, false or true so
  return (retVal == true and true or false)
end

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------
local function _DBGCMD()
  _DBG("Edit mode: ", editMode)
  _DBG("cmd.prechar: ", "'" ..cmd.prechar .."'")
  _DBG("cmd.count1: ", cmd.count1)
  _DBG("cmd.cmdchar: ", "'".. cmd.cmdchar .. "'")
  _DBG("cmd.count2: ", cmd.count2)
  _DBG("cmd.nchar: ", "'" .. cmd.nchar .. "'")
  _DBG("cmd.arg: ", "'" .. cmd.arg .. "'")
  _DBG("------------------------------------------")
end
  
function resetCmd()
  cmdLast = shallowcopy(cmd)
  cmd = cmds.newCommand()
end

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------
-- implement returned plugin object inc event handlers here
local plugin = {
  name = "Vim",
  description = "Vim-like editing for ZBS.",
  author = "Paul Reilly",
  version = "0.52",
  dependencies = "1.61",
  
----------------------------------------------------------------------------------------------------
  onRegister = function(self)
    setMode(kEditMode.insert)
    cmd = cmds.newCommand()
    ide:SetStatus("Press 'Escape' to enter Vim editing mode")
    _DBG(os.setlocale(nil))
  end,

----------------------------------------------------------------------------------------------------
  onEditorKeyDown = function(self, editor, event)
    curEditor = editor
    local key =  tostring(event:GetKeyCode())
    local keyNum = tonumber(key)
    
    key = keymap.keyNumToChar(keyNum)
    
    if cmds.motions.requireNextChar and not keymap.isKeyModifier(keyNum) then
      cmds.motions.requireNextChar = false
      if keyNum == 27 then resetCmd() return false end
      cmd.arg = tostring(key)
      _DBGCMD()
      if cmds.validateAndExecute(editor, cmd) then 
        resetCmd()
      end
      return false
    end
    
    if editMode == kEditMode.insert then
      if keyNum == 27 then 
        setMode(kEditMode.normal)
        cmd = cmds.newCommand()
        return false
      else
        -- in insert mode always pass keys to editor
        return true
      end
    else 
      -- not insert mode, check for colon to enter command line mode
      if editMode ~= kEditMode.commandLine and keyNum == 59 and wx.wxGetKeyState(wx.WXK_SHIFT) then
        setMode(kEditMode.commandLine)
        ide:SetStatus(":")
        -- don't use resetCmd here because we don't 
        -- want to lose last cmd
        cmd = cmds.newCommand(); 
        cmd.cmdchar = ":"
        return false
      end
    end

    if keymap.isKeyModifier(keyNum) then return false end   

    ------------------------------------------------------------------------------------------------
    --         Command Line Mode        
    if editMode == kEditMode.commandLine then
      if keyNum == 13 then
        setMode(kEditMode.normal)
        cmds.cmdLine.execute(editor)
        resetCmd()
        return false
        -- add to current command
      elseif key == "BS" then
        if #cmd.cmdchar > 1 then
          cmd.cmdchar = cmd.cmdchar:sub(1, cmd.cmdchar - 1)
          ide:SetStatus(cmd.cmdchar)
        else
          setMode(kEditMode.normal)
        end
      elseif keyNum == 27 then
        setMode(kEditMode.normal)
      else
        cmd.cmdchar = cmd.cmdchar .. key
        ide:SetStatus(cmd.cmdchar)
      end
      return false
    end

    ------------------------------------------------------------------------------------------------
    -- not command line, remap key if required
    if keymap.user[key] then key = keymap.user[key] end
    
    ------------------------------------------------------------------------------------------------
    --    Normal/Visual Modes 
    if keyNum == 27 then setMode(kEditMode.normal) ; cmd = cmds.newCommand() return false end
  
    -- handle numbers
    if tonumber(key) and tonumber(key) < 10 then
      local processAsChar = false
      if cmd.cmdchar == "" then
        -- lone zero is line start command
        if cmd.count1 == 0 and tonumber(key) == 0 then
          cmds.motions["HOME"](editor)
          resetCmd()
          return false
        else
          cmd.count1 = cmd.count1 * 10 + tonumber(key)
        end
      else
        -- we already have a command letter
        if (cmd.count2 == 0 and tonumber(key) == 0) then
          -- zero after command means home
          key = "0"
          processAsChar = true
        elseif cmd.count2 == 0 and cmds.cmdTakesNumberAsChar(cmd.cmdchar) then
          -- any number after these commands is treated r
          key = tostring(key)
          processAsChar = true
        else
          cmd.count2 = cmd.count2 * 10 + tonumber(key)
        end
      end
      if not processAsChar then return false end
    end
    -- process chars
    if cmd.cmdchar == "" then 
      if key == 'g' then 
        if cmd.prechar == "" then 
          cmd.prechar = key
        else
          cmd.cmdchar = key
        end
      else
        cmd.cmdchar = key 
      end
    else
      cmd.nchar = key
    end
    _DBGCMD()
    if cmds.validateAndExecute(editor, cmd) then 
      resetCmd()
    end
    
    return false
    ------------------------------------------------------------------------------------------------
  end,
  
  -- caret setting is per document/editor, but our Vim mode is global
  -- so handle events to make sure carets match when switching etc
  onEditorLoad = function(self, editor) setCaret(editor) end,
  onEditorNew = function(self, editor) setCaret(editor) end,
  onEditorFocusSet = function(self, editor) setCaret(editor) end
}

function _DBG(...)
  if DEBUG then 
    local msg = "" for k,v in ipairs{...} do msg = msg .. tostring(v) .. "\t" end ide:Print(msg)
  end
end

return plugin
