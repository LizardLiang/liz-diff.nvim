-- Minimal vim mock for unit tests running outside Neovim
-- Only stubs what liz-diff modules actually call

if not vim then
  ---@diagnostic disable: lowercase-global
  vim = {
    deepcopy = function(t)
      if type(t) ~= 'table' then return t end
      local copy = {}
      for k, v in pairs(t) do
        copy[k] = vim.deepcopy(v)
      end
      return copy
    end,
    tbl_deep_extend = function(behavior, ...)
      local result = {}
      for i = 1, select('#', ...) do
        local tbl = select(i, ...)
        if tbl then
          for k, v in pairs(tbl) do
            if type(v) == 'table' and type(result[k]) == 'table' then
              result[k] = vim.tbl_deep_extend(behavior, result[k], v)
            else
              result[k] = vim.deepcopy(v)
            end
          end
        end
      end
      return result
    end,
    split = function(s, sep)
      local parts = {}
      for part in s:gmatch('[^' .. sep .. ']+') do
        parts[#parts + 1] = part
      end
      return parts
    end,
    trim = function(s)
      return s:match('^%s*(.-)%s*$')
    end,
    log = { levels = { WARN = 2, INFO = 3, ERROR = 1 } },
    notify = function() end,
    fn = {},
    api = {},
    cmd = function() end,
    bo = {},
    schedule = function(fn) fn() end,
  }
end

local M = {}

function M.reset_module(mod_name)
  package.loaded[mod_name] = nil
  return require(mod_name)
end

return M
