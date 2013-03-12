
local copas = require ("copas.timer")
local socket = require ("socket")
require("coxpcall")
local pcall, xpcall = copcall, coxpcall

local servers = {}
setmetatable(servers, {__mode = "k"})   -- server table weak keys
local clients = {}
setmetatable(clients, {__mode = "k"})   -- client table weak keys
local workers = {}
setmetatable(workers, {__mode = "kv"})  -- workers table, weak keys (handler function) and values (worker tables)

-------------------------------------------------------------------------------
-- The eventer is an event dispatcher. It works on top of Copas Timer using the
-- workers to create event handlers. The eventer uses a publish/subscribe mechanism with servers and clients.
-- The servers should register before firing any events, and the clients should
-- subscribe to server events.<br/>
-- <br/>Dispatching pushes event data in the worker queues of the eventhandlers. This means that one or more workers
-- have been scheduled to each handle one or more enqueued events, but they will not be executed when an event is dispatched. Execution follows later when
-- the Copas Timer loop continues to handle its worker queues in the background.
-- The eventer will create a global table; <code>copas.eventer</code>, but that should generally not be used except for
-- the <code>copas.eventer.decorate()</code> method which will provide an object/table with event capabilities.<br/>
-- <br/>This module is part of Copas Timer and is free software under the MIT/X11 license.
-- @copyright 2011-2013 Thijs Schreijer
-- @release Version 1.0, Timer module to extend Copas with a timer and worker capability


-------------------------------------------------------------------------------
-- local function to do the actual dispatching by creating new threads
-- @param client unique id of the client (use 'self' for objects)
-- @param server unique id of the server that generated the event
-- @param handler function to use as coroutine
-- @param ... any additional parameters to be included in the event
-- @return item queued in the worker queue
local disp = function(handler, client, server, event, ...)
    if not workers[handler] then
        -- worker not found, so create one
        workers[handler] = copas.addworker(function(queue)
                -- wrap the handler in a function that cleans up when it returns
                local success, err = pcall(handler, queue)
                -- the handler should never return, but if it does (error?), clean it up
                copas.removeworker(workers[handler])
                workers[handler] = nil
                if not success then
                    error("Copas.Eventer eventhandler encountered an error:" .. tostring(err))
                end
            end)
    end

    return workers[handler]:push({client = client, server = server, name = event, n = select("#", ...), ...  })
end

------------------ functions for the decorator -------------------->> START
-- see the decorate() function
local decor = {

    -------------------------------------------------------------------------------
    -- Table (as a set) with the event strings for this server.
    -- @name server.events
    -- @see decorate
    -- @example# -- create an object and decorate it with event capabilities
    -- local obj1 = {}
    -- copas.eventer.decorate(obj1, { "start", "error", "stop" } )
    -- &nbsp
    -- print(obj1.events.start)   --> "start"
    -- print(obj1.events.error)   --> "error"
    -- print(obj1.events.stop)    --> "stop"
    events = function() end,         -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Dispatches an event for this server. It functions as a shortcut to
    -- <code>serverdispatch()</code>.
    -- @name server.dispatch
	-- @param self the (decorated) server object
    -- @param event event string of the event to dispatch
    -- @param ... any additional event parameters
    -- @see server.events
    -- @see decorate
    -- @see serverdispatch
	-- @return event table
    -- @example# -- create an object and decorate it with event capabilities
    -- local obj1 = {}
    -- copas.eventer.decorate(obj1, { "start", "error", "stop" } )
    -- &nbsp
    -- ..... do some stuff, subscribe to events, start the copas loop, etc.
    -- &nbsp
    -- -- raise the start event and include th starttime as an extra
    -- -- parameter to be passed to the eventhandlers
    -- local e = obj1:dispatch(obj1.events.start, socket.gettime())
    -- -- now wait for the event to be completely handled
    -- e:waitfor()
    dispatch = function(self, event, ...)
        assert(event and self.events[event],"No valid event string provided")
        return copas.eventer.serverdispatch(self, event, ...)
    end,

    -------------------------------------------------------------------------------
    -- Subscribes a client to the events of this server. It functions as a shortcut
    -- to <code>clientsubscribe()</code>.
    -- @name server.subscribe
	-- @param self the (decorated) server object
    -- @param client the client identifier (usually the client object table)
    -- @param handler the handler function for the event
    -- @param event the event to subscribe to or <code>nil</code> to subscribe to all events
    -- @see server.events
    -- @see decorate
    -- @see clientsubscribe
    -- @example# -- create an object and decorate it with event capabilities
    -- local obj1 = {}
    -- copas.eventer.decorate(obj1, { "start", "error", "stop" } )
    -- &nbsp
    -- -- create another object and subscribe to events of obj1
    -- local obj2 = {
    --     eventhandler = function(eventqueue)
	--         while true do
	--             local event = eventqueue:pop()
	--             local self = event.client
	--             -- handle the retrieved data here
	--             print(event.client)    -->  "table: 03AF0910"
	--             print(event.server)    -->  "table: 06A30AD3"
	--             print(event.name)      -->  "stop"
	--             print(event.n)         -->  "2"
	--             print(event[1])        -->  "arg1"
	--             print(event[2])        -->  "arg2"
	--         end
	--     end,
    -- }
    -- obj1:subscribe(obj2, obj1.events.stop)
    -- &nbsp
    -- ..... do some stuff, start the copas loop, etc.
    -- &nbsp
    -- -- raise the stop event
    -- local e = obj1:dispatch(obj1.events.stop, "arg1", "arg2")
    subscribe = function(self, client, handler, event)
        assert(client, "client cannot be nil")
        assert(type(handler) == "function", "handler must be a function, got " .. type(handler))
        if event then
            assert(self.events[event],"Invalid event string provided")
        end
        return copas.eventer.clientsubscribe(client, self, handler, event)
    end,

    -------------------------------------------------------------------------------
    -- Unsubscribes a client from the events of this server. It functions as a shortcut
    -- to <code>clientunsubscribe()</code>.
    -- @name server.unsubscribe
	-- @param self the (decorated) server object
    -- @param client the client identifier (usually the client object table), must be the same as
    -- used while subscribing.
    -- @param event the event to unsubscribe from or <code>nil</code> to unsubscribe from all events
    -- @see server.events
    -- @see decorate
    -- @see clientunsubscribe
    unsubscribe = function(self, client, event)
        assert(client, "client cannot be nil")
        if event then
            assert(self.events[event],"Invalid event string provided")
        end
        return copas.eventer.clientunsubscribe(client, self, event)
    end,
}
------------------ functions for the decorator -------------------->> END

------------------ functions for the event table ------------------>> START
local et = {

    -------------------------------------------------------------------------------
    -- The event string. (this is a field, not a function)
    -- @name event.event
	-- @see server.events
    event = function() end,         -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Table/list with queueitems created. One for each event subscription dispatched.
	-- (this is a field, not a function)
    -- @name event.queueitems
    queueitems = function() end,       -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Cancels all event related queueitems from the copas background worker queues.
    -- Queueitems will remain in the event object itself, but will be flagged
    -- as cancelled.
    -- @name event.cancel
	-- @param self the event table
    cancel = function(self)
        for _, item in pairs(self.queueitems) do
            item:cancel()
        end
    end,

    -------------------------------------------------------------------------------
    -- Waits for an event to be completed. That is; all event queueitems have been completed by the workers,
    -- this does not include additional events spawned from them. Current thread/worker will
    -- yield while waiting (so cannot be used from the mainthread!).
    -- @name event.waitfor
	-- @param self the event table
    -- @param timeout timeout (in seconds), use <code>nil</code> for no timeout
    -- @return <code>true</code> when completed, or <code>nil, "timeout"</code> in case of a timeout.
    -- @see event.finish
    waitfor = function(self, timeout)
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
                    w:pause()  -- its a copastimer workerthread
                else
                    -- not a workerthread, just yield????
                    coroutine.yield()
                end
                -- only here (after being resumed) the timer might have expired and set the result and error values
            end
        end
        return (err == nil), err
    end,

    -------------------------------------------------------------------------------
    -- Waits for an event to be completed in a blocking mode. That is; all event queueitems have been completed by the workers
    -- (this does not include additional events spawned from them). Current thread will
    -- NOT yield while waiting, it will only process the event related queueitems. It is blocking, so timers, sockets
    -- and workers will not run in the mean time, so executing this method may take a long time so use carefully!<br/>
    -- If it should not block, then use <code>waitfor()</code>.
    -- @name event.finish
	-- @param self the event table
    -- @param timeout timeout (in seconds), use <code>nil</code> for no timeout
    -- @return <code>true</code> when completed, or <code>nil, "timeout"</code> in case of a timeout (in case of a timeout, the
	-- unfinished queueitems will remain in the worker queues, they will not be cancelled).
    -- @see event.waitfor
    finish = function(self, timeout)
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
    end,
}
------------------ functions for the event table ------------------>> END



copas.eventer = {

    -------------------------------------------------------------------------------
    -- registers a server that will fire events.
	-- The prefered way is to use the <code>decorate()</code> function.
    -- @param server a unique key to identify the specific server, can be a string or
    -- table, or whatever, as long as it is unique
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
    -- unregisters a server that will no longer fire events
    -- @param server a unique key to identify the specific server, can be a string or
    -- table, or whatever, as long as it is unique
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
    -- subscribes a client to events.
	-- The prefered way is to use the <code>decorate()</code> function and then call <code>subscribe()</code>
    -- @param client unique client parameter (self)
    -- @param server a unique key to identify the specific server
    -- @param handler event handler function to be called. It will be called with
    -- signature <code>handler(client, server, event, [additional event parameters...])</code>
    -- or in method notation; <code>client:handler(server, event, [additional event parameters...])</code>.
    -- @param event string, <code>nil</code> to subscribe to all events
	-- @see decorate
	-- @see server.subscribe
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
    -- unsubscribes a client from events.
	-- The prefered way is to use the <code>decorate()</code> function and then call <code>unsubscribe()</code>
    -- @param client unique client parameter (self)
    -- @param server a unique key to identify the specific server, <nil>nil</nil> to unsubscribe all
    -- @param event string, <code>nil</code> to unsubscribe from all events
	-- @see decorate
	-- @see server.unsubscribe
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
    -- dispatches an event from a server.
	-- The prefered way is to use the <code>decorate()</code> function and then call <code>dispatch()</code>
    -- @param server a unique key to identify the specific server
    -- @param event string
    -- @param ... other arguments to be passed on as arguments to the eventhandler
    -- @return event object, see the 'see' section below.
    -- @see event.event
    -- @see event.threads
    -- @see event.cancel
    -- @see event.waitfor
    -- @see event.finish
	-- @see decorate
	-- @see server.dispatch
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
    -- <li><code>server:subscribe(client, handler, event)</code></li>
    -- <li><code>server:unsubscribe(client, event)</code></li>
    -- <li><code>server:dispatch(event, ...)</code></li>
    -- <li><code>server.events</code></li>
    -- </ul>Additionally it will register the object as event server. The methods are
	-- shortcuts to the <code>eventer</code> methods <code>clientsubscribe, clientunsubscribe, serverdispatch</code>.
    -- @param server The event server object that will be decorated with the methods and tables listed above.
    -- @param events A list of event strings. This list will be copied to a new table (as a set) and stored in <code>server.events</code>
    -- @see clientsubscribe
    -- @see clientunsubscribe
    -- @see serverdispatch
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
        server.subscribe = decor.subscribe
        server.unsubscribe = decor.unsubscribe
        server.dispatch = decor.dispatch

        -- register the client as an event server
        copas.eventer.serverregister(server, server.events)
    end,

    -------------------------------------------------------------------------------
    -- Gets a list of subscriptions of a particular client.
    -- @param client the client for which to get the subscriptions
    -- @return <code>nil</code> if the client has no subscriptions, otherwise a table
    -- with subscriptions. The result table is keyed by 'server' and each value
    -- is a list of eventstrings the client is subscribed to on this server.
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
    -- @return <code>nil</code> if the server is unregistered, otherwise a table
    -- with subscriptions. The result table is keyed by 'event string' and each value
    -- is a list of clients that is subscribed to this event.
    -- @example# local list = copas.eventer.getclients(copas)     -- get list of Copas clients
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

-- Register own events and the copas events with the eventer.
local eevents      -- do this local, so LuaDoc picks up the next statement
-------------------------------------------------------------------------------
-- Event list for eventer (events generated by it).
-- @class table
-- @name copas.eventer.events
-- @field register Fired whenever a new server registers events (note: 'copas' and
-- 'copas.eventer' will have been registered before any client had a chance to
-- subscribe, so these subscriptions cannot be caught by using this event)
-- @field unregister Fired whenever a server unregisters its events
-- @field subscribe Fired whenever a client subscribes to events
-- @field unsubscribe Fired whenever a client unsubscribes from events
eevents = { "register", "unregister", "subscribe", "unsubscribe" }
copas.eventer.decorate(copas.eventer, eevents)

local cevents      -- do this local, so LuaDoc picks up the next statement
-------------------------------------------------------------------------------
-- Event list for Copas itself. The event structure for Copas will only be
-- initialized when the eventer is used.
-- @class table
-- @name copas.events
-- @field loopstarting Fired <strong>before</strong> the copas loop starts. It will
-- immediately be finished (see <code>event.finish()</code>). So while the event threads
-- run there will be no timers, sockets, nor workers running. Only the threads created
-- for the 'loopstarting' event will run.
-- @field loopstarted Fired when the Copas loop has started, by now timers, sockets
-- and workers are running.
-- @field loopstopping Fired the Copas loop starts exiting. For as long as not all
-- event threads (for this specific event) have finished, the timers, sockets and
-- workers will keep running.
-- @field loopstopped Fired <strong>after</strong> the Copas loop has finished, this event will
-- immediately be finished (see <code>event.finish()</code>), so the timers,
-- sockets and workers no longer run.
-- @see event.finish
cevents = { "loopstarting", "loopstarted", "loopstopping", "loopstopped" }
copas.eventer.decorate(copas, cevents )


-- return eventer
return copas.eventer
