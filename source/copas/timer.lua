-------------------------------------------------------------------------------
-- Copas Timer is a module that adds a timer capability to the Copas scheduler.
-- It provides the same base functions <code>step</code> and <code>loop</code>
-- as Copas (it actually replaces them) except that it will also check for (and
-- run) timers expiring and run background workers if there is no IO or timer to
-- handle. It also adds an <code>exitloop</code> method that allows for a
-- controlled exit from the loop.<br/>
-- <br/>To use the module, make sure to 'require' copastimer before any other
-- code 'requires' copas. This will make sure that the copas version in use will
-- be updated before any other code uses it. The changes should be transparent to
-- your existing code. It should be required as; <code>local copas =
-- require("copas.timer")</code> because it returns the global <code>copas</code>
-- table and not a separate timer table.<br/>
-- <br/>There is a difference between the 2 background mechanisms provided; the
-- timers run on the main loop, they should never yield and return quickly, but they
-- are precise. On the other hand the workers run in their own thread (coroutine)
-- and can be yielded if they take too long, but are less precisely timed.<br/>
-- <br/>The workers are dispatched from a rotating queue, so when a worker is up to run
-- it will be removed from the queue, resumed, and (if not finished) added at the end
-- of the queue again.
-- <br/><strong>Important:</strong> the workers should never wait for work to come in. They must
-- exit when done. New work should create a new worker. The reason is that while
-- there are worker threads available the luasocket <code>select</code> statement is called
-- with a 0 timeout (non-blocking) to make sure background work is completed asap.
-- If a worker waits for work (call <code>yield()</code> when it has nothing to do)
-- it will create a busy-wait situation.<br/>
-- <br/>Copas Timer is free software under the MIT/X11 license.
-- @copyright 2011 Thijs Schreijer
-- @release Version 0.4.1, Timer module to extend Copas with a timer and worker capability

local copas = require("copas")
local socket = require("socket")
require("coxpcall")

local timerid = 1		-- counter to create unique timerid's
local timers = {}		-- table with timers by their id
local order = nil		-- linked list with timers sorted by expiry time, 'order' being the first to expire
local PRECISION = 0.02  -- default precision value
local TIMEOUT = 5       -- default timeout value
local workers = {}      -- list with background worker threads
local copasstep = copas.step    -- store original function
local copasloop = copas.loop    -- store original function
local exiting           -- indicator of loop status
local exitingnow        -- indicator that loop must exit immediately
local exiteventthreads  -- table with exit threads to be completed before exiting
local exitcanceltimers  -- should timers be cancelled after ending the loop
local exittimeout       -- timeout for workers to exit
local exittimer         -- timerhandling the exit timeout


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
    elseif t.when < order.when then
        -- insert at top of list
        t.next = order
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
-- Will be used as error handler if none provided
local _missingerrorhandler = function(...)
	print("Error in timer callback/worker thread : ",  ... )
    print(debug.traceback)
end

-------------------------------------------------------------------------------
-- Adds a background worker to the end of the thread list
-- @param t thread table (see copas.addworker()) to add to the list
local pushthread = function(t)
    table.insert(workers, t)
end

-------------------------------------------------------------------------------
-- Pops background worker from the thread list
-- @param t thread table (see copas.addworker()) or actual thread (coroutine)
-- to remove from the list. If nil then just the one on top will be popped.
-- @return the popped thread table, or nil if it wasn't found
local popthread = function(t)
    if #workers == 0 then
        return nil
    end

    if not t then
        -- get the first one
        return table.remove(workers, 1)
    else
        -- specific one specified, have to go look for it
        for i, v in ipairs(workers) do
            if v == t or v.thread == t then
                -- found it, return it
                return table.remove(workers, i)
            end
        end
        -- wasn't found
        return nil
    end
end

-------------------------------------------------------------------------------
-- Returns a background worker
-- @param t thread (coroutine) to get from the list
-- @return the thread table (as earlier returned by <code>addworker()</code>)
-- or <code>nil</code> if it wasn't found
-- @see copas.addworker
-- @usage# if copas.getworker(coroutine.running()) then
--     print ("I'm running as a background worker")
-- else
--     print ("No background worker found, so I'm on my own")
-- end
copas.getworker = function(t)
    if #workers == 0 then
        return nil
    end

    if not t then
        return nil
    else
        -- specific one specified, have to go look for it
        for i, v in ipairs(workers) do
            if v == t or v.thread == t then
                -- found it, return it
                return v
            end
        end
        -- wasn't found
        return nil
    end
end

-------------------------------------------------------------------------------
-- Removes a worker thread
-- @param t thread table (as returned by <code>copas.addworker()</code>), or actual thread
-- to be removed.
-- @return <code>true</code> if success or <code>false</code> if it wasn't found
-- @see copas.addworker
copas.removeworker = function(t)
    if t then
        if popthread(t) then
            return true -- succeeded
        else
            return false    -- not found
        end
    else
        return false    -- not found
    end
end

-------------------------------------------------------------------------------
-- Adds a worker thread. The threads will be executed when there is no IO nor
-- any expiring timer to run. The <code>args</code> key of the returned table can be modified
-- while the thread is still scheduled. After the <code>args</code> have been passed to
-- <code>resume</code> the <code>args</code> will be set to <code>nil</code>. If <code>args</code> is set again, then the
-- next time the thread is up to run, the new set of <code>args</code> will be passed on to the
-- thread. This enables feeding the thread with data.
-- @param func function to execute in the coroutine
-- @param args table with arguments for the function
-- @param errhandler function to handle any errors returned
-- @return table with keys <code>thread, args, errhandler</code>
-- @see copas.removeworker
-- @usage# copas.addworker(function(...)
--         local t = {...}
--         print(table.concat(t, " "))
--     end, { "Hello", "world" })
copas.addworker = function(func, args, errhandler)
    local t = {
        thread = coroutine.create(func),
        args = args,
        errhandler = errhandler or _missingerrorhandler,
    }
    pushthread(t)
    return t
end

-------------------------------------------------------------------------------
-- Runs work on background threads
-- @return <code>true</code> if threads remain with work to do
-- @return <code>nil</code> if nothing remains to be done
local dowork = function()
    local t
    while not t do
        t = popthread()   -- get next in line worker
        if not t then break end     -- no more workers, so exit loop
        if t.thread and coroutine.status(t.thread) == "dead" then t = nil end
    end
    if t then
        -- execute this thread
        t.args = t.args or {}
        local success, err = coroutine.resume(t.thread, unpack(t.args))
        if not success then
            t.errhandler(nil, err)
        end
        if coroutine.status(t.thread) ~= "dead" then
            t.args = nil    -- handled those, so drop them
            pushthread(t)   -- add thread to end of queue again for next run
        end
    end
    return (#workers > 0)
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
    if #workers ~= 0 then
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


-------------------------------------------------------------------------------
-- Indicator of the loop running or exiting.
-- @return <ul>
-- <li><code>nil</code>: the loop is not running, </li>
-- <li><code>false</code>: the loop is running, or </li>
-- <li><code>true</code>: the loop is scheduled to stop</li></ul>
-- @usage# if copas.isexiting() ~= nil then
--     -- loop is currently running, make it exit after the worker queue is empty and cancel any timers
--     copas.exitloop(nil, false)
-- end
-- @see copas.loop
-- @see copas.exitloop
copas.isexiting = function()
    return exiting
end

-- creates the exittimer that will force the exit
local startexittimer = function()
    assert(exittimer == nil, "exittimer already set")
    assert (exittimeout and exittimeout >= 0, "Bad exittimeout value; " .. tostring(exittimeout))
    exittimer = copas.newtimer(nil,function() exitingnow = true end, nil, false):arm(exittimeout)
end

-------------------------------------------------------------------------------
-- Instructs Copas to exit the loop. It will wait for any background workers to complete.
-- If the <code>copas.eventer</code> is used then the timeout will only start after the
-- <code>copas.events.loopstopping</code> event has been completely handled.
-- @param timeout Timeout (in seconds) after which to forcefully exit the loop,
-- abandoning any workerthreads still running.
-- <ul><li><code>nil</code> or negative: no timeout, continue running until worker queue is empty</li>
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
            exiteventthreads = { threads = {} }       -- not used, so make empty table
        end
    end
end

-------------------------------------------------------------------------------
-- Creates a new timer.
-- After creating call the <code>arm</code> method of the new timer to actually
-- schedule it. REMARK: the background workers run in their own thread (coroutine)
-- and hence need to <code>yield</code> when their operation takes to long, but
-- the timers run on the main loop, and hence the callbacks should never
-- <code>yield()</code>, in those cases consider adding a worker through
-- <code>copas.addworker()</code> from the timer callback.
-- @param f_arm callback function to execute when the timer is armed
-- @param f_expire callback function to execute when the timer expires
-- @param f_cancel callback function to execute when the timer is cancelled
-- @param recurring (boolean) should the timer automatically be re-armed with
-- the same interval after it expired
-- @param f_error callback function to execute when any of the other callbacks
-- generates an error
-- @usage# -- Create a new timer
-- local t = copas.newtimer(nil, function () print("hello world") end, nil, false, nil)
-- &nbsp;
-- -- Create timer and arm it immediately, to be run in 5 seconds
-- copas.newtimer(nil, function () print("hello world") end, nil, false, nil):arm(5)
-- &nbsp;
-- -- Create timer and arm it immediately, to be run now (function f is provide twice!) and again every 5 seconds
-- local f = function () print("hello world") end
-- copas.newtimer(f, f, nil, true, nil):arm(5)
-- @see t:arm
-- @see t:cancel
-- @see copas.cancelall
copas.newtimer = function(f_arm, f_expire, f_cancel, recurring, f_error)
    return {
        interval = 1,
        recurring = recurring,
        -------------------------------------------------------------------------------
        -- Arms a previously created timer
        -- @name t:arm
        -- @param interval the interval after which the timer expires (in seconds)
        -- @return the timer <code>t</code>
        -- @usage# -- Create a new timer
        -- local t = copas.newtimer(nil, function () print("hello world") end, nil, false)
        -- t:arm(5)              -- arm it at 5 seconds
        -- t:cancel()            -- cancel it again
        -- @see t:cancel
        -- @see copas.newtimer
        arm = function(self, interval)
            self.interval = interval or self.interval
            self.when = socket.gettime() + interval
            -- add to list
            timeradd(self)
            -- run ARM handler
            if f_arm then coxpcall(f_arm, f_error or _missingerrorhandler) end
            return self
        end,
        expire = function(self)
            -- remove from list
            timerremove(self)
            -- execute
            if f_expire then coxpcall(f_expire, f_error or _missingerrorhandler) end
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
        -- Cancels a previously armed timer
        -- @name t:cancel
        -- @usage# -- Create a new timer
        -- local t = copas.newtimer(nil, function () print("hello world") end, nil, false)
        -- t:arm(5)              -- arm it at 5 seconds
        -- t:cancel()            -- cancel it again
        -- @see t:arm
        -- @see copas.newtimer
        cancel = function(self)
            -- remove self from timer list
            timerremove(self)
            self._hasbeencancelled = true   -- in case it is cancelled by the 'expire' handler
            -- run CANCEL handler
            if f_cancel then coxpcall(f_cancel, f_error or _missingerrorhandler) end
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
            if (next(exiteventthreads.threads)) then
                -- we still have threads in the table
                -- now cleanup exit events that are done
                for k,v in pairs(exiteventthreads.threads) do
                    if coroutine.status(v) == "dead" then
                        -- this one is done, clear it
                        exiteventthreads[k] = nil
                    end
                end
            end
            -- Are we done with the exit events and no timer has been set?
            if not next(exiteventthreads.threads) and not exittimer and exittimeout then
                -- table is empty and we have a timeout that has not yet been set; so set it now.
                startexittimer()
            end
            -- do we still have workers to complete?
            if not next(workers) then
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
            copas:dispatch(copas.events.loopstopped, workers):finish()
        end
    end
    exiting = nil
    exitingnow = nil
    exittimeout = nil
    exiteventthreads = nil
end


--=============================================================================
--=============================================================================
--
--      UTILITY FUNCTIONS BASED ON COPASTIMER
--
--=============================================================================
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
-- @usage# local t = socket.gettime()
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


-- return existing/modified copas table
return copas
