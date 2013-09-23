-------------------------------------------------------------------------------
-- Copas Timer is a module that adds a timer capability to the Copas scheduler.
-- It provides the same base functions <code>step</code> and <code>loop</code>
-- as Copas (it actually replaces them) except that it will also check for (and
-- run) timers expiring and run background workers if there is no IO or timer to
-- handle.<br/>
-- <br/>To use the module it should be required as; <code>local copas =
-- require("copas.timer")</code> because it returns the global <code>copas</code>
-- table and not a separate timer table.<br/>
-- <br/>There is a difference between the 2 background mechanisms provided; the
-- timers run on the main loop, and hence should never yield. The workers run in
-- their own thread (coroutine) and can be yielded if they take too long.<br/>
-- <br/>The workers are dispatched from a rotating queue, so when a worker is up to run
-- it will be removed from the queue, resumed, and (if not finished) added at the end
-- of the queue again.<br/>
-- <br/>Copas Timer is free software under the MIT/X11 license.
-- @copyright 2011-2013 Thijs Schreijer
-- @release Version 1.0, Timer module to extend Copas with a timer and worker capability

local copas = require("copas")
local socket = require("socket")
require("coxpcall")
local pcall, xpcall = copcall, coxpcall

local timerid = 1		-- counter to create unique timerid's
local timers = {}		-- table with running timers by their id
local order = nil		-- linked list with running timers sorted by expiry time, 'order' being the first to expire
local PRECISION = 0.02  -- default precision value
local TIMEOUT = 5       -- default timeout value
local copasstep = copas.step    -- store original function
local copasloop = copas.loop    -- store original function
local exiting           -- indicator of loop status
local exitingnow        -- indicator that loop must exit immediately
local exiteventthreads  -- table with exit threads to be completed before exiting
local exitcanceltimers  -- should timers be cancelled after ending the loop
local exittimeout       -- timeout for workers to exit
local exittimer         -- timerhandling the exit timeout
-- worker data
local activeworkers = {}        -- list with background worker threads, currently scheduled
local inactiveworkers = {}      -- table with background workers, currently inactive, indexed by the thread
local runningworker             -- the currently running worker table

-------------------------------------------------------------------------------
-- Will be used as error handler for timers if none provided
local _missingTerrorhandler = function(...)
	print("copas.timer: Error in timer callback: ",  ... )
    print(debug.traceback())
end

-------------------------------------------------------------------------------
-- Will be used as error handler for workers if none provided
local _missingWerrorhandler = function(co, msg)
    print(debug.traceback(co, "copas.timer: Error in worker coroutine: " .. tostring(msg)))
end


--=============================================================================
--               BACKGROUND WORKERS
--=============================================================================

-------------------------------------------------------------------------------
-- Adds a background worker to the end of the active thread list. Removes it
-- simultaneously from the inactive list.
-- @param t thread table (see copas.addworker()) to add to the list
local pushthread = function(t)
    table.insert(activeworkers, t)
    inactiveworkers[t.thread] = nil  -- remove to be sure
end

-------------------------------------------------------------------------------
-- Pops background worker from the active thread list
-- @param t thread table (see copas.addworker()) or actual thread (coroutine)
-- to remove from the list. If nil then just the one on top will be popped.
-- @return the popped thread table, or nil if it wasn't found
local popthread = function(t)
    if #activeworkers == 0 then
        return nil
    end

    if not t then
        -- get the first one
        return table.remove(activeworkers, 1)
    else
        -- specific one specified, have to go look for it
        for i, v in ipairs(activeworkers) do
            if v == t or v.thread == t then
                -- found it, return it
                return table.remove(activeworkers, i)
            end
        end
        -- wasn't found
        return nil
    end
end

-------------------------------------------------------------------------------
-- Returns a background worker table
-- @param t thread (coroutine) to look up
-- @return the worker table (as earlier returned by <code>addworker()</code>)
-- or <code>nil</code> if it wasn't found
-- @see copas.addworker
-- @usage if copas.getworker(coroutine.running()) then
--     print ("I'm running as a background worker")
-- else
--     print ("No background worker found, so I'm on my own")
-- end
copas.getworker = function(t)
    if not t then
        return nil
    else
        -- specific one specified, have to go look for it
        -- check inactive list
        if inactiveworkers[t] then
            return inactiveworkers[t]
        end
        -- look in active list
        for _, v in ipairs(activeworkers) do
            if v.thread == t then
                -- found it, return it
                return v
            end
        end
        -- not found yet, is it now running?
        if runningworker and runningworker.thread == t then
            return runningworker
        end
        -- wasn't found
        return nil
    end
end

-------------------------------------------------------------------------------
-- Removes a worker thread
-- @param t worker table (as returned by <code>copas.addworker()</code>), or actual thread/coroutine
-- to be removed.
-- @return worker table or <code>nil</code> if it wasn't found
-- @see copas.addworker
copas.removeworker = function(t)
    if t then
        local tt = popthread(t)
        if tt then
            return tt -- succeeded, was in active list
        else
            -- check inactive list
            if type(t) == "table" then
                if inactiveworkers[t.thread] then
                    -- its a workertable in the inactive list
                    tt, inactiveworkers[t.thread] = inactiveworkers[t.thread], nil
                    return tt
                end
            else
                if inactiveworkers[t] then
                    -- its a worker coroutine in the inactive list
                    tt, inactiveworkers[t] = inactiveworkers[t], nil
                    return tt
                end
            end

            -- check running worker
            if not runningworker then
                return nil    -- not found
            else
                -- we're currently being run from a worker, so check whether its that one being removed
                if runningworker == t or runningworker.thread == t then
                    runningworker._hasbeenremoved = true
                    return runningworker
                end
            end
        end
    else
        return nil    -- not found
    end
end

local queueitem  -- trick luadoc
-------------------------------------------------------------------------------
-- Queue element to hold queued data in a worker queue. Queue elements are created
-- and returned by the the <code>worker:push()</code> method.
-- @name queueitem
-- @class table
-- @field cancelled flag; <code>true</code> when the element has been cancelled
-- @field completed flag; <code>true</code> when the element has been completed or cancelled
-- ('completed' is when the worker requests the next element by calling its <code>pop()</code> function
-- @field worker The worker table for which this queue element has been enqueued.
-- @field data the actual data
-- @field cancel method
-- @field complete method
-- @see queueitem.cancel
-- @see queueitem.complete
-- @see worker.push
queueitem = function(data, worker)
  return {
      data = data,
      worker = worker,  -- worker thread table
      cancelled = nil,  -- set to true when cancelled
      completed = nil,  -- set to true when completed
      -----------------------------------------------------------------------
      -- Cancels the queueItem.
      -- When cancelling both the <code>cancelled</code> and <code>completed</code>
      -- flag will be set. The cancel flag will prevent the data from being executed
      -- when it is being popped from the queue.
      -- @name queueitem.cancel
      -- @param self the queueitem
      -- @see queueitem
      -- @see worker.push
      cancel = function(self)
          self.cancelled = true
          self.completed = true
      end,
      -----------------------------------------------------------------------
      -- Completes the queueItem.
      -- The <code>completed</code> flag will be set.
      -- @name queueitem.complete
      -- @param self the queueitem
      -- @see queueitem
      -- @see worker.push
      complete = function(self)
          self.completed = true
      end,
    }
end

local _worker -- trick LuaDoc, its defined within copas.addworker below
-------------------------------------------------------------------------------
-- Worker object. These are created by the <code>addworker()</code> method.
-- @name worker
-- @class table
-- @field thread Holds the thread/coroutine for this worker
-- @field errhandler Holds the errorhandler for this worker
-- @field queue Holds the list of queue elements to be processed by the worker
-- @field push method
-- @field pop method
-- @field pause method
-- @see worker.push
-- @see worker.pop
-- @see worker.pause
-- @see copas.addworker
_worker = {}
_worker = nil
-------------------------------------------------------------------------------
-- Adds a worker thread. The workers will be executed when there is no IO nor
-- any expiring timer to run. The function will be started immediately upon
-- creating the coroutine for the worker. Calling <code>worker:push(data)</code> on
-- the returned worker table will enqueue data to be handled. The function can
-- fetch data from the queue through <code>self:pop()</code> which will
-- pop a new element from the workers queue. For lengthy operations where the code needs
-- to yield without popping a new element from the queue, call <code>self:pause()</code>.
-- @param func function to execute as the coroutine
-- @param errhandler function to handle any errors returned (must be a function
-- taking 2 arguments; 1 - coroutine generating the error, 2 - returned error)
-- @return worker table
-- @see copas.removeworker
-- @see worker
-- @usage local w = copas.addworker(function(queue)
--         -- do some initializing here... will be run immediately upon
--         -- adding the worker
--         while true do
--             data = queue:pop()    -- fetch data from queue, implictly yields the coroutine
--             -- handle the retrieved data here
--             print(data)
--             -- do some lengthy stuff
--             queue:pause()         -- implicitly yields
--             -- do more lengthy stuff
--         end
--     end)
-- -- enqueue data for the new worker
-- w:push("here is some data")
copas.addworker = function(func, errhandler)
    local popdata
    local t
    t = {
        thread = coroutine.create(func),
        errhandler = errhandler or _missingWerrorhandler,
        queue = {},
        ------------------------------------------------------
        -- Adds data to the worker queue. If the worker has died, it will return an error
        -- and nothing will be enqueued.
        -- @name worker.push
        -- @param self The worker table
        -- @param data Data to be added to the queue of the worker
        -- @return queueitem that was added to the worker queue, or <code>nil</code> and error message
        -- @usage local w = copas.addworker(myfunc)
        -- worker:push("some data")
		    -- @see worker
		    -- @see queueitem
        push = function(self, data)
                if coroutine.status(self.thread) == "dead" then return nil, "cannot push data to dead worker" end
                table.insert(self.queue, queueitem(data, self))
                if t ~= runningworker then
                    -- move worker to activelist, only if not active, active will be reinserted by dowork()
                    pushthread(self)
                end
                return self.queue[1]
            end,
        ------------------------------------------------------
        -- Retrieves data from the worker queue (and implicitly yields control). Note that this method
        -- implicitly yields the coroutine until new data has been pushed in the worker queue.
        -- @name worker.pop
        -- @param self The worker table
        -- @return data field of the next queueitem popped from the queue
        -- @see worker
        -- @see queueitem
        pop = function(self)
                assert(coroutine.running() == self.thread,"pop() may only be called by the workerthread itself")
                if self._lastpopped then
                    --contains previously popped data element, mark as completed
                    self._lastpopped:complete()
                end
                self._lastpopped = nil

                while not self._lastpopped do
                  coroutine.yield()
                  self._lastpopped = table.remove(self.queue, 1)
                  if self._lastpopped and self._lastpopped.cancelled then self._lastpopped = nil end
                end
                return self._lastpopped.data
            end,
        ------------------------------------------------------
        -- Yields control in case of lengthy operations. Similar to <code>pop()</code> except
        -- that this method does not pop a new element from the worker queue.
        -- @name worker.pause
        -- @param self The worker table
        -- @return <code>true</code>
        -- @see worker
        pause = function(self)
                assert(coroutine.running() == self.thread,"pause() may only be called by the workerthread itself")
                table.insert(self.queue,1,true)  -- insert fake element; true
                coroutine.yield()
                return table.remove(self.queue, 1) -- returns the fake element; true
            end,
        -- perform a single step for this worker
        step = function(self)
              local oldrunningworker = runningworker
              runningworker = self
              local success, err = coroutine.resume(self.thread)
              runningworker = oldrunningworker
              if not success then
                  pcall(self.errhandler, self.thread, err)
              end
              if coroutine.status(self.thread) ~= "dead" then
                  -- coroutine is still alive
                  if not self._hasbeenremoved then -- double check the worker didn't remove itself
                      if #self.queue > 0 then
                          pushthread(self)   -- add thread to end of queue again for next run
                      else
                          -- nothing in queue, so move to inactive list
                          inactiveworkers[self.thread] = self
                      end
                  else
                      self._hasbeenremoved = nil
                  end
              else
                  -- coroutine has died, cancel all that is left in the queue
                  if self._lastpopped then
                    if success then
                      self._lastpopped:complete()  -- exit was succesful, so mark as complete
                    else
                      self._lastpopped:cancel()    -- exit was an error, so mark as cancelled
                    end
                  end
                  while self.queue[1] do
                      local item = table.remove(self.queue, 1)
                      item:cancel()
                  end
              end
            end,
    }
    -- initialize coroutine by resuming, and store in list (queue empty, so inactive)
    local success, err = coroutine.resume(t.thread,t)
    if not success then pcall(t.errhandler, t.thread, err) end
    inactiveworkers[t.thread] = t
    return t
end

-------------------------------------------------------------------------------
-- Runs work on background threads
-- @return <code>true</code> if workers remain with work to do, <code>false</code> otherwise
local dowork = function()
    local t = popthread()   -- get next in line worker
    if t then
      t:step() -- execute it
    end
    return (#activeworkers > 0)
end


--=============================================================================
--               TIMERS
--=============================================================================

-------------------------------------------------------------------------------
-- Remove an armed timer from the list of running timers
local timerremove = function(t)
    if t == order then order = t.next end
    if t.previous then t.previous.next = t.next end
    if t.next then t.next.previous = t.previous end
    t.next = nil
    t.previous = nil
    if t.id then    -- fix: cancelling unarmed timer (no ID) error.
        timers[t.id] = nil
    end
end

-------------------------------------------------------------------------------
-- Add a newly armed timer to the list of timers running
local timeradd = function (t)
    -- check existence
    if t.id then
        timerremove(t)
    else
        -- create ID
        t.id = timerid
        timerid = timerid + 1
    end
    -- store in id ordered list
    timers[t.id]=t
    -- store in expire-time ordered list
    if not order then
        -- list empty, just add
        order=t
        order.next = nil
        order.previous = nil
    elseif t.when < order.when then
        -- insert at top of list
        t.next = order
        t.previous = nil
        order.previous = t
        order = t
    else
        local insertafter = order
        while insertafter.next and (insertafter.next.when <= t.when) do
            insertafter = insertafter.next
        end
        t.previous = insertafter
        t.next = insertafter.next
        insertafter.next = t
        if t.next then t.next.previous = t end
    end
end

-------------------------------------------------------------------------------
-- Check timerlist whether next up timer has expired already
-- @param precision up to how far in the future will a timer be considered expired
-- @return time until next timer expires
-- @return 0 if there is work to do (worker threads)
-- @return <code>nil</code> if there is neither a timer running nor there is work to do
local timercheck = function(precision)
    local result
    if order and (order.when <= (socket.gettime() + precision)) then
        -- a timer expired, so must execute
        local t = order
        order = order.next
        t:expire()
    else
        -- no timer to execute, so something else to do?
        dowork()
    end

    -- When is the next piece of work to be done
    if #activeworkers ~= 0 then
        result = 0  -- resume asap to get work done
    else
        if order then
            -- no work, wait for next timer
            result = order.when - socket.gettime()
        else
            -- nothing to do, no work nor timers, return nil
        end
    end

    return result
end


-- creates the exittimer that will force the exit
local startexittimer = function()
    assert(exittimer == nil, "exittimer already set")
    assert (exittimeout and exittimeout >= 0, "Bad exittimeout value; " .. tostring(exittimeout))
    exittimer = copas.newtimer(nil,function() exitingnow = true end, nil, false):arm(exittimeout)
end

-------------------------------------------------------------------------------
-- Creates a new timer.
-- After creating call the <code>arm</code> method of the new timer to actually
-- schedule it. REMARK: the background workers run in their own thread (coroutine)
-- and hence need to yield control when their operation takes too long, but
-- the timers run on the main loop, and hence the callbacks should never
-- yield, in those cases consider adding a worker through
-- <code>copas.addworker()</code> from the timer callback.
-- @param f_arm callback function to execute when the timer is armed
-- @param f_expire callback function to execute when the timer expires
-- @param f_cancel callback function to execute when the timer is cancelled
-- @param recurring (boolean) should the timer automatically be re-armed with
-- the same interval after it expired
-- @param f_error callback function to execute (in a <code>xpcall()</code> call)
-- when any of the other callbacks generates an error
-- @usage -- Create a new timer
-- local t = copas.newtimer(nil, function () print("hello world") end, nil, false, nil)
-- &nbsp;
-- -- Create timer and arm it immediately, to be run in 5 seconds
-- copas.newtimer(nil, function () print("hello world") end, nil, false, nil):arm(5)
-- &nbsp;
-- -- Create timer and arm it immediately, to be run now (function f is provide twice!) and again every 5 seconds
-- local f = function () print("hello world") end
-- copas.newtimer(f, f, nil, true, nil):arm(5)
-- @see timer.arm
-- @see timer.cancel
-- @see copas.cancelall
copas.newtimer = function(f_arm, f_expire, f_cancel, recurring, f_error)
    return {
        interval = nil,     -- must be set on first call to arm()
        recurring = recurring,
        -------------------------------------------------------------------------------
        -- Arms a previously created timer. When <code>arm()</code> is called on an already
        -- armed timer then the timer will be rescheduled, the <code>cancel</code> handler
        -- will not be called in this case, but the <code>arm</code> handler will run.
        -- @name timer.arm
        -- @param self timer table
        -- @param interval the interval after which the timer expires (in seconds). This must
        -- be set with the first call to <code>arm()</code> any additional calls will reuse
        -- the existing interval if no new interval is provided.
        -- @return the timer <code>t</code>, which allows chaining creating/arming calls, see example.
        -- @usage -- Create a new timer
        -- local f = function() print("hello world") end
        -- local t = copas.newtimer(nil, f, nil, false)
        -- t:arm(5)              -- arm it at 5 seconds
        -- -- which is equivalent to chaining the arm() call
        -- local t = copas.newtimer(nil, f, nil, false):arm(5)
        -- @see timer.cancel
        -- @see copas.newtimer
        arm = function(self, interval)
            self.interval = interval or self.interval
            assert(type(self.interval) == "number", "Interval not set, expected number, got " .. type(self.interval))
            self.when = socket.gettime() + interval
            -- if armed previously, remove myself
            timerremove(self)
            -- add to list
            timeradd(self)
            -- run ARM handler
            if f_arm then coxpcall(f_arm, f_error or _missingTerrorhandler) end
            return self
        end,
        expire = function(self)
            -- remove from list
            timerremove(self)
            -- execute
            if f_expire then coxpcall(f_expire, f_error or _missingTerrorhandler) end
            -- set again if recurring
            if self.recurring then
                self.when = socket.gettime() + (self.interval or 1)
                if not self._hasbeencancelled then
                    -- if the 'expire' handler cancelled the timer, it failed because
                    -- while executing it temporarily wasn't in the list
                    timeradd(self)
                end
            end
        end,
        -------------------------------------------------------------------------------
        -- Cancels a previously armed timer. This will run the <code>cancel</code> handler
        -- provided when creating the timer.
        -- @name timer.cancel
        -- @param self timer table
        -- @usage -- Create a new timer
        -- local t = copas.newtimer(nil, function () print("hello world") end, nil, false)
        -- t:arm(5)              -- arm it at 5 seconds
        -- t:cancel()            -- cancel it again
        -- @see timer.arm
        -- @see copas.newtimer
        cancel = function(self)
            -- remove self from timer list
            timerremove(self)
            self._hasbeencancelled = true   -- in case it is cancelled by the 'expire' handler
            -- run CANCEL handler
            if f_cancel then coxpcall(f_cancel, f_error or _missingTerrorhandler) end
        end,
    }
end

-------------------------------------------------------------------------------
-- Cancels all currently armed timers.
-- @see copas.exitloop
copas.cancelall = function()
    for _, t in pairs(timers) do
        t:cancel()
    end
end

--=============================================================================
--               COPAS CORE
--=============================================================================


-------------------------------------------------------------------------------
-- Executes a single Copas step followed by the execution of the first expired
-- (if any) timer in the timers list (it replaces the original <code>copas.step()</code>)
-- if there is no timer that expires then it will try to execute a worker step if available.
-- @param timeout timeout value (in seconds) to pass to the Copas step handler
-- @param precision see parameter <code>precision</code> at function <code>loop()</code>.
-- @return time in seconds until the next timer in the list expires, 0 if there is a worker
-- waiting for execution, or <code>nil</code> if there is no timer nor any worker.
-- @see copas.loop
copas.step = function (timeout, precision)
    copasstep(timeout)  -- call original copas step function
    return timercheck(precision or PRECISION)
end

-------------------------------------------------------------------------------
-- Executes an endless loop handling Copas steps and timers  (it replaces the original <code>copas.loop()</code>).
-- The loop can be terminated by calling <code>exitloop</code>.
-- @param timeout time out (in seconds) to be used. The timer list
-- will be checked at least every <code>timeout</code> period for expired timers. The
-- actual interval will be between <code>0</code> and <code>timeout</code> based on the next
-- timers expire time or worker threads being available. If not provided, it defaults to 5 seconds.
-- @param precision the precision of the timer (in seconds). Whenever the timer
-- list is checked for expired timers, a timer is considered expired when the exact
-- expire time is in the past or up to <code>precision</code> seconds in the future.
-- It defaults to 0.02 if not provided.
-- @see copas.step
-- @see copas.exitloop
-- @see copas.isexiting
copas.loop = function (timeout, precision)
    timeout = timeout or TIMEOUT
    precision = precision or PRECISION
    exiting = false
    exitingnow = false
    exittimeout = nil
    exiteventthreads = {}
    exittimer = nil
    -- do initial event
    if copas.eventer then
        -- raise event for starting, execute them now, run threads until complete,
        -- no sockets, no timers, no workers, just the event threads
        copas:dispatch(copas.events.loopstarting):finish()
        -- raise event for started, this one will be executed on the main loop once it starts running
        copas:dispatch(copas.events.loopstarted)
    end
    -- execute single timercheck and get time to next timer expiring
    local nextstep = timercheck(precision) or timeout
    -- enter the loop
    while not exitingnow do
        -- verify next expiry time
        if nextstep > timeout then
            nextstep = timeout
        elseif nextstep < 0 then
            nextstep = 0
        end
        -- run copas step and timercheck
        nextstep = copas.step(nextstep, precision) or timeout

        -- check on exit strategy
        if exiting and not exitingnow then
            if (next(exiteventthreads.queueitems)) then
                -- we still have threads in the table
                -- now cleanup exit events that are done
                for k,v in pairs(exiteventthreads.queueitems) do
                    if v.cancelled or v.completed then
                        -- this one is done, clear it
                        exiteventthreads[k] = nil
                    end
                end
            end
            -- Are we done with the exit events and no timer has been set?
            if not next(exiteventthreads.queueitems) and not exittimer and exittimeout then
                -- table is empty and we have a timeout that has not yet been set; so set it now.
                startexittimer()
            end
            -- do we still have workers to complete?
            if not next(activeworkers) then
                -- so we're exiting and the workers are all done, we're ready to exit
                exitingnow = true
            end
        end
    end

    -- Loop is done now, so cleanup and finalize exit code.

    if exittimer then
        exittimer:cancel()
        exittimer = nil
    end
    -- cancel timers if required
    if exitcanceltimers then
        copas.cancelall()
    end
    -- run the last event 'loopstopped'
    if exittimeout and exittimeout < 0 then
        -- we had to exit immediately, no events should run, so nothing to do here
    else
        -- run the last event
        if copas.eventer then
            -- raise event, add workers table as eventdata to inform about unfinished worker threads
            -- run threads until complete, no sockets, no timers, no workers, just the event threads
            copas:dispatch(copas.events.loopstopped, activeworkers):finish()
        end
    end
    exiting = nil
    exitingnow = nil
    exittimeout = nil
    exiteventthreads = nil
end

-------------------------------------------------------------------------------
-- Indicator of the loop running or exiting.
-- @return <ul>
-- <li><code>nil</code>: the loop is not running, </li>
-- <li><code>false</code>: the loop is running, or </li>
-- <li><code>true</code>: the loop is scheduled to stop</li></ul>
-- @usage if copas.isexiting() ~= nil then
--     -- loop is currently running, make it exit after the worker queue is empty and cancel any timers
--     copas.exitloop(nil, false)
-- end
-- @see copas.loop
-- @see copas.exitloop
copas.isexiting = function()
    return exiting
end

-------------------------------------------------------------------------------
-- Instructs Copas to exit the loop. It will wait for any background workers to complete their queue.
-- If the <code>copas.eventer</code> is used then the timeout will only start after the
-- <code>copas.events.loopstopping</code> event has been completely handled.
-- @param timeout Timeout (in seconds) after which to forcefully exit the loop,
-- abandoning any workers still running.
-- <ul><li><code>nil</code> or negative: no timeout, continue running until all workers have emptied their queues</li>
-- <li><code>&lt 0</code>: exit immediately after next loop iteration, do not
-- wait for workers nor the <code>copas.events.loopstopping/loopstopped</code> events</li> to complete
-- (timers will still be cancelled if set to do so)</ul>
-- @param keeptimers (boolean) if <code>true</code> then the active timers will NOT be cancelled, otherwise
-- <code>copas.cancelall()</code> will be called to properly cancel all running timers.
-- @see copas.loop
-- @see copas.isexiting
copas.exitloop = function(timeout, keeptimers)
    if exiting == false then
        exiting = true
        exittimeout = tonumber(timeout)
        exitcanceltimers = not keeptimers
        exittimer = nil
        if exittimeout and exittimeout < 0 then
            exitingnow = true
        else
            exitingnow = false
        end
        if copas.eventer then
            exiteventthreads = copas:dispatch(copas.events.loopstopping)
        else
            exiteventthreads = { queueitems = {} }       -- not used, so make empty table
        end
    end
end

--=============================================================================
--               UTILITY FUNCTIONS
--=============================================================================

-------------------------------------------------------------------------------
-- Calls a function delayed, after the specified amount of time.
-- An example use is a call that requires communications to be running already,
-- but if you start the Copas loop, it basically blocks; classic chicken-egg. In this case use the
-- <code>delayedexecutioner</code> to call the method in 0.5 seconds, just before
-- starting the CopasTimer loop. Now when the method actually executes, communications
-- will be online already. The internals use a timer, so it is executed on the main
-- loop and should not be suspended by calling <code>yield()</code>.
-- @param delay delay in seconds before calling the function
-- @param func function to call
-- @param ... any arguments to be passed to the function
-- @see copas.newtimer
-- @usage local t = socket.gettime()
-- copas.delayedexecutioner(5, function(txt)
--         print(txt .. " and it was " .. socket.gettime() - t .. " to be precise.")
--     end, "This should display in 5 seconds from now.")

copas.delayedexecutioner = function (delay, func, ...)
    local list = {...}
    local f = function()
        func(unpack(list))
    end
    copas.newtimer(nil, f, nil, false):arm(delay)
end


-------------------------------------------------------------------------------
-- Executes a handler function after a specific condition has been met
-- (non-blocking wait). This is implemented using a timer, hence both the
-- <code>condition()</code> and <code>handler()</code> functions run on the main
-- thread and should never yield.
-- @param interval interval (in seconds) for checking the condition
-- @param timeout timeout value (in seconds) after which the operation fails
-- (note that the <code>handler()</code> will still be called)
-- @param condition a function that is called repeatedly. It will get the
-- additional parameters specified to <code>waitforcondition()</code>. The
-- function should return <code>true</code> or <code>false</code> depending on
-- whether the condition was met.
-- @param handler the handler function that will be executed. It will
-- <strong>always</strong> be executed. The first argument to the handler will
-- be <code>true</code> if the condition was met, or <code>false</code> if the
-- operation timed-out, any additional parameters provided to
-- <code>waitforcondition()</code> will be passed after that.
-- @param ... additional parameters passed on to both the <code>condition()</code>
-- and <code>handler()</code> functions.
-- @return timer that verifies the condition.
-- @usage local count = 1
-- function check(param)
--     print("Check count ", count, ". Called using param = ", param)
--     count = count + 1
--     return (count == 10)
-- end
-- &nbsp
-- function done(conditionmet, param)
--     if conditionmet then
--         print("The condition was met when count reached ", count - 1,". Called using param = ", param)
--     else
--         print("Failed, condition was not met. Called using param = ", param)
--     end
-- end
-- &nbsp
-- copas.waitforcondition(0.1, 5, check, done, "1234567890")
copas.waitforcondition = function (interval, timeout, condition, handler, ...)
    assert (interval,'No interval provided')
    assert (timeout,'No timeout provided')
    assert (condition,'No condition function provided')
    assert (handler,'No handler function provided')

    local arglist = {...}
    local timeouttime = socket.gettime() + timeout
    local t
    t = copas.newtimer(nil, function()
            -- timer function, check condition
            local result, err = pcall(condition, unpack(arglist))
            if result == false then
                -- we had an error
                print("copas.waitforcondition; condition check returned error: " .. tostring(err))
                t:cancel()
            else
                local conditionmet = err
                if conditionmet then
                    -- completed, cancel timer, call handler with success
                    t:cancel()
                    local result, err = pcall(handler, conditionmet, unpack(arglist))
                    if not result then
                        -- we had an error calling the handler
                        print("copas.waitforcondition; handler returned error after condition was met: " .. tostring(err))
                    end
                else
                    if timeouttime < socket.gettime() then
                        -- timeout, call handler with first argument 'false' to indicate timeout
                        t:cancel()
                        local result, err = pcall(handler, conditionmet, unpack(arglist))
                        if not result then
                            -- we had an error
                            print("copas.waitforcondition; handler returned error after waiting timed-out: " .. tostring(err))
                        end
                    else
                        -- Not met, but also not timed-out yet, do nothing, let timer continue
                    end
                end
            end
        end, nil, true):arm(interval)
    return t
end

-- return existing/modified copas table
return copas
