-- solution.lua - Lua filter for solution toggle and auto-points tracking
-- Handles solution blocks with scalable answer boxes and point markers
-- Uses Meta + Div filters so Pandoc walks the full AST automatically.

-- Point values for marker commands
local point_values = {
  ["\\p"] = 1,
  ["\\hp"] = 0.5,
  ["\\pp"] = 2,
}

-- Module-level state (set by Meta filter, read by Div filter)
local is_solution_mode = false
local show_answerfields = true
local use_grid = true

---------------------------------------------------------------------------
-- Helper: metadata value → string
---------------------------------------------------------------------------
local function meta_to_string(meta_value)
  if meta_value == nil then
    return ""
  elseif type(meta_value) == "string" then
    return meta_value
  elseif type(meta_value) == "boolean" then
    return tostring(meta_value)
  elseif meta_value.t == "MetaInlines" then
    return pandoc.utils.stringify(meta_value)
  elseif meta_value.t == "MetaString" then
    return meta_value.text or pandoc.utils.stringify(meta_value)
  else
    return pandoc.utils.stringify(meta_value)
  end
end

---------------------------------------------------------------------------
-- Helper: metadata value → boolean with default
---------------------------------------------------------------------------
local function meta_to_bool(meta_value, default)
  if meta_value == nil then
    return default
  end
  if type(meta_value) == "boolean" then
    return meta_value
  end
  local str = meta_to_string(meta_value)
  if str == "true" then return true end
  if str == "false" then return false end
  return default
end

---------------------------------------------------------------------------
-- Point counting
---------------------------------------------------------------------------

-- Count point markers in raw text.
-- Order matters: match longer commands (\hp, \pp) before \p so that
-- e.g. \pp is not double-counted as two \p.  We remove matched tokens
-- from a working copy so adjacent markers (e.g. \p\p) are handled.
-- The frontier pattern %f[^a-zA-Z] matches at any position where the
-- next character is not a letter (including end-of-string).
local function count_points_in_text(text)
  local points = 0
  local s = text

  -- Pass 1: \hp (must precede \p to avoid false \p match inside \hp)
  for _ in s:gmatch("\\hp%f[^a-zA-Z]") do
    points = points + point_values["\\hp"]
  end
  s = s:gsub("\\hp%f[^a-zA-Z]", "")

  -- Pass 2: \pp (must precede \p)
  for _ in s:gmatch("\\pp%f[^a-zA-Z]") do
    points = points + point_values["\\pp"]
  end
  s = s:gsub("\\pp%f[^a-zA-Z]", "")

  -- Pass 3: \p (only single-letter command left)
  for _ in s:gmatch("\\p%f[^a-zA-Z]") do
    points = points + point_values["\\p"]
  end

  return points
end

-- Forward declarations for mutual recursion
local count_points_in_inlines
local count_points_in_blocks

-- Count points in inline elements
count_points_in_inlines = function(inlines)
  local points = 0
  for _, el in ipairs(inlines) do
    if el.t == "RawInline" and (el.format == "tex" or el.format == "latex") then
      points = points + count_points_in_text(el.text)
    elseif el.t == "Math" then
      points = points + count_points_in_text(el.text)
    elseif el.content then
      points = points + count_points_in_inlines(el.content)
    end
  end
  return points
end

-- Count points in a list of blocks recursively
count_points_in_blocks = function(blocks)
  local points = 0
  for _, block in ipairs(blocks) do
    if block.t == "RawBlock" and (block.format == "tex" or block.format == "latex") then
      points = points + count_points_in_text(block.text)
    elseif block.t == "Para" or block.t == "Plain" then
      points = points + count_points_in_inlines(block.content)
    elseif block.t == "Div" then
      points = points + count_points_in_blocks(block.content)
    elseif block.t == "BlockQuote" then
      points = points + count_points_in_blocks(block.content)
    elseif block.t == "BulletList" or block.t == "OrderedList" then
      for _, item in ipairs(block.content) do
        points = points + count_points_in_blocks(item)
      end
    elseif block.t == "Header" then
      points = points + count_points_in_inlines(block.content)
    end
  end
  return points
end

---------------------------------------------------------------------------
-- Height estimation for answer fields
---------------------------------------------------------------------------
local function estimate_content_height(blocks)
  local total_chars = 0
  local extra_lines = 0

  for _, block in ipairs(blocks) do
    if block.t == "Para" or block.t == "Plain" then
      local text = pandoc.utils.stringify(block.content)
      total_chars = total_chars + #text
      extra_lines = extra_lines + 1
      -- Check for DisplayMath inlines inside Para
      for _, inline in ipairs(block.content) do
        if inline.t == "Math" and inline.mathtype == "DisplayMath" then
          extra_lines = extra_lines + 2
        end
      end
    elseif block.t == "BulletList" or block.t == "OrderedList" then
      for _, item in ipairs(block.content) do
        local text = pandoc.utils.stringify(item)
        total_chars = total_chars + #text
        extra_lines = extra_lines + 0.5
      end
    elseif block.t == "RawBlock" then
      extra_lines = extra_lines + 2
    elseif block.t == "Div" then
      local nested = estimate_content_height(block.content)
      extra_lines = extra_lines + nested / 0.5
    else
      local text = pandoc.utils.stringify(block)
      total_chars = total_chars + #text
    end
  end

  local text_lines = total_chars / 80
  local total_lines = text_lines + extra_lines
  local height = math.max(2, total_lines * 0.5)
  height = math.floor(height * 2 + 0.5) / 2

  return height
end

---------------------------------------------------------------------------
-- Format points for display (handles decimals nicely)
---------------------------------------------------------------------------
local function format_points(pts)
  if pts == math.floor(pts) then
    return tostring(math.floor(pts))
  else
    return string.format("%.1f", pts)
  end
end

---------------------------------------------------------------------------
-- Meta filter: read metadata, inject \newif flags
---------------------------------------------------------------------------
local function Meta(meta)
  is_solution_mode = meta_to_bool(meta["solution"], false)
  show_answerfields = meta_to_bool(meta["answerfields"], true)
  use_grid = meta_to_bool(meta["grid-paper"], true)

  -- Build LaTeX flag definitions
  local solution_flag = is_solution_mode and "\\solutiontrue" or "\\solutionfalse"
  local grid_flag = use_grid and "\\examgridtrue" or "\\examgridfalse"

  local latex_cmds = string.format(
    "\\newif\\ifsolution\n%s\n\\newif\\ifexamgrid\n%s",
    solution_flag, grid_flag
  )

  -- Add to header-includes
  local header_includes = meta["header-includes"]
  if header_includes == nil then
    header_includes = pandoc.MetaList({})
  elseif header_includes.t ~= "MetaList" then
    header_includes = pandoc.MetaList({header_includes})
  end

  table.insert(header_includes, pandoc.MetaBlocks({pandoc.RawBlock("latex", latex_cmds)}))
  meta["header-includes"] = header_includes

  return meta
end

---------------------------------------------------------------------------
-- Div filter: process .solution divs, auto-insert \marks{N}
---------------------------------------------------------------------------
local function Div(div)
  if not div.classes:includes("solution") then
    return nil  -- pass through unchanged
  end

  local box_attr = div.attributes["box"]
  local pts = count_points_in_blocks(div.content)
  local marks_block = nil
  if pts > 0 then
    marks_block = pandoc.RawBlock("latex",
      string.format("\\marks{%s}", format_points(pts)))
  end

  if is_solution_mode then
    -- Solution mode: wrap content in solutionbox, append marks
    local new_content = { pandoc.RawBlock("latex", "\\begin{solutionbox}") }
    for _, el in ipairs(div.content) do
      table.insert(new_content, el)
    end
    table.insert(new_content, pandoc.RawBlock("latex", "\\end{solutionbox}"))
    if marks_block then
      table.insert(new_content, marks_block)
    end

    div.content = new_content
    div.classes = pandoc.List({})
    div.attributes = {}
    return div

  else
    -- Exam mode
    if show_answerfields then
      local height
      if box_attr and tonumber(box_attr) then
        height = box_attr
      else
        height = estimate_content_height(div.content)
      end

      local new_content = {
        pandoc.RawBlock("latex", string.format("\\examanswerfield{%s}", height))
      }
      if marks_block then
        table.insert(new_content, marks_block)
      end

      div.content = new_content
      div.classes = pandoc.List({})
      div.attributes = {}
      return div

    else
      -- No answer fields: return only marks (or nothing)
      if marks_block then
        div.content = { marks_block }
        div.classes = pandoc.List({})
        div.attributes = {}
        return div
      else
        return {}  -- empty list removes the div
      end
    end
  end
end

return {
  { Meta = Meta },
  { Div = Div },
}
