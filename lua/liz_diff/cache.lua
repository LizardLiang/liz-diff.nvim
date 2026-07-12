local M = {}

local cache = {}

function M.get(keyword)
  return cache[keyword]
end

function M.set(keyword, files, meta)
  cache[keyword] = { files = files, cursor_index = 1, meta = meta }
end

function M.set_cursor(keyword, index)
  if cache[keyword] then
    cache[keyword].cursor_index = index
  end
end

function M.clear()
  cache = {}
end

return M
