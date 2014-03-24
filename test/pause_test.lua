local socket = require("socket")
local copas = require("copas.timer")

local backgroundworker = function(queue)
  local cnt = 0
  while true do
    queue:pause(1)  -- pause 1 second, the basis for this simple timer
    cnt = cnt + 1
    print("Simple timer reporting " .. tostring(cnt))
    if cnt > 10 then copas.exitloop() end  -- exit sample
  end
end
local t1 = copas.addworker(backgroundworker)


print("Starting loop, counting to 10...")
copas.loop()                          -- enter loop
print ("bye, bye...")
