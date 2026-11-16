-- A module.
local M = {}

--[[ Long
comment ]]
function M.greet(name)
  local s = [[raw
text]]
  print("hi " .. name, #s, nil, true)
end

return M
