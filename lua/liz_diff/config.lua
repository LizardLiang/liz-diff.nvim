local M = {}

local config = {
  width = 0.8,
  height = 0.6,
  border = 'rounded',
  keymap = {
    close = { '<Esc>', 'q' },
    open_diff = '<CR>',
  },
}

local function is_list(t)
  if type(t) ~= 'table' then
    return false
  end
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then
      return false
    end
  end
  return i > 0
end

local function deep_merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == 'table' and type(result[k]) == 'table' and not is_list(v) then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = vim.deepcopy(v)
    end
  end
  return result
end

function M.merge(user_opts)
  if not user_opts then
    return
  end
  config = deep_merge(config, user_opts)
end

function M.get()
  return config
end

return M
