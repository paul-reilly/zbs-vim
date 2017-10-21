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
--                $, ^, 0, gg, gt, gT, z., zz, zt, zb, d^, d0, d$, c^, c0, c$
--                i, I, a, A (not stored in buffers for repeating)
--                # - opens current document in real instance of Vim
--   
--         visual mode:
--                y, x, c
--   
--         command line mode:
--                w, q
--   
--   
--         '-' remapped as '$' so '0' = HOME, '-' = END
--   
--   
----------------------------------------------------------------------------------------------------
local DEBUG = true
local _DBG -- for console output, definition at EOF

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

keymap.sys = {["8"] = "BS",     ["9"] = "TAB",     ["92"]  = "\\",   ["127"] = "DEL",     
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
  { sc = "Ctrl+r", action = function() curEditor:Redo() end,                             id = nil },
  { sc = "Ctrl+v", action = function() cmds.general.execute("v+Ctrl", curEditor, false) end, id = nil }
}

keymap.overrideHotKeys = function(setNotRestore)
  --if true then return end
  if setNotRestore then
    for k, v in pairs(keymap.hotKeysToOverride) do
      local sc
      if v.id == nil then v.id, sc = ide:GetHotKey(v.sc) end
      local ret = ide:SetHotKey(v.action, v.sc)
      if ret == nil then ide:Print("Cannot set shortcut ".. v.sc) end
    end
  else
    for k, v in pairs(keymap.hotKeysToOverride) do
      local ret = ide:SetHotKey(v.id, v.sc)
      if ret == nil then ide:Print("Cannot set shortcut ".. v.sc) end
    end
  end
end

----------------------------------------------------------------------------------------------------
-- visualBlock and visualLine are not very useful at the moment
local kEditMode = { normal = "Normal", visual = "Visual", visualBlock = "Visual - Block", 
                    visualLine = "Visual - Line", insert = "Insert - ZeroBrane", 
                    commandLine = "Command Line" }

-- for the Lua equivalent of brace matching with 'end's at some point
local luaSectionKeywords = { ["local function"] = "local function", ["function"] = "function", 
                             ["while"] = "while", ["for"] = "for", ["if"] = "if", 
                             ["repeat"] = "repeat" }

-- forward declarations of function variables
local hasSelection
local setCaret
local cmds -- table

local editMode = nil
-- bound repetitions of some functions to this value
-- to avoid pasting stuff 100,000 times or whatever
local _MAX_REPS = 50 
local curEditor, curNumber, curCommand, lastNumber, lastCommand = nil, 0, "", 0, ""
local selectionAnchor = 0

local cmd -- initialised in onRegister
local cmdLast

----------------------------------------------------------------------------------------------------
local function resetCurrentVars()
  curNumber = 0
  curCommand = ""
end

function table.clone(org)
  return {table.unpack(org)}
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
  if isModeVisual(mode) and isModeVisual(editMode) then
    editMode = kEditMode.normal
    curEditor:SetEmptySelection(curEditor:GetCurrentPos())
    selectionAnchor = nil
  else
    if isModeVisual(mode) then
      selectionAnchor = curEditor:GetCurrentPos()
      curEditor:SetAnchor(curEditor:GetCurrentPos())
      if mode == kEditMode.visualBlock then 
        -- this works with mulitple selections
        local pos = curEditor:GetCurrentPos()
        curEditor:SetSelectionStart(origPos)
        curEditor:SetSelectionMode(wxstc.wxSTC_SEL_RECTANGLE)
        curEditor:SetRectangularSelectionAnchor(0)
        curEditor:SetRectangularSelectionCaret(pos)
      elseif mode == kEditMode.visual then curEditor:SetSelectionMode(wxstc.wxSTC_SEL_STREAM)
      elseif mode == kEditMode.visualLine then curEditor:SetSelectionMode(wxstc.wxSTC_SEL_LINES)
      end
    else
      selectionAnchor = nil
    end
    editMode = mode
    if editMode == kEditMode.normal then curEditor:SetEmptySelection(curEditor:GetCurrentPos()) end
  end
  ide:SetStatus("Vim mode: "..mode)
  setCaret(curEditor)
  curEditor:SetOvertype(overtype)
  cmd.origPos = curEditor:GetCurrentPos()
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
local function callExtendableFunc(obj, name, reps)
  cmd.origPos = curEditor:GetCurrentPos()
  extend = isModeVisual(editMode) and "Extend" or ""
  reps = reps ~= nil and reps or math.max(curNumber, 1)
  for i = 1, reps do
    obj[name .. extend](obj)
  end
end

local function normOrVisFunc(obj, norm, vis)
  if editMode == kEditMode.visual then
    obj[vis](obj)
  else
    local reps = math.max(curNumber, 1)
    for i = 1, reps do
      obj[norm](obj)
    end
  end
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
    while char == 32 do
      ed:SetSelectionEnd(ed:GetSelectionEnd() - 1)
      char = ed:GetCharAt(ed:GetSelectionEnd() - 1)
    end
  end
end

local function gotoPosition(ed, pos)
  if isModeVisual(editMode) then
    setSelectionFromPositions(ed, selectionAnchor, pos)
    ed:SetCurrentPos(pos)
  else
    ed:GotoPos(pos)
  end
end

-- uses wxSTC_FIND_.. constants 
local function searchForAndGoto(ed, text, nth, searchBackwards, redo)
  local extend = isModeVisual(editMode)
  local flags = wxstc.wxSTC_FIND_MATCHCASE -- wxstc.wxSTC_FIND_WHOLEWORD  
  minPos = redo == nil and ed:GetCurrentPos() or redo
  local maxPos = searchBackwards and 0 or ed:GetLength()
  local pos = ed:FindText(minPos, maxPos, text, flags)
  if pos ~= wxstc.wxSTC_INVALID_POSITION then
    if pos == minPos then 
      -- we're already at the beginning of the text, search again from after text
      if redo == nil then 
        searchForAndGoto(ed, text, nth, searchBackwards, minPos + #text)
        return 
      end
    end
    gotoPosition(ed, pos)
  end
  if nth > 1 then 
    nth = nth - 1
    searchForAndGoto(ed, text, nth, searchBackwards)
  end
end

function hasSelection(editor)
  return (editor:GetSelectionStart() ~= editor:GetSelectionEnd())
end

local function cancelSelection(ed)
  ed:SetEmptySelection(ed:GetCurrentPos())
  setMode(kEditMode.normal)
end

local function restoreCaretPos(ed, cmd)
  if cmd.origPos ~= nil then
    ed:SetCurrentPos(cmd.origPos)
  end
end

----------------------------------------------------------------------------------------------------
-- vim commands and logic
----------------------------------------------------------------------------------------------------
cmds = {}

-- rough copy of cmd structure used by neovim to keep things extendable
cmds.newCommand = function(searchbuf)
  local cmd = {
    opargs = nil,            -- operator arguments
    prechar = "",            -- prefix character (optional, always 'g')
    cmdchar = "",            -- command character
    nchar = "",              -- next command character (optional)
    ncharC1 = "",            -- first composing character (optional) 
    ncharC2 = "",            -- second composing character (optional)
    extrachar = "",          -- yet another character (optional) 
    opcount = 0,             -- count before an operator
    count1 = 0,              -- count before command, default 0
    count2 = 0,              -- count before command, default 1
    arg = "",                -- extra argument from nv_cmds[]
    retval = nil,            -- return: CA_* values
    searchbuf = {},          -- return: pointer to search pattern or NULL
    origPos = nil            -- pos in document before execution
  }
  return cmd
end

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
         cmdKey == "x"
end

-- these commands treat numbers as chars, so check with this
cmds.cmdTakesNumberAsChar = function(cmdKey)
  return cmdKey == "f" or cmdKey == "F"
end

-- called from key event, executes on when cmd has valid structure
cmds.validateAndExecute = function(editor, cmd)
  if cmd.cmdchar ~= "" then
    curNumber = cmd.count1
    if cmd.nchar == "" then
      if cmds.motions[cmd.cmdchar] then
        if cmds.motions.needArgs[cmd.cmdchar] and cmd.arg == "" then 
          cmds.motions.requireNextChar = true 
          return false 
        end
        cmds.motions.execute(cmd.cmdchar, editor, math.max(1, cmd.count1))
        return true
      --is not motion
      elseif not cmds.cmdNeedsSecondChar(cmd.cmdchar) or isModeVisual(editMode) then
        if cmds.operators[cmd.cmdchar] then
          cmds.execute(cmd, curNumber, editor, nil, false, false)
        else
          _DBG("Performed from command table!")
          cmds.general.execute(cmd.prechar .. cmd.cmdchar, editor)
        end
        return true
      end
    else
      -- we have an operator and a 2nd char eg motion or linewise (dd, cc)
      if cmds.operators[cmd.cmdchar] then
        -- check if marker or find cmd 
        if cmds.motions.needArgs[cmd.cmdchar] then
          cmds.execute(cmd, curNumber, editor, nil, false, false)
          return true
        elseif cmds.motions[cmd.nchar] then
          cmds.execute(cmd, curNumber, editor, math.max(cmd.count2, 1), false, true)
          return true
        else
          if cmd.nchar == cmd.cmdchar then
            cmds.execute(cmd, curNumber, editor, nil, true, false)
            return true
          end
        end
      end
      _DBG("Performed from command table.")
      cmds.general.execute(cmd.prechar .. cmd.cmdchar .. cmd.nchar, editor)
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
  for i = 1, #curCommand do
    if cmds.cmdLine[curCommand:sub(i,i)] then
      cmds.cmdLine[curCommand:sub(i,i)](editor)
    end
  end
  resetCurrentVars()
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
  ["h"]       = function(ed, reps) callExtendableFunc(ed, "CharLeft" , reps) end,
  ["BS"]      = function(ed, reps) callExtendableFunc(ed, "CharLeft" , reps) end, 
  ["LEFT"]    = function(ed, reps) callExtendableFunc(ed, "CharLeft" , reps) end, 
  ["j"]       = function(ed, reps) callExtendableFunc(ed, "LineDown" , reps) end,
  ["DOWN"]    = function(ed, reps) callExtendableFunc(ed, "LineDown" , reps) end,
  ["k"]       = function(ed, reps) callExtendableFunc(ed, "LineUp"   , reps) end,
  ["UP"]      = function(ed, reps) callExtendableFunc(ed, "LineUp"   , reps) end,
  ["l"]       = function(ed, reps) callExtendableFunc(ed, "CharRight", reps) end,
  ["RIGHT"]   = function(ed, reps) callExtendableFunc(ed, "CharRight", reps) end,
  ["f"]       = function(ed, reps) searchForAndGoto(ed, cmd.arg, reps, false) end,
  ["F"]       = function(ed, reps) searchForAndGoto(ed, cmd.arg, reps, true) end
}

cmds.motions.needArgs = {
  ["f"] = true, ["F"] = true, ["m"] = true, ["'"] = true
}

-- this is checked for in onEditorKeyDown and cmd.arg gets the next char
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
  ed:EndUndoAction()
end

----------------------------------------------------------------------------------------------------

cmds.operators = {
  ["d"]  = function(ed, linewise) setCmdSelection(ed, cmd, true, linewise)
                                  ed:Cut() cancelSelection(ed) 
                                  end,
  ["c"]  = function(ed, linewise) setCmdSelection(ed, cmd, true, linewise)
                                  ed:Cut() 
                                  if linewise then
                                    cmds.general.execute("O", ed)
                                  else 
                                    setMode(kEditMode.insert) 
                                  end ; end,
  ["y"]  = function(ed, linewise) setCmdSelection(ed, cmd, true, linewise)
                                  ed:Copy() cancelSelection(ed) end,
  ["x"]  = function(ed, linewise) setCmdSelection(ed, cmd, true, linewise)
                                         ed:Cut() ; cancelSelection(ed) end,
}  

----------------------------------------------------------------------------------------------------
cmds.general = { 
  ["v"]      = function(ed) setMode(kEditMode.visual, false) end,
  ["V"]      = function(ed) setMode(kEditMode.visualLine, false) end,
  ["v+Ctrl"] = function(ed) setMode(kEditMode.visualBlock, false) end,
  ["i"]      = function(ed) setMode(kEditMode.insert, false) end,
  ["I"]      = function(ed) ed:Home() ; setMode(kEditMode.insert, false) end,
  ["a"]      = function(ed) setMode(kEditMode.insert, false) end,
  ["A"]      = function(ed) ed:LineEnd() ; setMode(kEditMode.insert, false) end,
  ["R"]      = function(ed) setMode(kEditMode.insert, true) end,
  ["gg"]     = function(ed) callExtendableFunc(ed, "DocumentStart") end,
  ["gt"]     = function(ed) ide.frame:AddPendingEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED,
                              ID.NOTEBOOKTABNEXT)) end,
  ["gT"]     = function(ed) ide.frame:AddPendingEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED,
                              ID.NOTEBOOKTABPREV)) end,
  ["G"]      = function(ed) if curNumber > 0 then
                              gotoPosition(ed, ed:PositionFromLine(curNumber - 1))
                            else
                              callExtendableFunc(ed, "DocumentEnd")
                            end ; end,
  ["x"]      = function(ed) normOrVisFunc(ed, "DeleteBack", "Cut") end,
  ["o"]      = function(ed) ed:InsertText(ed:GetLineEndPosition(ed:GetCurrentLine()), "\13\10") 
                            ed:LineDown() ; setMode(kEditMode.insert, false) ; end,
  ["O"]      = function(ed) ed:LineUp()
                            ed:InsertText(ed:GetLineEndPosition(ed:GetCurrentLine()), "\13\10") 
                            ed:LineDown() ; setMode(kEditMode.insert, false) ; end,
  ["Y"]      = function(ed) cmd.cmdchar = "y"
                            cmds.execute(cmd, curNumber, ed, nil, true, false) end,
  ["p"]      = function(ed) for i=1, math.min(math.max(curNumber, 1), _MAX_REPS) do 
                              ed:Paste() 
                            end ; end,
  ["u"]      = function(ed) for i=1, math.max(curNumber, 1) do ed:Undo() end ; end,
  ["zz"]     = function(ed) ed:VerticalCentreCaret() end,
  ["z."]     = function(ed) ed:VerticalCentreCaret() end,
  ["zt"]     = function(ed) ed:SetFirstVisibleLine(ed:GetCurrentLine()) ; end,
  ["zb"]     = function(ed) local pos = ed:GetCurrentLine() - ed:LinesOnScreen() + 1
                            ed:SetFirstVisibleLine(math.max(0, pos)) ; end,
  ["r+Ctrl"] = function(ed) ed:Redo() end,
  ["."]      = function(ed) curNumber = lastNumber ; cmd = cmdLast ; 
                            cmds.validateAndExecute(ed, cmd) end,
  ["DEL"]    = function(ed) local pos = ed:GetCurrentPos()
                            ed:DeleteRange(pos, math.min(math.max(curNumber, 1), _MAX_REPS)) end,
  ["#"]      = function(ed) openRealVim(ed) end,
  ["Q"]      = function(ed) ed:SetRectangularSelectionCaret(ed:GetCurrentPos()+1) end
}

cmds.general.execute = function(key, editor)
  local retVal
  if cmds.general[key] ~= nil then
    editor:BeginUndoAction()
    retVal = cmds.general[key](editor)
    editor:EndUndoAction()
    if key ~= "." then
      lastNumber = curNumber
      lastCommand = key
    end
  end
  resetCurrentVars()
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
  
----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------
-- implement returned plugin object inc event handlers here
local plugin = {
  name = "Vim",
  description = "Vim-like editing for ZBS.",
  author = "Paul Reilly",
  version = "0.3",
  dependencies = "1.61",
  
----------------------------------------------------------------------------------------------------
  onRegister = function(self)
    setMode(kEditMode.insert)
    -- currently need to override ZBS shortcuts here
    --origCtrlReg = 
    --ide:SetHotKey(function() curEditor:Redo() end, "Ctrl+R")
    cmd = cmds.newCommand()
    ide:SetStatus("Press 'Escape' to enter Vim editing mode")
  end,

----------------------------------------------------------------------------------------------------
  onEditorKeyDown = function(self, editor, event)
    curEditor = editor
    local key =  tostring(event:GetKeyCode())
    local keyNum = tonumber(key)
    
    key = keymap.keyNumToChar(keyNum)
    
    if cmds.motions.requireNextChar and not keymap.isKeyModifier(keyNum) then 
      cmd.arg = tostring(key)
      cmds.motions.requireNextChar = false
      _DBGCMD()
      if cmds.validateAndExecute(editor, cmd) then 
        cmdLast = table.clone(cmd)
        cmd = cmds.newCommand()
      end
      return false
    end
    
    if editMode == kEditMode.insert then
      if keyNum == 27 then 
        setMode(kEditMode.normal)
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
        resetCurrentVars()
        curCommand = ":"
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
        -- add to current command
      elseif key == "BS" then
        if #curCommand > 1 then
          curCommand = curCommand:sub(1, #curCommand - 1)
          ide:SetStatus(curCommand)
        else
          setMode(kEditMode.normal)
        end
      elseif keyNum == 27 then
        resetCurrentVars()
        setMode(kEditMode.normal)
      else
        curCommand = curCommand .. key
        ide:SetStatus(curCommand)
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
          cmd = cmds.newCommand()
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
      cmdLast = table.clone(cmd)
      cmd = cmds.newCommand()
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
