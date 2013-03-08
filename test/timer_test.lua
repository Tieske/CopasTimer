local socket = require("socket")
local copas = require("copas.timer")
host = "localhost"
port = 50000


-- function for socket handling
function handle(skt)
  skt = copas.wrap(skt)
  reqdata = skt:receive(pattern)
  -- do some stuff
end

-- create 2 workerthreads, where the second feeds data to the first
local w1 = 0
local backgroundworker1 = function(queue)
    while true do
		local data = queue:pop()  -- new arguments will be passed to data for next loop
        w1=w1+1
        print("Worker 1 reporting " .. tostring(w1) .. ", with provided data: " .. tostring(data))
        if w1 > 10 then return end  -- thread dies
    end
end
local t1 = copas.addworker(backgroundworker1):push("starting up")
local w2 = 0
local backgroundworker2 = function(queue)
    while true do
        queue:pause()      -- do not accept argument
        w2=w2+1
        print("Worker 2 reporting " .. tostring(w2))
        -- worker 1 received its arguments, so pass some more
        t1:push("  --==<< worker2 passes " .. w2 .. " to worker 1 >>==--  ")
        if w2 > 20 then return end  -- thread dies
    end
end
local t2 = copas.addworker(backgroundworker2):push("anything will do, just to start it")

-- function as just a timer
local lasttime
local cnt = 8
local silly = function()
    cnt=cnt-1
    if lasttime then
        print (cnt .. ": It's been " .. tostring(socket.gettime() - lasttime) .. " since we were here, silly how time flies...")
    end
    lasttime = socket.gettime()
    if cnt == 0 then
        -- exit the loop
        copas.exitloop(nil,true)
    elseif cnt == 4 then
        -- restart worker1
        w1 = 0
        t1 = copas.addworker(backgroundworker1):push("starting again from the timer")
    end
end



server = socket.bind(host, port)            -- create a server
copas.addserver(server, handle)

-- setup a delayed executioner example
local det = socket.gettime()
copas.delayedexecutioner(5, function(t)
        print(t .. " and it was " .. socket.gettime() - det .. " to be precise.")
    end, "This should display in 5 seconds from now.")

print("Waiting for some bogus connection... will exit after the count down.")
copas.newtimer(silly, silly, nil, true, nil):arm(2)  -- silly timer

copas.loop()                          -- enter loop
print ("bye, bye...")
