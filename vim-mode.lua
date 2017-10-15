--         MIT Copyright 2017 Paul Reilly (https://opensource.org/licenses/MIT)
--
--
--  ::::::::: :::::::::   ::::::::                :::     ::: ::::::::::: ::::    ::::  
--       :+:  :+:    :+: :+:    :+:               :+:     :+:     :+:     +:+:+: :+:+:+ 
--      +:+   +:+    +:+ +:+                      +:+     +:+     +:+     +:+ +:+:+ +:+ 
--     +#+    +#++:++#+  +#++:++#++ +#++:++#++:++ +#+     +:+     +#+     +#+  +:+  +#+ 
--    +#+     +#+    +#+        +#+                +#+   +#+      +#+     +#+       +#+ 
--   #+#      #+#    #+# #+#    #+#                 #+#+#+#       #+#     #+#       #+# 
--  ######### #########   ########                    ###     ########### ###       ### 
-- 
--               zbs-vim adds a useful subset of Vim-like editing to ZBS
--                  and the ability to open current document in Vim
--
--                                     Commands
--                                     --------
--
--      normal mode:
--             [num]h, j, k, l, yy, G, dd, dw, db, cc, cw, cb, x, b, w, p
--             $, ^, 0, gg, gt, gT, z., zz, zt, zb, d^, d0, d$, c^, c0, c$
--             i, I, a, A (not stored in buffers for repeating)
--             # - opens current document in real instance of Vim
--
--      visual mode:
--             y, x, c
--
--      command line mode:
--             w, q
--
--
--      '-' remapped as '$' so '0' = HOME, '-' = END
--
-----------------------------------------------------------------------------------------------------
local DEBUG = false

local function _DBG(...)
  if DEBUG then 
    local msg = "" ; for k,v in ipairs{...} do ; msg = msg .. tostring(v) .. "\t" ; end ; ide:Print(msg)
  end
end

-- remap any keys you want here
local keyRemap = { ["-"] = "$" }             

-- Table mapping number keys to their shifted characters. You might need to edit this to suit
-- your locale
local shiftMap = {["0"] = ")", ["1"] = "!", ["2"]  = "\"", ["3"] = "£", ["4"] = "$", 
                  ["5"] = "%", ["6"] = "^", ["7"]  = "&" , ["8"] = "*", ["9"] = "(",
                  [";"] = ":", ["'"] = "@", ["#"]  = "~" , ["["] = "{", ["]"] = "}",
                  ["-"] = "_", ["="] = "+", ["\\"] = "|" , [","] = "<", ["."] = ">",
                  ["/"] = "?"
}

local keyMap = {["8"] = "BS",     ["9"] = "TAB",    ["92"]  = "\\",   ["127"] = "DEL",     ["312"] = "END",     
                ["313"] = "HOME", ["314"] = "LEFT", ["315"] = "UP",   ["316"] = "RIGHT",   ["317"] = "DOWN",
                ["366"] = "PGUP", ["367"] = "PGDOWN"}

-- visualBlock and visualLine are not very useful at the moment
local kEditMode = { normal = "Normal", visual = "Visual", visualBlock = "Visual - Block", visualLine = "Visual - Line", 
                    insert = "Insert - ZeroBrane", commandLine = "Command Line" }

-- forward declarations of function variables
local eventKeyNumToChar
local executeCommandNormal
local executeMotion

local editMode = nil
-- bound repetitions of some functions to this value
-- to avoid pasting stuff 100,000 times or whatever
local _MAX_REPS = 50 
local curEditor, curNumber, curCommand, lastNumber, lastCommand = nil, 0, "", 0, ""

-- rough copy of cmd structure used by neovim to keep things extendable
local function newCommand(searchbuf)
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

local cmd -- initialised in onRegister
local cmdLast

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

local function setCaret(editor)
  editor:SetCaretStyle(editMode == kEditMode.insert and 1 or 2)
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
  else
    if mode == kEditMode.visualBlock then 
      -- this always jumps to line 0 for some reason
      local origPos = curEditor:GetCurrentPos()
      curEditor:SetSelectionStart(origPos)
      curEditor:SetSelectionMode(wxstc.wxSTC_SEL_RECTANGLE)
      curEditor:SetSelectionStart(origPos)
    elseif mode == kEditMode.visual then curEditor:SetSelectionMode(wxstc.wxSTC_SEL_STREAM)
    elseif mode == kEditMode.visualLine then curEditor:SetSelectionMode(wxstc.wxSTC_SEL_LINES)
    end
    editMode = mode
    if editMode == kEditMode.normal then curEditor:SetEmptySelection(curEditor:GetCurrentPos()) end

  end
  ide:SetStatus("Vim mode: "..mode)
  setCaret(curEditor)
  curEditor:SetOvertype(overtype)
end

-- some wxStyledTextCtrl methods have Extend versions
-- so this saves a bit of duplication for working
-- in visual mode
local function callExtendableFunc(obj, name, callExtend, reps)
  if callExtend ~= nil then
    extend = callExtend == true and "Extend" or ""
  else
    extend = isModeVisual(editMode) and "Extend" or ""
  end
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

-- uses wxSTC_FIND_.. constants 
local function searchForAndGoto(ed, text, searchBackwards, minPos)
  local flags = wxstc.wxSTC_FIND_WHOLEWORD
  if minPos == nil then minPos= ed:GetCurrentPos() end
  local maxPos = searchBackwards and 0 or ed:GetLength()
  local pos = ed:FindText(minPos, maxPos, text, flags)
  if pos ~= wxstc.wxSTC_INVALID_POSITION then
    if pos == minPos then 
      -- we're already at the beginning of the text, search again from after text
      searchForAndGoto(ed, text, searchBackwards, minPos + #text) 
      return 
    end
    ed:GotoPos(pos)
  end
end

local function yank(ed)
  local origPos = ed:GetCurrentPos()
  local line = ed:GetCurrentLine()
  ed:SetSelectionStart(ed:PositionFromLine(line))
  local lastLine = line + math.max(0, curNumber-1)
  --ed:SetSelectionEnd(ed:GetLineEndPosition(lastLine))
  -- GetLineEndPosition doesn't get CR/LF so do this instead
  ed:SetSelectionEnd(ed:PositionFromLine(lastLine) + ed:LineLength(lastLine))
  ed:Copy()
  ed:SetEmptySelection(origPos)
end

local function hasSelection(editor)
  return (editor:GetSelectionStart() ~= editor:GetSelectionEnd())
end

local commandsCommandLine = {
    ["w"]       = function(ed) ide:GetDocument(ed):Save() end,
    ["q"]       = function(ed) ide:GetDocument(ed):Close() end
}

local function parseAndExecuteCommandLine(editor)
  for i = 1, #curCommand do
    if commandsCommandLine[curCommand:sub(i,i)] then
      commandsCommandLine[curCommand:sub(i,i)](editor)
    end
  end
  resetCurrentVars()
end

local executeMotion

local motions = {
  ["PGUP"]    = function(ed, extend, reps) callExtendableFunc(ed, "PageUp"   ,extend, reps) end,
  ["PGDOWN"]  = function(ed, extend, reps) callExtendableFunc(ed, "PageDown" ,extend, reps) end,
  ["}"]       = function(ed, extend, reps) executeMotion("DOWN", ed, extend)
                                           callExtendableFunc(ed, "ParaDown" ,extend, reps) 
                                           executeMotion("UP", ed, extend)
                                           end,
  ["{"]       = function(ed, extend, reps) callExtendableFunc(ed, "ParaUp", extend, reps) 
                                           executeMotion("UP", ed, extend) end,
  ["END"]     = function(ed, extend, reps) callExtendableFunc(ed, "LineEnd"  ,extend, reps) end,
  ["$"]       = function(ed, extend, reps) callExtendableFunc(ed, "LineEnd"  ,extend, reps) end,
  ["HOME"]    = function(ed, extend, reps) callExtendableFunc(ed, "Home"     ,extend, reps) end,
  ["0"]       = function(ed, extend, reps) callExtendableFunc(ed, "Home"     ,extend, reps) end,
  ["^"]       = function(ed, extend, reps) callExtendableFunc(ed, "VCHome"   ,extend, reps) end,
  ["b"]       = function(ed, extend, reps) callExtendableFunc(ed, "WordLeft" ,extend, reps) end,
  ["w"]       = function(ed, extend, reps) callExtendableFunc(ed, "WordRight",extend, reps) end,
  ["h"]       = function(ed, extend, reps) callExtendableFunc(ed, "CharLeft" ,extend, reps) end,
  ["BS"]      = function(ed, extend, reps) callExtendableFunc(ed, "CharLeft" ,extend, reps) end, 
  ["LEFT"]    = function(ed, extend, reps) callExtendableFunc(ed, "CharLeft" ,extend, reps) end, 
  ["j"]       = function(ed, extend, reps) callExtendableFunc(ed, "LineDown" ,extend, reps) end,
  ["DOWN"]    = function(ed, extend, reps) callExtendableFunc(ed, "LineDown" ,extend, reps) end,
  ["k"]       = function(ed, extend, reps) callExtendableFunc(ed, "LineUp"   ,extend, reps) end,
  ["UP"]      = function(ed, extend, reps) callExtendableFunc(ed, "LineUp"   ,extend, reps) end,
  ["l"]       = function(ed, extend, reps) callExtendableFunc(ed, "CharRight",extend, reps) end,
  ["RIGHT"]   = function(ed, extend, reps) callExtendableFunc(ed, "CharRight",extend, reps) end
}

function executeMotion(motion, ed, extend, reps)
  motions[motion](ed, extend, reps)
end

local function selectCurrentLine(ed, incLineEnd)
  local line = ed:GetCurrentLine()
  local lineStart = ed:PositionFromLine(line)
  local lineEnd = incLineEnd == true and (lineStart + ed:LineLength(line)) or ed:GetLineEndPosition(line)
  if not hasSelection(ed) then 
    ed:SetSelectionStart(lineStart)
    ed:SetSelectionEnd(lineEnd)
  else
    -- extend existing selection by line
    if ed:GetSelectionStart() < lineStart then
      ed:SetSelectionEnd(lineEnd)
    else
      ed:SetSelectionStart(lineStart)
    end
  end
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

-- for change operator, to match Vim behaviour of only changing word
-- and not trailing space
local function moveCaretLeftPastSpaces(ed)
  local char = ed:GetCharAt(ed:GetCurrentPos() - 1)
  while char == 32 do
    motions["h"](ed, true, 1)
    char = ed:GetCharAt(ed:GetCurrentPos() - 1)
  end
end

local operators = {
  ["d"]  = function(ed, linewise, final) if linewise then selectCurrentLine(ed, true) end ; 
                                         if final then ed:Cut() end ; end,
  ["c"]  = function(ed, linewise, final) if linewise then selectCurrentLine(ed, true) end ; 
                                         if final then moveCaretLeftPastSpaces(ed) ; ed:Cut() 
                                           if linewise then
                                             executeCommandNormal("O", ed)
                                           else 
                                             setMode(kEditMode.insert) end
                                         end ; end,
  ["y"]  = function(ed, linewise, final) if linewise then selectCurrentLine(ed, true) end ; 
                                         if final then ed:Copy() cancelSelection(ed) end ; end,
  ["x"]  = function(ed, linewise, final) if linewise then selectCurrentLine(ed, true) end ; 
                                         if final then ed:Cut() ; cancelSelection(ed) end ; end
}  


local commandsNormal = { 
  ["v"]       = function(ed) setMode(kEditMode.visual, false) end,
  ["V"]       = function(ed) setMode(kEditMode.visualLine, false) end,
  ["v+Ctrl"]  = function(ed) setMode(kEditMode.visualBlock, false) end,
  ["i"]       = function(ed) setMode(kEditMode.insert, false) end,
  ["I"]       = function(ed) ed:Home() ; setMode(kEditMode.insert, false) end,
  ["a"]       = function(ed) setMode(kEditMode.insert, false) end,
  ["A"]       = function(ed) ed:LineEnd() ; setMode(kEditMode.insert, false) end,
  ["R"]       = function(ed) setMode(kEditMode.insert, true) end,
  ["gg"]      = function(ed) callExtendableFunc(ed, "DocumentStart") end,
  ["gt"]      = function(ed) ide.frame:AddPendingEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED,
                               ID.NOTEBOOKTABNEXT)) end,
  ["gT"]      = function(ed) ide.frame:AddPendingEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED,
                               ID.NOTEBOOKTABPREV)) end,
  ["G"]       = function(ed) if curNumber > 0 then
                               local line = ed:GetCurrentLine()
                               local relative = curNumber - 1 - line
                               local reps = math.abs(relative)
                               if relative <= 0 then
                                 motions["k"](ed, nil, reps)
                               else
                                 motions["j"](ed, nil, reps)
                               end
                               motions["HOME"](ed, nil)
                             else
                               callExtendableFunc(ed, "DocumentEnd")
                             end ; end,
  ["x"]       = function(ed) normOrVisFunc(ed, "DeleteBack", "Cut") end,
  ["o"]       = function(ed) ed:InsertText(ed:GetLineEndPosition(ed:GetCurrentLine()), "\13\10") 
                             ed:LineDown() ; setMode(kEditMode.insert, false) ; end,
  ["O"]       = function(ed) ed:LineUp()
                             ed:InsertText(ed:GetLineEndPosition(ed:GetCurrentLine()), "\13\10") 
                             ed:LineDown() ; setMode(kEditMode.insert, false) ; end,
  ["Y"]       = function(ed) yank(ed) end,
  ["p"]       = function(ed) for i=1, math.min(math.max(curNumber, 1), _MAX_REPS) do ed:Paste() end ; end,
  ["u"]       = function(ed) for i=1, math.max(curNumber, 1) do ed:Undo() end ; end,
  ["zz"]      = function(ed) ed:VerticalCentreCaret() end,
  ["z."]      = function(ed) ed:VerticalCentreCaret() end,
  ["zt"]      = function(ed) ed:SetFirstVisibleLine(ed:GetCurrentLine()) ; end,
  ["zb"]      = function(ed) ed:SetFirstVisibleLine(math.max(0, ed:GetCurrentLine() - ed:LinesOnScreen() + 1)) ; end,
  ["r+Ctrl"]  = function(ed) ed:Redo() end,
  ["."]       = function(ed) curNumber = lastNumber ; executeCommandNormal(lastCommand, ed) end,
  ["DEL"]     = function(ed) local pos = ed:GetCurrentPos() ; ed:DeleteRange(pos, math.min(math.max(curNumber, 1), _MAX_REPS)) end,
  ["#"]       = function(ed) openRealVim(ed) end,
}

local commandsVisual = {
  ["c"] = function(ed, cmd) end,
  ["x"] = function(ed, cmd) end,
  ["y"] = function(ed, cmd) end
}

-- this remains local because of forward declaration
-- noUndo passed to any relevant function in case we
-- want to extend 
function executeCommandNormal(key, editor, noUndo)
  local retVal
  if commandsNormal[key] ~= nil then
    retVal = commandsNormal[key](editor, noUndo)
    if key ~= "." then
      lastNumber = curNumber
      lastCommand = key
    end
  end
  resetCurrentVars()
  -- retVal could be nil, false or true so
  return (retVal == true and true or false)
end

local function doesCommandExpectMotionElement(cmdKey)
  if isModeVisual(editMode) then return false end
  return cmdKey == "c" or cmdKey == "d" or cmdKey == "z" or
         cmdKey == "y"
end

-- forward declaration at top of file
function eventKeyNumToChar(keyNum)
  local number
  if keyNum >= 48 and keyNum <= 57 then
    number = keyNum - 48
    if not wx.wxGetKeyState(wx.WXK_SHIFT) then
      return number
    else
      return shiftMap[tostring(number)]
    end
  else
    if keyNum >= 32 and keyNum <= 126 then
      key = string.char(keyNum)
      if not wx.wxGetKeyState(wx.WXK_SHIFT) then 
        return key:lower()
      else
        if shiftMap[key] then return shiftMap[key] else return key end
      end
    else
      if wx.wxGetKeyState(wx.WXK_SHIFT) then key = key .. "+Shift" return key end
    end
  end
  return (keyMap[tostring(keyNum)] or tostring(keyNum))
end

local function executeCommand(cmd, cmdReps, editor, motionReps, linewise, doMotion)
  editor:BeginUndoAction()
  local iters = math.max(cmdReps, 1)
  for i = 1, iters do
    if doMotion then motions[cmd.nchar](editor, true, motionReps) end
    local final = i == iters and true or false
    operators[cmd.cmdchar](editor, linewise, final)
  end
  editor:EndUndoAction()
end

local function validateAndExecuteCommand(editor, cmd)
  _DBG("cmd.prechar: ", cmd.prechar)
  _DBG("cmd.count1: ", cmd.count1)
  _DBG("cmd.cmdchar: ", cmd.cmdchar)
  _DBG("cmd.count2: ", cmd.count2)
  _DBG("cmd.nchar: ", cmd.nchar)
  if cmd.cmdchar ~= "" then
    curNumber = cmd.count1
    if cmd.nchar == "" then
      if motions[cmd.cmdchar] then 
        editor:BeginUndoAction()
        motions[cmd.cmdchar](editor, false, math.max(cmd.count1, 1))
        editor:EndUndoAction()
        return true 
      elseif not doesCommandExpectMotionElement(cmd.cmdchar) then
        editor:BeginUndoAction()
        if operators[cmd.cmdchar] then
          executeCommand(cmd, curNumber, editor, nil, false, false)
        else
          _DBG("Performed from old table!")
          _DBG("---"..cmd.prechar.. cmd.cmdchar)
          executeCommandNormal(cmd.prechar .. cmd.cmdchar, editor)
        end
        editor:EndUndoAction()
        return true
      end
    else
      -- we have an operator and a motion or linewise (eg dd, cc)
      if operators[cmd.cmdchar] then
        if motions[cmd.nchar] then
          executeCommand(cmd, curNumber, editor, math.max(cmd.count2, 1), false, true)
          return true
        else
          if cmd.nchar == cmd.cmdchar then
            executeCommand(cmd, curNumber, editor, nil, true, false)
            return true
          end
        end
      end
      executeCommandNormal(cmd.prechar .. cmd.cmdchar .. cmd.nchar, editor)
      _DBG("Performed from old table!")
      return true
    end
  end
    
  return false
end

-----------------------------------------------------------------------------------------------------
-- implement returned plugin object inc event handlers here
return {
  name = "Vim",
  description = "Vim-like editing for ZBS.",
  author = "Paul Reilly",
  version = "0.3",
  dependencies = "1.61",
  
  onRegister = function(self)
    setMode(kEditMode.insert)
    -- currently need to override ZBS shortcuts here
    --origCtrlReg = 
    ide:SetHotKey(function() curEditor:Redo() end, "Ctrl+R")
    cmd = newCommand()
    ide:SetStatus("Press 'Escape' to enter Vim editing mode")
  end,

  onEditorKeyDown = function(self, editor, event)
    curEditor = editor
    local key =  tostring(event:GetKeyCode())
    local keyNum = tonumber(key)
    
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
        ide:GetOutputNotebook().errorlog:Erase()
        ide:SetStatus(":")
        resetCurrentVars()
        curCommand = ":"
        return false
      end
    end

    -- in Vim mode. Do nothing with Ctrl, Shift or Alt events
    if keyNum >= 306 and keyNum <= 308 then return false end 
    
    key = eventKeyNumToChar(keyNum)
        
    -----------------------------------------------------------------
    --         Command Line Mode        
    if editMode == kEditMode.commandLine then
      -- clear output window
      ide:GetOutputNotebook().errorlog:Erase()
      if keyNum == 13 then
        setMode(kEditMode.normal)
        parseAndExecuteCommandLine(editor)
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
    -----------------------------------------------------------------
    
    -- not command line, remap key if required
    if keyRemap[key] then key = keyRemap[key] end
    
    -----------------------------------------------------------------
    --    Normal/Visual Modes 
    if keyNum == 27 then setMode(kEditMode.normal) ; cmd = newCommand() return false end
    -- handle numbers
    if tonumber(key) and tonumber(key) < 10 then
      if cmd.cmdchar == "" then
        -- lone zero is line start command
        if cmd.count1 == 0 and tonumber(key) == 0 then
          motions["HOME"](editor)
          cmd = newCommand()
        else
          cmd.count1 = cmd.count1 * 10 + tonumber(key)
        end
      else
        if cmd.count2 == 0 and tonumber(key) == 0 then
          key = "HOME"
        else
          cmd.count2 = cmd.count2 * 10 + tonumber(key)
        end
      end
      if key ~= "HOME" then return false end
    end
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
    if validateAndExecuteCommand(editor, cmd) then 
      cmdLast = table.clone(cmd)
      cmd = newCommand()
    end
    
    return false
    -----------------------------------------------------------------
  end,
  
  -- caret setting is per document/editor, but our Vim mode is global
  -- so handle events to make sure carets match when switching etc
  onEditorLoad = function(self, editor) setCaret(editor) end,
  onEditorNew = function(self, editor) setCaret(editor) end,
  onEditorFocusSet = function(self, editor) setCaret(editor) end
}
