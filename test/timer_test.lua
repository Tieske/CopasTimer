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

local someerror = function()
	data = data * nil  -- this will error
end

-- create a thread raising an error, to see what the default errorhandler does
local errworker = copas.addworker(function(queue)
	while true do
		local data = queue:pop()
		print("\n\n===========================\nAn error will follow; to show worker errorhandler output\n===========================")
		someerror()
	end
end)
errworker:push("some data")

-- create 2 workerthreads, where the second feeds data to the first
local w1 = 0
local backgroundworker1 = function(queue)
    while true do
--print("enetering w1")
		local data = queue:pop()  -- new arguments will be passed to data for next loop
        w1=w1+1
        print("Worker 1 reporting " .. tostring(w1) .. ", with provided data: " .. tostring(data))
        if w1 > 10 then return end  -- thread dies
    end
end
local t1 = copas.addworker(backgroundworker1)
t1:push("starting up")

local w2 = 0
local backgroundworker2 = function(queue)
    while true do
--print("enetering w2")
        queue:pause()      -- do not accept argument
        w2=w2+1
        print("Worker 2 reporting " .. tostring(w2))
        -- worker 1 received its arguments, so pass some more
        local item, err = t1:push("  --==<< worker2 passes " .. w2 .. " to worker 1 >>==--  ")
        if err then
          print("worker2:", err) 
          print("Now exiting worker 2")
          return  -- thread dies
        end
        if w2 > 20 then return end  -- will never be reached!
    end
end
local t2 = copas.addworker(backgroundworker2)
t2:push("anything will do, just to start it")

-- function as just a timer
local lasttime
local cnt = 8
local silly = function()
    cnt=cnt-1
    if lasttime then
        print (cnt .. ": It's been " .. tostring(socket.gettime() - lasttime) .. " seconds since we were here, silly how time flies...")
    end
    lasttime = socket.gettime()
    if cnt == 0 then
        -- exit the loop
        copas.exitloop(nil,true)
    elseif cnt == 4 then
        -- restart worker1
        w1 = 0
        t1 = copas.addworker(backgroundworker1)
        t1:push("starting again from the timer")
    end
end

local errtimer=function()
	print("\n\n===========================\nAn error will follow; to show timer errorhandler output\n===========================")
	someerror()
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
copas.newtimer(nil, errtimer, nil, false, nil):arm(1)  -- error timer

copas.loop()                          -- enter loop
print ("bye, bye...")
