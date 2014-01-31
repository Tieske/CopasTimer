local copas = require ("copas.timer")
local ev = require("copas.eventer")
local socket = require("socket")

host = "localhost"
port = 50000

-- create an object with event capabilities
local object1 = {

    i = 999,

    init = function(self)
        -- decorate myself with 'subscribe', 'unsubscribe' and 'dispatch' methods
        -- also ads a table 'events' which is a set with event values
        copas.eventer.decorate(self, {"started","myEvent","stopped"} )

        -- create timer to raise events at intervals
        self.timer = copas.newtimer(nil, function()
                self.i = self.i + 1
                if self.i > 10 then
                    print("we reached the count of 10, so instructing copas to exit...")
                    copas.exitloop(5, true)
                    -- notice that the timer will be stopped from the eventhandler
                else
                    self:dispatch(self.events.myEvent, self.i)
                end
            end, function()
                print ("---> from the timer 'cancel' handler: I've been cancelled!")
            end, true):arm(0.5)

        -- subscribe to copas events
        copas:subscribe(self, self.copaseventhandler)

        -- raise event (dispatch method was added by 'decorate' call above)
        self:dispatch(self.events.started)
    end,

    copaseventhandler = function(self, eventqueue)
      while true do
        local event = eventqueue:pop()
        if event.name == copas.events.loopstarting then
          print("COPAS is starting, lets initialize, set counter properly")
          self.i = 0
        elseif event.name == copas.events.loopstarted then
          local w = copas.addworker(function(queue)
              local t = queue:pop()
              print(table.concat(t, " "))
              copas.removeworker(queue)
          end)
          w:push({ "Hello", "world" })
          -- notice that the line above executes some time after the line below...
          print("COPAS has started, lets wait and see what happens")
        elseif event.name == copas.events.loopstopping then
          print("COPAS is stopping, cancelling the timer")
          self.timer:cancel()
        elseif event.name == copas.events.loopstopped then
          print("COPAS loop has stopped, so we're done")
        else
          print("Received an unknown copas event; " .. tostring(event.name))
        end
      end
    end,

}

-- initialize object (will decorate and register with the eventer) and subscribe to copas events
object1:init()

-- create second object to consume events
local object2 = {
    eventhandler = function(self, eventqueue)
	    while true do
        local event = eventqueue:pop()
        print ("received event; " .. event.name .. " with data; " .. tostring(event[1]) )
      end
    end,
}
-- subscribe second object to events of first object, do not use 'decorate' this time, but
-- directly on the eventer.
copas.eventer.clientsubscribe(object2, object1, object2.eventhandler)  -- subscribe to all events



-- now go startup a loop to get going

server = socket.bind(host, port)            -- create a dummy server otherwise copas won't run the test
copas.addserver(server, function (skt)
        -- function for socket handling
        skt = copas.wrap(skt)
        reqdata = skt:receive(pattern)
        -- do some stuff
    end)

print("Waiting for some bogus connection... will exit after count hits 10")
copas.loop()                          -- enter loop
print ("bye, bye...")
