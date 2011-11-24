-- Copas test
local copas = require("copas.timer")
local socket = require("socket")

local count = 1
function check(param)
    print("Check count ", count, ". Called using param = ", param)
    count = count + 1
    return (count == 10)
end

function done(conditionmet, param)
    if conditionmet then
        print("The condition was met when count reached ", count - 1,". Called using param = ", param)
    else
        print("Failed, condition was not met. Called using param = ", param)
    end
    copas.exitloop()
end

copas.waitforcondition(0.1, 5, check, done, "1234567890")

copas.loop()
