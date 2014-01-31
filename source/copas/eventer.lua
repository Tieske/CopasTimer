-------------------------------------------------------------------------------
-- The eventer is an event dispatcher. It works on top of Copas Timer using the
-- `worker` to create event handlers. The eventer uses a publish/subscribe mechanism with servers and clients.
-- The servers should register before firing any events, and the clients should
-- subscribe to server events.
-- 
-- Dispatching pushes event data in the `worker` queues of the eventhandlers. This means that one or more workers
-- have been scheduled to each handle one or more enqueued events, but they will not be executed when an event 
-- is dispatched. Execution follows later when
-- the Copas Timer loop continues to handle its worker queues in the background.
-- The events have 2 synchronization methods; `finish` and `waitfor`.
--
-- The eventer will create a table within the Copas module; `copas.eventer`, but that 
-- should generally not be used except for
-- the `copas.eventer.decorate` method which will provide an object/table with event capabilities.
--
-- @author Thijs Schreijer, http://www.thijsschreijer.nl
-- @license Copas Timer is free software under the MIT/X11 license.
-- @copyright 2011-2014 Thijs Schreijer
-- @release Version 1.0, Timer module to extend Copas with a timer, worker and event capabilities


local copas = require ("copas.timer")
local socket = require ("socket")
require("coxpcall")
local pcall, xpcall = copcall, coxpcall
local errorhandler

local servers = {}
setmetatable(servers, {__mode = "k"})   -- server table weak keys
local clients = {}
setmetatable(clients, {__mode = "k"})   -- client table weak keys
local workers = {}
setmetatable(workers, {__mode = "kv"})  -- workers table, weak keys (handler function) and values (worker tables)


-- Will be used as error handler for eventhandlers.
-- @param err the error object
local _missingerrorhandler = function(err)
    return debug.traceback("copas.eventer encountered an error while executing an eventhandler: " .. tostring(err))
end

local notobjects = {
  ["function"] = 1,
  ["nil"] = 1,
  ["number"] = 1,
  ["string"] = 1,
  ["boolean"] = 1,
  --["table"] = 1, 
  ["function"] = 1, 
  ["thread"] = 1,
  --["userdata"] = 1, 
}
local nulerrhandler = function() end

-- local function to do the actual dispatching by creating new threads
-- @param handler function to use as coroutine
-- @param client unique id of the client (use 'self' for objects)
-- @param server unique id of the server that generated the event
-- @param event ?
-- @param ... any additional parameters to be included in the event
-- @return item queued in the worker queue
local disp = function(handler, client, server, event, ...)
    if not workers[handler] then
      -- worker not found, so create one
      if notobjects[type(client)] then
        -- client is not an object type, so install handler without object/self notation
        workers[handler] = copas.addworker(function(queue)
                -- wrap the handler in a function that cleans up when it returns
                local ok, err = xpcall(function() handler(queue) end, errorhandler or _missingerrorhandler)
                -- the handler should never return, but if it does (error?), clean it up
                copas.removeworker(workers[handler])
                workers[handler] = nil
                if not ok then
                  error(err)  -- must throw error, so copas.timer cleans up properly
                end
            end, nullerrhandler) -- use null handler to disable copas.timer errorhandler
      else
        -- client is an object type, so install handler with object/self notation
        workers[handler] = copas.addworker(client, function(obj, queue)
                -- wrap the handler in a function that cleans up when it returns
                local ok, err = xpcall(function() handler(obj, queue) end, errorhandler or _missingerrorhandler)
                -- the handler should never return, but if it does (error?), clean it up
                copas.removeworker(workers[handler])
                workers[handler] = nil
                if not ok then
                  error(err)  -- must throw error, so copas.timer cleans up properly
                end
            end, nullerrhandler) -- use null handler to disable copas.timer errorhandler
      end
    end

    return workers[handler]:push({client = client, server = server, name = event, n = select("#", ...), ...  })
end

--=============================================================================
--               DECORATOR FUNCTIONS
--=============================================================================

-------------------------------------------------------------------------------
-- Decorator functions.
-- These functions are applied to decorated objects/tables
-- @section decorator
-- @see decorate

-------------------------------------------------------------------------------
-- Decorated event server.
-- This class describes the elements applied to an event server by the `decorate` function
-- @type event_server

local event_server = {}

-------------------------------------------------------------------------------
-- Table (as a set) with the event strings for this server. The set generated is
-- protected, so accessing a non-existing element will throw an error.
-- @table events
-- @see decorate
-- @usage -- create an object and decorate it with event capabilities
-- local obj1 = {}
-- copas.eventer.decorate(obj1, { "start", "error", "stop" } )
-- 
-- print(obj1.events.start)     --> "start"
-- print(obj1.events.error)     --> "error"
-- print(obj1.events.stop)      --> "stop"
-- print(obj1.events.not_found) --> throws an error
event_server.events = {}

-------------------------------------------------------------------------------
-- Dispatches an event for this server. It functions as a shortcut to
-- `serverdispatch`.
-- @tparam string event one of the elements of `event_server.events` indicating the event to dispatch
-- @param ... any additional event parameters
-- @see event_server.events
-- @see decorate
-- @return `event` 
-- @usage -- create an object and decorate it with event capabilities
-- local obj1 = {}
-- copas.eventer.decorate(obj1, { "start", "error", "stop" } )
-- 
-- ..... do some stuff, subscribe to events, start the copas loop, etc.
-- 
-- -- raise the start event and include th starttime as an extra
-- -- parameter to be passed to the eventhandlers
-- local e = obj1:dispatch(obj1.events.start, socket.gettime())
-- -- now wait for the event to be completely handled
-- e:waitfor()
function event_server:dispatch(event, ...)
    assert(event and self.events[event],"No valid event string provided")
    return copas.eventer.serverdispatch(self, event, ...)
end

-------------------------------------------------------------------------------
-- Subscribes a client to the events of this server. It functions as a shortcut
-- to `clientsubscribe`. See the example below for the format of the
-- event data delivered to the event handler.
-- @param client the client identifier (usually the client object table)
-- @tparam function handler the handler function for the event. For the function signature see `clientsubscribe`.
-- @tparam string event the event (from the list `event_server.events`) to subscribe to or `nil` to subscribe to all events
-- @see decorate
-- @usage -- create an object and decorate it with event capabilities
-- local obj1 = {}
-- copas.eventer.decorate(obj1, { "start", "error", "stop" } )
-- 
-- -- create another object and subscribe to events of obj1
-- local obj2 = {
--     eventhandler = function(self, eventqueue)
--         while true do
--             local event = eventqueue:pop()
--             -- handle the retrieved data here
--             print(event.client)         -->  "table: 03AF0910" == obj2
--             print(event.server)         -->  "table: 06A30AD3" == obj1
--             print(event.name)           -->  "stop"
--             print(event.n)              -->  "2"
--             print(event[1])             -->  "arg1"
--             print(event[2])             -->  "arg2"
--         end
--     end,
-- }
-- obj1:subscribe(obj2, obj2.eventhandler, obj1.events.stop)
-- 
-- ..... do some stuff, start the copas loop, etc.
-- 
-- -- raise the stop event
-- local e = obj1:dispatch(obj1.events.stop, "arg1", "arg2")
function event_server:subscribe(client, handler, event)
    assert(client, "client cannot be nil")
    assert(type(handler) == "function", "handler must be a function, got " .. type(handler))
    if event then
        assert(self.events[event],"Invalid event string provided")
    end
    return copas.eventer.clientsubscribe(client, self, handler, event)
end

-------------------------------------------------------------------------------
-- Unsubscribes a client from the events of this server. It functions as a shortcut
-- to `clientunsubscribe`.
-- @param client the client identifier (usually the client object table), must be the same as used while subscribing.
-- @tparam string event the event (from the list `event_server.events`) to unsubscribe from or `nil` to unsubscribe from all events
-- @see decorate
function event_server:unsubscribe(client, event)
    assert(client, "client cannot be nil")
    if event then
        assert(self.events[event],"Invalid event string provided")
    end
    return copas.eventer.clientunsubscribe(client, self, event)
end


--=============================================================================
--               EVENT FUNCTIONS
--=============================================================================

-------------------------------------------------------------------------------
-- Event.
-- Class returned for a dispatched event, with synchonization capabilities
-- @type event
-- @see event_server:dispatch
-- @field event (string) the event name (from the list `event_server.events`)

local et = {}

-------------------------------------------------------------------------------
-- Table/list with queueitems created. One for each event subscription dispatched.
-- @table event.queueitems
et.queueitems = {}

-------------------------------------------------------------------------------
-- Cancels all event related queueitems from the Copas background worker queues.
-- Queueitems will remain in the event object itself, but will be flagged
-- as cancelled.
-- @function event:cancel
function et:cancel()
    for _, item in pairs(self.queueitems) do
        item:cancel()
    end
end

-------------------------------------------------------------------------------
-- Waits for an event to be completed in a non-blocking mode. That is; all event queueitems have been completed by the workers,
-- this does not include additional events spawned from them. Current thread/worker will
-- yield while waiting (so cannot be used from the mainthread!).
-- @function event:waitfor
-- @param timeout timeout (in seconds), use `nil` for no timeout
-- @return `true` when completed, or `nil, "timeout"` in case of a timeout.
-- @see event:finish
function et:waitfor(timeout)
    local done = false
    local err
    local t

    -- if a timeout is set create a timer
    if timeout and timeout>0 then
        t = copas.newtimer(nil, function()
                                    done = true
                                    err = "timeout"
                                end, nil, false):arm(timeout)
    end
    while not done do
        -- assume done, then check all threads
        done = true
        for _, item in pairs(self.queueitems) do
            if not item.completed and not item.cancelled then
                done = false    -- too bad, not finished, so back to false
                break
            end
        end
        if done then
            -- we're done, so cancel the timeout timer if present
            if t then
                t:cancel()
            end
        else
            -- not done, so yield to let other threads/coroutines finish their work
            local w = copas.getworker(coroutine.running())
            if w then
                w:pause()  -- I'm currently running on a copastimer workerthread
            else
                -- not a workerthread, just yield????
                coroutine.yield()
            end
            -- only here (after being resumed) the timer might have expired and set the result and error values
        end
    end
    return (err == nil), err
end

-------------------------------------------------------------------------------
-- Waits for an event to be completed in a blocking mode. That is; all event queueitems have been completed by the workers
-- (this does not include additional events spawned from them). Current thread will
-- NOT yield while waiting, it will only process the event related queueitems. It is blocking, so timers, sockets
-- and workers will not run in the mean time, so executing this method may take a long time so use carefully!<br/>
-- If it should not block, then use `event:waitfor`.
-- @function event:finish
-- @param timeout timeout (in seconds), use `nil` for no timeout
-- @return `true` when completed, or `nil, "timeout"` in case of a timeout (in case of a timeout, the unfinished queueitems will remain in the worker queues, they will not be cancelled).
-- @see event:waitfor
function et:finish(timeout)
    if not timeout then
        timeout = 365 * 24 * 60 * 60    -- use 1 year as 'no timeout', should suffice
    end
    local t = socket.gettime() + (tonumber(timeout) or 0)

    -- create a thread table list by looking up all worker thread tables
    local list = {}
    for _,item in ipairs(self.queueitems) do
        if item.cancelled or item.completed then
          -- nothing to do, already done
        else
          table.insert(list, item)   -- insert in our tracking list
          if not item.worker.queue[1] == item then
              -- so our element is somewhere further down the queue, we have to move it up to first position
              for i, item2 in ipairs(item.worker.queue) do
                if item2 == item then
                  -- found it, move it to 1st
                  table.remove(item.worker.queue,i)
                  table.insert(item.worker.queue,1,item2)
                  break
                end
              end
          end
        end
    end

    -- now deal with the threads in the list
    local done = false
    while t > socket.gettime() do
        done = true
        for _,item in ipairs(list) do
            if not item.cancelled and not item.completed then
                -- this one is not finished, so back to false, and resume routine
                done = false
                copas.removeworker(item.worker)  -- must remove because step() will add it again to the end
                item.worker:step()               -- of the workers list and we don't want doubles
            end
        end
        if done then break end
    end
    if done then
        return true
    else
        return nil, "timeout"
    end
end


-------------------------------------------------------------------------------
-- Eventer core functions.
-- Generally these functions are not used, except for `decorate` which implements regular
-- object oriented access to all others.
-- @section core


copas.eventer = {

    -------------------------------------------------------------------------------
    -- Sets the error handler function to be used when calling eventhandlers.
    -- @param handler the error handler function (the errorhandler will be passed along
    -- to an `xpcall` call)
    seterrorhandler = function(handler)
        assert(type(handler) == "function", "The handler must be a function, got " .. type(handler))
        errorhandler = handler
    end,

    -------------------------------------------------------------------------------
    -- Registers a server that will fire events.
    -- The prefered way is to use the `decorate` function.
    -- @param server a unique key to identify the specific server. Usually a table/object, but can be a string or whatever, as long as it is unique
    -- @param eventlist list of strings with event names (table keys are unused, only values, so may also be a set)
    -- @see decorate
    serverregister = function(server, eventlist)
        assert(server, "Server parameter cannot be nil")
        assert(not servers[server],"Server is already registered")
        assert(type(eventlist) == "table", "EventList must be a table with strings")
        -- build event table with listeners
        local events = {}    -- table with events of server
        setmetatable(events, {__mode = "k"})   -- event client table weak keys
        for _, v in pairs(eventlist) do
            events[v] = {}      -- client list for this event
        end
        servers[server] = events
        -- raise my own event
        copas.eventer:dispatch(copas.eventer.events.register, server, eventlist)
        return true
    end,

    -------------------------------------------------------------------------------
    -- Unregisters a server that will no longer fire events
    -- @param server a unique key to identify the specific server
    serverunregister = function(server)
        assert(server, "Server parameter cannot be nil")
        if servers[server]  then
            servers[server] = nil
            for _, ct in pairs(clients) do
                ct[server] = nil
            end
            -- raise my own event
            copas.eventer:dispatch(copas.eventer.events.unregister, server)
        end
        return true
    end,

    -------------------------------------------------------------------------------
    -- Subscribes a client to events.
    -- The prefered way is to use the `decorate` function and then call `event_server:subscribe`.
    -- @param client unique client parameter (usually self)
    -- @param server a unique key to identify the specific server (usually the server object/table)
    -- @param handler event handler function to be called, it will be wrapped as a background worker-coroutine. If `client` is either a table or a userdata (object types), then the handler will be called with 2 arguments; `client` and `worker`, otherwise it will only get `worker`. See `event_server:subscribe` for an example of how the parameters are passed to the handler.
    -- @tparam string event event name, or `nil` to subscribe to all events
    -- @see decorate
    -- @see event_server:subscribe
    clientsubscribe = function(client, server, handler, event)
        assert(client, "Client parameter cannot be nil")
        assert(type(handler) == "function", "Invalid handler parameter, expected function, got " .. type(handler))
        assert(server, "Server parameter cannot be nil")
        local stable = servers[server]  -- server table
        assert(stable, "Server not found")
        if event then
            -- specific event
            local etable = stable[event]
            assert(etable, "Event not found for this server")
            etable[client] = handler
        else
            -- all events
            for _, etable in pairs (stable) do
                etable[client] = handler
            end
        end
        if not clients[client] then
            local s = {}
            setmetatable(s, {__mode = "k"})   -- server table weak keys
            clients[client] = s
        end
        clients[client][server] = server
        -- raise my own event
        copas.eventer:dispatch(copas.eventer.events.subscribe, client, server, event)
        return true
    end,

    -------------------------------------------------------------------------------
    -- Unsubscribes a client from events.
    -- The prefered way is to use the `decorate` function and then call `event_server:unsubscribe`.
    -- @param client unique client parameter (usually self)
    -- @param server a unique key to identify the specific server (usually the server object/table), or `nil` to unsubscribe from all servers
    -- @tparam string event event string, or `nil` to unsubscribe from all events
    -- @see decorate
    -- @see event_server:unsubscribe
    clientunsubscribe = function(client, server, event)
        assert(client, "Client parameter cannot be nil")

        local unsubserv = function(server)
            -- unsubscribe from 1 specific server
            local stable = servers[server]
            if not event then
                -- unsubscribe from all events
                for _, etable in pairs(stable) do
                    etable[client] = nil
                end
            else
                -- unsubscribe from specific event
                if stable[event] then
                    stable[event][client] = nil
                end
            end
        end

        local servsubleft = function(server)
            -- check if the client has subscriptions left on this server
            local stable = servers[server]
            for _, etable in pairs(stable) do
                if etable[client] then
                    return true
                end
            end
            return false
        end

        local ct = clients[client]  -- client table
        if ct then
            -- this client is registered
            if server then
                -- unsubscribe from a specific server
                unsubserv(server)
                if not servsubleft(server) then
                    -- no subscriptions left on this server, remove server from client list
                    ct[server] = nil
                end
            else
                -- unsubscribe from all servers
                for _, svr in pairs(clients[client]) do
                    unsubserv(svr)
                    if not servsubleft(server) then
                        -- no subscriptions left on this server, remove server from client list
                        ct[svr] = nil
                    end
                end
            end
            -- check if the client has any subscriptions left, remove if not
            if not next(ct) then
                clients[client] = nil
            end
            -- raise my own event
            copas.eventer:dispatch(copas.eventer.events.unsubscribe, client, server, event)
        end
    end,


    -------------------------------------------------------------------------------
    -- Dispatches an event from a server.
    -- The prefered way is to use the `decorate` function and then call `event_server:dispatch`
    -- @param server a unique key to identify the specific server
    -- @tparam string event event string
    -- @param ... other arguments to be passed on as arguments to the eventhandler
    -- @return `event` 
    -- @see decorate
    -- @see event_server:dispatch
    serverdispatch = function(server, event, ...)
        local tt = {}   -- thread table

        -- we're up and running, so check what's coming in
        assert(event, "Event parameter cannot be nil")
        assert(server, "Server parameter cannot be nil")
        local stable = servers[server]
        assert(stable, "Server not found")
        local etable = stable[event]
        assert(etable, "Event not found; " .. tostring(event))

        -- call event specific handlers
        local item
        for cl, hdlr in pairs(etable) do
            item = disp(hdlr, cl, server, event, ...)
            table.insert(tt,item)
        end

        -- return event table
        return {
            queueitems = tt,
            event = event,
            cancel = et.cancel,
            finish = et.finish,
            waitfor = et.waitfor,
        }
    end,

    -------------------------------------------------------------------------------
    -- Decorates an object as an event server. It will provide the object with the
    -- following methods/tables; <ul>
    -- <li>`event_server:subscribe`</li>
    -- <li>`event_server:unsubscribe`</li>
    -- <li>`event_server:dispatch`</li>
    -- <li>`event_server.events`</li>
    -- </ul>Additionally it will register the object as event server. The methods are
    -- shortcuts to the `eventer` methods `clientsubscribe, clientunsubscribe, serverdispatch`. See `event_server` for some examples.
    -- @param server The event server object that will be decorated with the methods and tables listed above.
    -- @param events A list of event strings (see `event_server.events`). This list will be copied to a new table (as a set) and stored in `server.events`
    -- @see event_server
    decorate = function(server, events)

        assert(type(server) == "table", "Server must be a table, got " .. tostring(server))
        assert(type(events) == "table", "Eventlist must be a table, got " .. tostring(events))
        -- fixup event table to be a set
        local ev = {}
        for _,v in pairs(events) do
            ev[v] = v
        end
        setmetatable(ev, {
            __index = function(t, key)
            local val = rawget(t, key)
            if not val then
              error("'"..tostring(key).."' is not a valid event in this set", 2)
            end
            return val
          end
          })

        -- decorate server table with the eventlist and the functions
        server.events = ev
        server.subscribe = event_server.subscribe
        server.unsubscribe = event_server.unsubscribe
        server.dispatch = event_server.dispatch

        -- register the client as an event server
        copas.eventer.serverregister(server, server.events)
    end,

    -------------------------------------------------------------------------------
    -- Gets a list of subscriptions of a particular client.
    -- @param client the client for which to get the subscriptions
    -- @return `nil` if the client has no subscriptions, otherwise a table with subscriptions. The result table is keyed by 'server' and each value is a list of eventstrings the client is subscribed to on this server.
    getsubscriptions = function(client)
        assert(client, "Client cannot be nil")
        if clients[client] then
            local result = {}
            -- loop through the list of servers this client subscribed to
            for _, server in pairs(clients[client]) do
                local elist = {}
                -- loop through all events from this server
                for event, etable in pairs(servers[server]) do
                    if etable[client] then
                        -- we have a subscription to this event, so store eventstring
                        table.insert(elist, event)
                    end
                end
                result[server] = elist
            end
            return result
        else
            return nil
        end
    end,

    -------------------------------------------------------------------------------
    -- Gets a list of clients of a particular server.
    -- @param server the server for which to get the subscribed clients
    -- @return `nil` if the server is unregistered, otherwise a table with subscriptions. The result table is keyed by 'event string' and each value is a list of clients that is subscribed to this event.
    -- @usage local list = copas.eventer.getclients(copas)     -- get list of Copas clients
    -- list = list[copas.events.loopstarted]            -- get clients of the 'loopstarted' event
    -- print ("the Copas 'loopstarted' event has " .. #list .. " clients subscribed.")
    getclients = function(server)
        assert(server, "Server cannot be nil")
        local stable = servers[server]
        if stable then
            local result = {}
            -- loop through server table
            for event, etable in pairs(stable) do
                local clist = {}
                for client, _ in pairs(etable) do
                    table.insert(clist, client)
                end
                result[event] = clist
            end
            return result
        else
            -- server wasn't found
            return nil
        end
    end,
}


-------------------------------------------------------------------------------
-- Eventer and Copas events.
-- List of events as generated by Copas and the Eventer itself, once the `eventer` module has been loaded.
-- @section own_events


-- Register own events and the copas events with the eventer.

-------------------------------------------------------------------------------
-- Event generated by the eventer.
-- @table copas.eventer.events
-- @field register Fired whenever a new server registers events (note: 'copas' and 'copas.eventer' will have been registered before any client had a chance to subscribe, so these subscriptions cannot be caught by using this event)
-- @field unregister Fired whenever a server unregisters its events
-- @field subscribe Fired whenever a client subscribes to events
-- @field unsubscribe Fired whenever a client unsubscribes from events
copas.eventer.events = { "register", "unregister", "subscribe", "unsubscribe" }
copas.eventer.decorate(copas.eventer, copas.eventer.events) -- replaces eventer.events by a set of itself

-------------------------------------------------------------------------------
-- Events generated by Copas. The event structure for Copas will only be
-- initialized when the eventer is used.
-- @table copas.events
-- @field loopstarting Fired <strong>before</strong> the copas loop starts. It will immediately be finished (see `event:finish`). So while the event threads run there will be no timers, sockets, nor workers running. Only the threads created for the 'loopstarting' event will run.
-- @field loopstarted Fired when the Copas loop has started, by now timers, sockets and workers are running.
-- @field loopstopping Fired when the Copas loop starts exiting (see `exitloop`). For as long as not all event threads (for this specific event) have finished, the timers, sockets and workers will keep running.
-- @field loopstopped Fired <strong>after</strong> the Copas loop has finished, this event will immediately be finished (see `event:finish`), so the timers, sockets and workers no longer run.
-- @see event:finish
copas.events = { "loopstarting", "loopstarted", "loopstopping", "loopstopped" }
copas.eventer.decorate(copas, copas.events)  -- replaces copas.events by a set of itself


-- return eventer
return copas.eventer
