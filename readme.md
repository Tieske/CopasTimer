#Copas Timer
Copas Timer is free software under the MIT/X11 license.  
Copyright 2011-2013 Thijs Schreijer

[Documentation](http://tieske.github.com/CopasTimer/) and [sourcecode](http://github.com/Tieske/CopasTimer) are on GitHub

##Purpose
Copas Timer is an add on module for the Copas socket scheduler. Copas Timer implements background workers and timers along side the sockets. As an optional component the eventer module is available which allows for event-driven code. The events are being run as background workers in the scheduler.

Note: this is still all coroutine based, so it is not non-blocking asynchroneous!

##Usage
Copas Timer integrates into the Copas module, so there is no separate module table for it. When you `require("copas.timer")` it will return the modified Copas module table.

Below some simple examples for using the Copas Timer functionalities.
###Timers
The timers are created using callback functions;

```lua
local copas = require("copas.timer")

-- define timer callbacks
local arm_cb = nil
local expire_cb = function() print("executing the timer") end
local cancel_cb = nil
-- define timer parameters
local recurring = true
local interval = 5  --> in seconds

local t = copas.newtimer(arm_cb, expire_cb, cancel_cb, recurring):arm(interval)

-- add some sockets here

copas.loop()    --> start the scheduler and execute the timers

````
###Workers
Workers are created as coroutines from functions. Each worker gets its own queue of data to work on, and they will only run when data is available.

```lua
local copas = require("copas.timer")

local w = copas.addworker(function(queue)
    -- do some initializing here... will be run immediately upon
    -- adding the worker
    while true do
      data = queue:pop()    -- fetch data from queue, implicitly yields the coroutine
      -- handle the retrieved data here
      print(data)
      -- do some lengthy stuff
      queue:pause()         -- implicitly yields, without fetching new data
      -- do more lengthy stuff
    end
  end)

-- enqueue data for the new worker
w:push("here is some data")   

-- add some sockets here

copas.loop()
````

###Events
The eventer module adds event capabilities to copas. The eventhandlers run as workers and process
event data from their worker queues.

Copas itself will also be generating events once the eventer module is used;
```lua
local copas = require("copas.timer")
require("copas.eventer")   -- will be installed inside the global copas table; copas.eventer

local my_app = {
  before_start = function(eventqueue)
    while true do
      local event = eventqueue:pop()
      local self = event.client
      
      -- initialize stuff and create some sockets here...
      
    end
  end,

  after_start = function(eventqueue)
    while true do
      local event = eventqueue:pop()
      local self = event.client

      -- do some stuff
      
    end
  end,
}

copas:subscribe(my_app, my_app.before_start, copas.events.loopstarting)
copas:subscribe(my_app, my_app.after_start, copas.events.loopstarted)

copas.loop()
````

Adding event capabilities to your own object is easy;

```lua
local copas = require("copas.timer")
require("copas.eventer")   -- will be installed inside the global copas table; copas.eventer

-- create a module table and enable it with 4 events;
local my_module = {}
copas.eventer.decorate(my_module, {"start", "txerror", "rxerror", "stop"})

my_module.start = function(self)
	-- lets dispatch our start event here
	self:dispatch(self.events.start, "start data 1", "start data 2")
end

return my_module
````


##Changelog
###xx-xxx-2013; release 1.0
- background workers have been completely revised to work as coroutines instead of callbacks. This also reflects in the `eventer` module, where 
event handlers must now be setup as coroutines and get their event data from a queue.

###07-Mar-2013; release 0.4.3
- `eventer.decorate()` function now protects access to `events` table so invalid events throw an error
- fixed bug in timer errorhandler function

###04-Jun-2012; release 0.4.2
- fixed undefined behaviour when arming an already armed timer
- removed default 1 second interval, now throws an error if the first call to `arm()` does not provide an interval.
- bugfix, worker could not remove itself from the worker queue
- added method `copas.waitforcondition()` to the timer module

###07-Nov-2011; release 0.4.1
- bugfix, timer could not be cancelled from its own handler.
- bugfix, worker completed elswhere is no longer resumed.
- changed `exitloop()` and `isexiting()` members, see docs for use (this is breaking!)
- added an optional eventer module that fires events as background tasks
- restructured files, no longer 'copastimer.lua' but now 'copas/timer.lua' (and 'copas/eventer.lua'). (this is breaking!)

###24-Oct-2011; Initial release 0.4.0

-------------------------------------------------------------------
