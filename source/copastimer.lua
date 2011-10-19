-------------------------------------------------------------------------------
-- Copas Timer is a module that adds a timer capability to the Copas scheduler.
-- It provides the same base functions <code>step</code> and <code>loop</code>
-- as Copas except that it will also check for timers expiring. In addition to
-- those standard Copas functions, it also adds an <code>isexiting</code> field
-- that allows for a controlled exit from the loop.<br/>
-- Copas Timer is free software and uses the same license as Lua.
-- @copyright 2011 Thijs Schreijer
-- @release Version 0.3, Timer module to extend Copas with a timer capability

local copas = require("copas")
local socket = require("socket")
require("coxpcall")

local timerid = 1		-- counter to create unique timerid's
local timers = {}		-- table with timers by their id
local order = nil		-- linked list with timers sorted by expiry time, 'order' being the first to expire
local PRECISION = 0.02  -- default precision value
local TIMEOUT = 5       -- default timeout value
local copasstep = copas.step    -- store original function
local copasloop = copas.loop    -- store original function

-------------------------------------------------------------------------------
-- Remove an armed timer from the list of running timers
local timerremove = function(t)
    if t == order then order = t.next end
    if t.previous then t.previous.next = t.next end
    if t.next then t.next.previous = t.previous end
	t.next = nil
	t.previous = nil
    timers[t.id] = nil
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
	print("Error in timer callback: ",  ... )
    print(debug.traceback)
end

-------------------------------------------------------------------------------
-- Check timerlist whether next up timer has expired already
-- @param precision up to how far in the future will a timer be considered expired
-- @return time until next timer expires
local timercheck = function(precision)
    local result
    if order then
        if order.when <= (socket.gettime() + precision) then
            -- expired, so must execute
            local t = order
            order = order.next
            t:expire()
        end
        -- find next event
        if order then
            result = order.when - socket.gettime()
        end
    end
    return result
end


-------------------------------------------------------------------------------
-- Indicator of the loop running or exiting (it is a field, not a function!).
-- Possible values; <ul>
-- <li><code>nil</code>: the loop is not running, </li>
-- <li><code>false</code>: the loop is running, or </li>
-- <li><code>true</code>: the loop is scheduled to stop after
-- the current iteration.</li></ul>
-- @usage# if copas.isexiting ~= nil then
--     -- loop is currently running, make it exit after the next iteration
--     copas.isexiting = true
-- end
copas.isexiting = function() end	-- dummy to trick luadoc
copas.isexiting = nil

-------------------------------------------------------------------------------
-- Creates a new timer.
-- After creating call the <code>arm</code> method of the new timer to actually
-- schedule it.
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
copas.newtimer = function(f_arm, f_expire, f_cancel, recurring, f_error)
    return {
        interval = 1,
        recurring = recurring,
-------------------------------------------------------------------------------
-- Arms a previously created timer
-- @name <code>t:</code>arm</code>
-- @param interval the interval after which the timer expires (in seconds)
-- @usage# -- Create a new timer
-- local t = copas.newtimer(nil, function () print("hello world") end, nil, false)
-- t:arm(5)              -- arm it at 5 seconds
-- t:cancel()            -- cancel it again
        arm = function(self, interval)
            self.interval = interval or self.interval
            self.when = socket.gettime() + interval
            -- add to list
            timeradd(self)
            -- run ARM handler
            if f_arm then coxpcall(f_arm, f_error or _missingerrorhandler) end
        end,
        expire = function(self)
            -- remove from list
            timerremove(self)
            -- execute
            if f_expire then coxpcall(f_expire, f_error or _missingerrorhandler) end
            -- set again if recurring
            if self.recurring then
                self.when = socket.gettime() + (self.interval or 1)
                timeradd(self)
            end
        end,
-------------------------------------------------------------------------------
-- Cancels a previously armed timer
-- @name <code>t:</code>cancel</code>
-- @usage# -- Create a new timer
-- local t = copas.newtimer(nil, function () print("hello world") end, nil, false)
-- t:arm(5)              -- arm it at 5 seconds
-- t:cancel()            -- cancel it again
        cancel = function(self)
            -- remove self from timer list
            timerremove(self)
            -- run CANCEL handler
            if f_cancel then coxpcall(f_cancel, f_error or _missingerrorhandler) end
        end,
    }
end

-------------------------------------------------------------------------------
-- Cancels all currently armed timers.
-- Call this method after exiting the loop, to make sure all timers are properly
-- cancelled and their cancel callback methods have been executed.
copas.cancelall = function()
    for _, t in pairs(timers) do
        t:cancel()
    end
end

-------------------------------------------------------------------------------
-- Executes a single Copas step followed by the execution of the first expired
-- (if any) timer in the timers list.
-- @param timeout timeout value (in seconds) to pass to the Copas step handler
-- @param precision see parameter <code>precision</code> at function <code>loop()</code>.
-- @return time in seconds until the next timer in the list expires, or
-- <code>nil</code> if there is none
copas.step = function (timeout, precision)
    copasstep(timeout)  -- call original copas step function
    return timercheck(precision or PRECISION)
end

-------------------------------------------------------------------------------
-- Executes an endless loop handling Copas steps and timers.
-- The loop can be terminated by setting <code>isexiting</code> to true. When
-- exiting the loop, consider call <code>cancelall()</code> to make sure all
-- armed timers get properly cancelled and their <code>cancel</code> callbacks
-- get called properly.
-- @param timeout time out (in seconds) to be used. The timer list
-- will be checked at least every <code>timeout</code> period for expired timers. The
-- actual interval will be between <code>0.001</code> and <code>timeout</code> based on the next
-- timers expire time. If not provided, it defaults to 5 seconds.
-- @param precision the precision of the timer (in seconds). Whenever the timer
-- list is checked for expired timers, a timer is considered expired when the exact
-- expire time is in the past or up to <code>precision</code> seconds in the future.
-- It defaults to 0.02 if not provided.
copas.loop = function (timeout, precision)
    timeout = timeout or TIMEOUT
    precision = precision or PRECISION
    copas.isexiting = false
    -- execute single timercheck and get time to next timer expiring
    local nextstep = timercheck(precision) or timeout
    -- enter the loop
    while not copas.isexiting do
        -- verify next expiry time
        if nextstep > timeout then
            nextstep = timeout
        elseif nextstep < 0.001 then
            nextstep = 0.001
        end
        -- run copas step and timercheck
        nextstep = copas.step(nextstep, precision) or timeout
    end
    copas.isexiting = nil
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
-- will be online already.
-- @param delay delay in seconds before calling the function
-- @param func function to call
-- @param ... any arguments to be passed to the function
copas.delayedexecutioner = function (delay, func, ...)
    local list = {...}
    local f = function()
        func(unpack(list))
    end
    copas.newtimer(nil, f, nil, false):arm(delay)
end

-------------------------------------------------------------------------------
-- Checks the network connection of the system and detects changes in connection or IP adress.
-- Call repeatedly to check status for changes. With every call include the previous results to compare with.
-- @param oldState (table) previous result to compare with, or <code>nil</code> if not called before
-- @return changed (boolean) same as <code>newstate.changed</code> (see below).
-- @return newState (table) same as regular info from <code>socket.dns</code> calls, but extended with;
-- <ul><li><code>localhostname </code>= (string) name of localhost (only field that can be set, defaults to <code>'localhost'</code>)</li>
-- <li><code>localhostip   </code>= (string) ip address resolved for <code>localhostname</code></li>
-- <li><code>connected     </code>= (string) either <code>'yes'</code>, <code>'no'</code>, or <code>'loopback'</code> (loopback means connected to localhost, no external connection)</li>
-- <li><code>changed       </code>= (boolean) <code>true</code> if <code>oldstate</code> is different on either; <code>name</code>, <code>connected</code>, or <code>ip[1]</code> properties</li></ul>
-- @usage# function test()
--     print ("TEST: entering endless check loop, change connection settings and watch the changes come in...")
--     require ("base")	-- from stdlib to pretty print the table
--     local change, data
--     while true do
--         change, data = copas.checknetwork(data)
--         if change then
--             print (prettytostring(data))
--         end
--     end
-- end
function copas.checknetwork (oldState)
	oldState = oldState or {}
	oldState.alias = oldState.alias or {}
	oldState.ip = oldState.ip or {}
	local sysname = socket.dns.gethostname()
	local newState = {
				name = sysname or "no name resolved",
				localhostname = oldState.localhostname or "localhost",
				localhostip = socket.dns.toip(oldState.localhostname or "localhost") or "127.0.0.1",
				alias = {},
				ip = {},
			}
	if not sysname then
		newState.connected = "no"
	else
		local sysip, data = socket.dns.toip(sysname)
		if sysip then
			newState.ip = data.ip
			newState.alias = data.alias
			if newState.ip[1] == newState.localhostip then
				newState.connected = "loopback"
			else
				newState.connected = "yes"
			end
		else
			newState.connected = "no"
		end
	end
	newState.changed = (oldState.name ~= newState.name or oldState.ip[1] ~= newState.ip[1] or newState.connected ~= oldState.connected)
	return newState.changed, newState
end

-------------------------------------------------------------------------------
-- Creates a timer to repeatedly check the network for changes in its connection state. It basically wraps the <code>checknetwork</code> function.
-- The first check will run when the timer gets armed.
-- @param handler callback function to be called when the network state changes. 2 arguments; <code>newState</code>, <codce>oldState</code>.
-- @param interval optional interval for checking in seconds. If provided the timer will be armed immediately, otherwise it has to be armed afterwards.
-- @param errhandler optional errorhandler to be used for the <code>handler</code> callback function
-- @return timer
function copas.addcheck(handler, interval, errhandler)
	assert(type(handler) == "function", "Error, no handler function provided")
	if interval then
		assert(type(interval) == "number", "Error in parameter 'interval', expected number, got " .. type(interval))
		assert(interval > 0, "Error in parameter 'interval', must be greater than 0, got " .. tostring(interval))
	end
	local oldState
	local checker = function()
			local changed, newState = copas.checknetwork(oldState)
			if changed then
				coxpcall(function() handler(newState, oldState) end, errhandler or _missingerrorhandler)
			end
			oldState = newState
		end
	if interval then
		return copas.newtimer(checker,checker,nil,true, nil):arm(interval)
	else
		return copas.newtimer(checker,checker,nil,true, nil)
	end
end


-- return existing copas table
return copas
