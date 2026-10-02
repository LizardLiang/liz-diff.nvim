local M = {}

local cache = {}

function M.get(keyword)
  return cache[keyword]
end

function M.set(keyword, files, meta, root)
  local previous = cache[keyword]
  cache[keyword] = {
    files = files,
    cursor_index = 1,
    meta = meta,
    root = root,
    filter = previous and previous.filter or '',
  }
end

-- Stores the filter text for the keyword and resets the cursor, since
-- cursor_index refers to rows of the filtered list.
function M.set_filter(keyword, text)
  if cache[keyword] then
    cache[keyword].filter = text
    cache[keyword].cursor_index = 1
  end
end

function M.set_cursor(keyword, index)
  if cache[keyword] then
    cache[keyword].cursor_index = index
  end
end

function M.delete(keyword)
  cache[keyword] = nil
end

function M.clear()
  cache = {}
end

return M
