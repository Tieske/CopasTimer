require("copas")
require("socket")
require("copastimer")
host = "localhost"
port = 50000

-- function handling network changes
local netchange = function (newState, oldState)
    if oldState then
        print ("The network connection changed...")
    else
        print ("Initial network state...")
    end
    print ("        connected : " .. newState.connected)
    print ("        IP address: " .. (newState.ip[1] or "none"))
    print ("        hostname  : " .. newState.name)
    -- do some stuff
end

-- function for socket handling
function handle(skt)
  skt = copas.wrap(skt)
  reqdata = skt:receive(pattern)
  -- do some stuff
end

-- function as just a timer
local lasttime
local cnt = 8
function silly()
    cnt=cnt-1
    if lasttime then
        print (cnt .. ": It's been " .. tostring(socket.gettime() - lasttime) .. " since we were here, silly how time flies...")
    end
    lasttime = socket.gettime()
    if cnt == 0 then
        -- exit the loop
        copas.isexiting = true
    end
end

server = socket.bind(host, port)            -- create a server
copas.addserver(server, handle)

print("Starting network checks, change your network and watch the changes come in")
local t = copas.addcheck(netchange)   -- create network check
t:arm(2)                                    -- arm the returned timer
copas.newtimer(silly, silly, nil, true, nil):arm(5)  -- silly timer
copas.loop()                          -- enter loop
print ("bye, bye...")

