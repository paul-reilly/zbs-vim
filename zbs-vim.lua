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
local kEditMode = { normal = 0, visual = 1, visualBlock = 2, visualLine = 3, 
                    insert = 4, commandLine = 5 }

local editMode = nil
-- bound repetitions of some functions to this value
-- to avoid pasting stuff 100,000 times or whatever
local _MAX_REPS = 50 
local curEditor, curNumber, curCommand, lastNumber, lastCommand = nil, 0, "", 0, ""

local function resetCurrentVars()
  curNumber = 0
  curCommand = ""
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
  return ( mode >= kEditMode.visual and mode <= kEditMode.visualLine )
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
  end
  setCaret(curEditor)
  curEditor:SetOvertype(overtype)
end

-- some wxStyledTextCtrl methods have Extend versions
-- so this saves a bit of duplication for working
-- in visual mode
local function callExtendableFunc(obj, name, ...)
  local extend = isModeVisual(editMode) and "Extend" or ""
  local reps = math.max(curNumber, 1)
  curEditor:BeginUndoAction()
  for i = 1, reps do
    obj[name .. extend](obj, ...)
  end
  curEditor:EndUndoAction()  
end

local function normOrVisFunc(obj, norm, vis)
  if editMode == kEditMode.visual then
    obj[vis](obj)
  else
    local reps = math.max(curNumber, 1)
    curEditor:BeginUndoAction()
    for i = 1, reps do
      obj[norm](obj)
    end
    curEditor:EndUndoAction()
  end
end

local function deleteLines(noUndo)
  local lineNumber, start, len
  local reps = math.max(curNumber, 1)
  if noUndo ~= true then curEditor:BeginUndoAction() end
  for i = 1, reps do
    lineNumber = curEditor:GetCurrentLine() --curEditor:LineFromPosition(curEditor:GetCurrentPos())
    curEditor:LineCut()
  end
  if noUndo ~= true then curEditor:EndUndoAction() end
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

local executeCommandNormal -- forward declaration required for locals only

local commandsNormal = {
  ["PGUP"]    = function(ed) callExtendableFunc(ed, "PageUp") end,
  ["PGDOWN"]  = function(ed) callExtendableFunc(ed, "PageDown") end,
  ["END"]     = function(ed) callExtendableFunc(ed, "LineEnd") end,
  ["$"]       = function(ed) callExtendableFunc(ed, "LineEnd") end,
  ["HOME"]    = function(ed) callExtendableFunc(ed, "Home") end,
  ["^"]       = function(ed) callExtendableFunc(ed, "VCHome") end,
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
                               curNumber = math.abs(relative)
                               if relative <= 0 then
                                 executeCommandNormal("k", ed)
                               else
                                 executeCommandNormal("j", ed)
                               end
                               executeCommandNormal("^", ed)
                             else
                               callExtendableFunc(ed, "DocumentEnd")
                             end ; end,
  ["b"]       = function(ed) callExtendableFunc(ed, "WordLeft") end,
  ["w"]       = function(ed) callExtendableFunc(ed, "WordRight") end,
  ["h"]       = function(ed) callExtendableFunc(ed, "CharLeft") end,
  ["BS"]      = function(ed) callExtendableFunc(ed, "CharLeft") end, 
  ["LEFT"]    = function(ed) callExtendableFunc(ed, "CharLeft") end, 
  ["j"]       = function(ed) callExtendableFunc(ed, "LineDown") end,
  ["DOWN"]    = function(ed) callExtendableFunc(ed, "LineDown") end,
  ["k"]       = function(ed) callExtendableFunc(ed, "LineUp") end,
  ["UP"]      = function(ed) callExtendableFunc(ed, "LineUp") end,
  ["l"]       = function(ed) callExtendableFunc(ed, "CharRight") end,
  ["RIGHT"]   = function(ed) callExtendableFunc(ed, "CharRight") end,
  ["x"]       = function(ed) normOrVisFunc(ed, "DeleteBack", "Cut") end,
  ["o"]       = function(ed) ed:InsertText(ed:GetLineEndPosition(ed:GetCurrentLine()), "\13\10") 
                             ed:LineDown() ; setMode(kEditMode.insert, false) ; end,
  ["O"]       = function(ed) ed:LineUp()
                             ed:InsertText(ed:GetLineEndPosition(ed:GetCurrentLine()), "\13\10") 
                             ed:LineDown() ; setMode(kEditMode.insert, false) ; end,
  ["y"]       = function(ed) if hasSelection(ed) then
                               ed:Copy() ; ed:SetEmptySelection(ed:GetCurrentPos()) 
                             end
                             if isModeVisual(editMode) then setMode(kEditMode.normal) end
                             end,
  ["c"]       = function(ed) if isModeVisual(editMode) then 
                               executeCommandNormal("x", ed) ; setMode(kEditMode.insert); 
                               ed:SetEmptySelection(ed:GetCurrentPos()) end ; end,
  ["yy"]      = function(ed) yank(ed) end,
  ["p"]       = function(ed) for i=1, math.min(math.max(curNumber, 1), _MAX_REPS) do ed:Paste() end ; end,
  ["u"]       = function(ed) for i=1, math.max(curNumber, 1) do ed:Undo() end ; end,
  ["zz"]      = function(ed) ed:VerticalCentreCaret() end,
  ["z."]      = function(ed) ed:VerticalCentreCaret() end,
  ["zt"]      = function(ed) ed:SetFirstVisibleLine(ed:GetCurrentLine()) ; end,
  ["zb"]      = function(ed) ed:SetFirstVisibleLine(math.max(0, ed:GetCurrentLine() - ed:LinesOnScreen() + 1)) ; end,
  ["cc"]      = function(ed) ed:BeginUndoAction()
                             if curNumber > 1 then curNumber = curNumber - 1 ; executeCommandNormal("dd", ed, true) end
                             ed:SetCurrentPos(ed:PositionFromLine(ed:GetCurrentLine())) 
                             executeCommandNormal("d$", ed) ; executeCommandNormal("i", ed) 
                             ed:EndUndoAction() ; end,
  ["c$"]      = function(ed) executeCommandNormal("d$", ed) ; executeCommandNormal("i", ed) ; end,
  ["cw"]      = function(ed) executeCommandNormal("dw", ed) ; executeCommandNormal("i", ed) ; end,
  ["cb"]      = function(ed) executeCommandNormal("db", ed) ; executeCommandNormal("i", ed) ; end,
  ["c^"]      = function(ed) executeCommandNormal("d^", ed) ; executeCommandNormal("i", ed) ; end,
  ["c0"]      = function(ed) executeCommandNormal("d^", ed) ; executeCommandNormal("i", ed) ; end,
  ["dd"]      = function(ed, noUndo) deleteLines(noUndo) end,
  ["d$"]      = function(ed) ed:DeleteRange(ed:GetCurrentPos(), ed:GetLineEndPosition(ed:GetCurrentLine()) - ed:GetCurrentPos()) ; end,
  ["d^"]      = function(ed) local pos = ed:PositionFromLine(ed:GetCurrentLine()) ; ed:DeleteRange(pos, ed:GetCurrentPos() - pos) ; end,
  ["d0"]      = function(ed) local pos = ed:PositionFromLine(ed:GetCurrentLine()) ; ed:DeleteRange(pos, ed:GetCurrentPos() - pos) ; end,
  ["dw"]      = function(ed) for i=1, math.min(math.max(curNumber, 1), _MAX_REPS) do ed:DelWordRight() end ; end,
  ["db"]      = function(ed) for i=1, math.min(math.max(curNumber, 1), _MAX_REPS) do ed:DelWordLeft() end ; end,
  ["r+Ctrl"]  = function(ed) ed:Redo() end,
  ["."]       = function(ed) curNumber = lastNumber ; executeCommandNormal(lastCommand, ed) end,
  ["DEL"]     = function(ed) local pos = ed:GetCurrentPos() ; ed:DeleteRange(pos, math.min(math.max(curNumber, 1), _MAX_REPS)) end,
  ["#"]       = function(ed) openRealVim(ed) end,
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
         cmdKey == "y" or cmdKey == "g"
end

local function eventKeyNumToChar(keyNum)
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

-----------------------------------------------------------------------------------------------------
-- implement returned plugin object inc event handlers here
return {
  name = "zbs-vim",
  description = "Vim-like editing for ZBS.",
  author = "Paul Reilly",
  version = "0.1",
  
  onRegister = function(self)
    setMode(kEditMode.insert)
    -- currently need to override ZBS shortcuts here
    --origCtrlReg = 
    ide:SetHotKey(function() curEditor:Redo() end, "Ctrl+R")
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
        ide:Print(":")
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
          ide:Print(curCommand)
        else
          setMode(kEditMode.normal)
        end
      elseif keyNum == 27 then
        resetCurrentVars()
        setMode(kEditMode.normal)
      else
        curCommand = curCommand .. key
        ide:Print(curCommand)
      end
      return false
    end
    -----------------------------------------------------------------
    
    -- not command line, remap key if required
    if keyRemap[key] then key = keyRemap[key] end
    
    -- handle numbers at start of command
    if tonumber(key) then
      -- don't add to total if command is underway
      if #curCommand == 0 then
        if tonumber(key) < 10 then
          -- lone zero is line start command
          if curNumber == 0 and tonumber(key) == 0 then
            executeCommandNormal("HOME", editor)
          else
            curNumber = (curNumber * 10) + tonumber(key)
          end
          return false
        end
      end
    end
    
    -- check for commands with second, motion parameters
    if curCommand:len() == 0 and doesCommandExpectMotionElement(key) then 
      curCommand = key
      return false -- wait for 2nd key
    else      
      if curCommand:len() == 1 then
        -- add to command string and continue to execution
        key = curCommand .. key
      end
    end

    if wx.wxGetKeyState(wx.WXK_CONTROL) then key = key .. "+Ctrl" end
    if wx.wxGetKeyState(wx.WXK_ALT) then key = key .. "+Alt" end
    
    ide:Print(key)
    return executeCommandNormal(key, editor)
  end,
  
  -- caret setting is per document/editor, but our Vim mode is global
  -- so handle events to make sure carets match when switching etc
  onEditorLoad = function(self, editor) setCaret(editor) end,
  onEditorNew = function(self, editor) setCaret(editor) end,
  onEditorFocusSet = function(self, editor) setCaret(editor) end
}
