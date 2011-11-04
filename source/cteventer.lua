
local copas = require ("copastimer")
local socket = require ("socket")

local servers = {}
setmetatable(servers, {__mode = "k"})   -- server table weak keys
local clients = {}
setmetatable(clients, {__mode = "k"})   -- client table weak keys


-------------------------------------------------------------------------------
-- Dispatching creates a separate copastimer background worker (thread/coroutine) for each client that has
-- to receive the event. The eventer will create a global; <code>copas.eventer</code>
-- for itself. The eventer uses servers and client, the servers should register
-- before firing any events, and the client should subscribe to server events.

-------------------------------------------------------------------------------
-- local function to do the actual dispatching by creating new threads
-- @param client unique id of the client (use 'self' for objects)
-- @param server unique id of the server that generated the event
-- @param handler function to use as the callback
-- @param ... any additional parameters to be included in the event
-- @return thread (coroutine) scheduled in the background worker of copastimer
local disp = function(handler, client, server, ...)
    local wkr = copas.addworker(handler, {client, server, ...}, nil)
    return wkr.thread
end

------------------ functions for the decorator -------------------->> START
-- see the decorate() function
local decor = {

    -------------------------------------------------------------------------------
    -- Table (as a set) with the event strings for this server.
    -- @name s:events
    -- @see decorate
    events = function() end,         -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Dispatches an event for this server. It functions as a shortcut to
    -- <code>serverdispatch()</code>.
    -- @name s:dispatch
    -- @param event event string of the event to dispatch
    -- @param ... any additional event parameters
    -- @see s:events
    -- @see decorate
    -- @see serverdispatch
    dispatch = function(self, event, ...)
        assert(event and self.events[event],"No valid event string provided")
        return copas.eventer.serverdispatch(self, event, ...)
    end,

    -------------------------------------------------------------------------------
    -- Subscribes a client to the events of this server. It functions as a shortcut
    -- to <code>clientsubscribe()</code>.
    -- @name s:subscribe
    -- @param client the client identifier (usually the client object table)
    -- @param handler the handler function for the event
    -- @param event the event to subscribe to or <code>nil</code> to subscribe to all events
    -- @see s:events
    -- @see decorate
    -- @see clientsubscribe
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
    -- @name s:unsubscribe
    -- @param client the client identifier (usually the client object table), must be the same as
    -- used while subscribing.
    -- @param event the event to unsubscribe from or <code>nil</code> to unsubscribe from all events
    -- @see s:events
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
    -- @name e:event
    event = function() end,         -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Table with threads (coroutines) created. One for each event handler dispatched.
    -- @name e:threads
    threads = function() end,       -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Removes all event related workers from the copas background worker queue.
    -- Threads will remain in the event object itself, but will no longer be
    -- executed as background workers.
    -- @name e:cancel
    cancel = function(self)
        for k, v in pairs(self.threads) do
            copas.removeworker(v)
        end
    end,

    -------------------------------------------------------------------------------
    -- Waits for an event to be completed. That is; all event threads spawned have died,
    -- this does not include additional threads spawned from them. Current thread will
    -- yield while waiting (so cannot be used from the mainthread!).
    -- @name e:waitfor
    -- @param timeout timeout (in seconds), use <code>nil</code> for no timeout
    -- @return <code>true</code> when completed, or <code>nil, "timeout"</code> in case of a timeout.
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
            for k, v in pairs(self.threads) do
                if type(v) == "thread" and coroutine.status(v) ~= "dead" then
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
                coroutine.yield()
                -- only here (after being resumed) the timer might have expired and set the result and error values
            end
        end
        return (err == nil), err
    end,

    -------------------------------------------------------------------------------
    -- Waits for an event to be completed in a blocking mode. That is; all event threads spawned have died
    -- (this does not include additional threads spawned from them). Current thread will
    -- NOT yield while waiting, it will only process the event related threads. It is blocking, so timers, sockets
    -- and workers will not run in the mean time, so executing this method may take a long time!
    -- @name e:finish
    -- @param timeout timeout (in seconds), use <code>nil</code> for no timeout
    -- @return <code>true</code> when completed, or <code>nil, "timeout"</code> in case of a timeout.
    finish = function(self, timeout)
        if not timeout then
            timeout = 365 * 24 * 60 * 60    -- use 1 year as 'no timeout', should suffice
        end
        local t = socket.gettime() + (tonumber(timeout) or 0)

        -- create a thread table list by looking up all worker thread tables
        local list = {}
        for k,v in pairs(self.threads) do
            v = copas.getworker(v)
            if v then
                table.insert(list, v)
            else
                error("The event object provided contains a thread that is no longer available in the copas worker queue. Cannot execute it.")
            end
        end

        -- now deal with the threads in the list
        local done = false
        while t > socket.gettime() do
            done = true
            for k,v in pairs(list) do
                if type(v.thread) == "thread" and coroutine.status(v.thread) ~= "dead" then
                    -- this one is not finished, so back to false, and resume routine
                    done = false
                    v.args = v.args or {}
                    local success, err = coroutine.resume(v.thread, unpack(v.args))
                end
            end
            if done then
                -- we looped through all of them and they we're all 'dead', so done, exit
                break
            end
        end
        if done then
            return true
        else
            return nil, "timeout"
        end
    end,
}
------------------ functions for the event table ------------------>> END


-------------------------------------------------------------------------------
-- local event list of eventer itself
local myevents = {
    register = "register",
    unregister = "unregister",
    subscribe = "subscribe",
    unsubscribe = "unsubscribe",
}

copas.eventer = {

    -------------------------------------------------------------------------------
    -- registers a server that will fire events
    -- @param server a unique key to identify the specific server, can be a string or
    -- table, or whatever, as long as it is unique
    -- @param eventlist list of strings with event names (table keys are unused, only values, so may also be a set)
    serverregister = function(server, eventlist)
        assert(server, "Server parameter cannot be nil")
        assert(not servers[server],"Server is already registered")
        assert(type(eventlist) == "table", "EventList must be a table with strings")
        -- build event table with listeners
        local events = {}    -- table with subscribers to SPECIFIC events of server
        setmetatable(events, {__mode = "k"})   -- event client table weak keys
        for i, v in pairs(eventlist) do
            events[v] = {}
        end
        local all = {}    -- table with subscribers to ALL events of server
        setmetatable(all, {__mode = "k"})   -- event client table weak keys
        servers[server] = { events = events, all = all}
        -- raise my own event
        copas.eventer.serverdispatch(copas.eventer, myevents.register, server, eventlist)
        return true
    end,

    -------------------------------------------------------------------------------
    -- unregisters a server that will fire events
    -- @param server a unique key to identify the specific server, can be a string or
    -- table, or whatever, as long as it is unique
    serverunregister = function(server)
        assert(server, "Server parameter cannot be nil")
        if servers[server]  then
            servers[server] = nil
            for c, ct in pairs(clients) do
                ct[server] = nil
            end
            -- raise my own event
            copas.eventer.dispatch(copas.eventer, myevents.unregister, server)
        end
        return true
    end,

    -------------------------------------------------------------------------------
    -- subscribes a client to events
    -- @param client unique client parameter (self)
    -- @param server a unique key to identify the specific server
    -- @param handler event handler function to be called. It will be called with
    -- signature <code>handler(client, server, event, [additional event parameters...])</code>
    -- or in method notation; <code>client:handler(server, event, [additional event parameters...])</code>.
    -- @param event string, <code>nil</code> to subscribe to all events
    clientsubscribe = function(client, server, handler, event)
        assert(client, "Client parameter cannot be nil")
        assert(type(handler) == "function", "Invalid handler parameter, expected function, got " .. type(handler))
        assert(server, "Server parameter cannot be nil")
        local stable = servers[server]  -- server table
        assert(stable, "Server not found")
        if event then
            -- specific event
            local etable = stable.events[event]
            assert(etable, "Event not found for this server")
            etable[client] = handler
        else
            -- all events
            stable.all[client] = handler
        end
        if not clients[client] then
            local s = {}
            setmetatable(s, {__mode = "k"})   -- server table weak keys
            clients[client] = s
        end
        clients[client][server] = server
        -- raise my own event
        copas.eventer.serverdispatch(copas.eventer, myevents.subscribe, client, server, event)
        return true
    end,

    -------------------------------------------------------------------------------
    -- unsubscribes a client from events
    -- @param client unique client parameter (self)
    -- @param server a unique key to identify the specific server, nil to unsubscribe all
    -- @param event string, <code>nil</code> to unsubscribe from all events
    clientunsubscribe = function(client, server, event)
        assert(client, "Client parameter cannot be nil")

        local unsubserv = function(server)
            -- unsubscribe from 1 specific server
            local stable = servers[server]
            if not event then
                -- unsubscribe from all events
                stable.all[client] = nil
            else
                -- unsubscribe from specific event
                if stable.events[event] then
                    stable.events[event][client] = nil
                end
            end
        end

        local servsubleft = function(server)
            -- check if the client has subscriptions left on this server
            if servers[server].all[client] then
                return true
            end
            local evs = servers[server].events
            for ev, _ in pairs(evs) do
                if ev[client] then
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
            if next(ct) == nil then
                clients[client] = nil
            end
            -- raise my own event
            copas.eventer.dispatch(copas.eventer, myevents.unsubscribe, client, server, event)
        end
    end,


    -------------------------------------------------------------------------------
    -- dispatches an event from a server
    -- @param server a unique key to identify the specific server
    -- @param event string
    -- @param ... other arguments to be passed on as arguments to the eventhandler
    -- @return eventobject, see the 'see' section below.
    -- @see e:event
    -- @see e:threads
    -- @see e:cancel
    -- @see e:waitfor
    -- @see e:finish
    serverdispatch = function(server, event, ...)
        local tt = {}   -- thread table

        -- we're up and running, so check what's coming in
        assert(event, "Event parameter cannot be nil")
        assert(server, "Server parameter cannot be nil")
        local stable = servers[server]
        assert(stable, "Server not found")
        local etable = stable.events[event]
        assert(etable, "Event not found for this server")

        -- create all event handler threads
        local t
        for cl, hdlr in pairs(stable.all) do
            t = disp(hdlr, cl, server, event, ...)
            table.insert(tt,t)
        end
        -- call event specific handlers
        for cl, hdlr in pairs(etable) do
            t = disp(hdlr, cl, server, event, ...)
            table.insert(tt,t)
        end

        -- build event table
        tt = {
            threads = tt,
            event = event,
            cancel = et.cancel,
            finish = et.finish,
            waitfor = et.waitfor,
        }
        return tt
    end,

    -------------------------------------------------------------------------------
    -- Decorates an object as an event server. It will provide the object with the
    -- following methods/tables; <ul>
    -- <li><code>s:subscribe(client, handler, event)</code></li>
    -- <li><code>s:unsubscribe(client, event)</code></li>
    -- <li><code>s:dispatch(event, ...)</code></li>
    -- <li><code>s.events</code></li>
    -- </ul>the methods are shortcuts to the <code>eventer</code> methods <code>clientsubscribe, clientunsubscribe, serverdispatch</code>.
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
        for k,v in pairs(events) do
            ev[v] = v
        end

        -- decorate server table with the eventlist and the functions
        server.events = ev
        server.subscribe = decor.subscribe
        server.unsubscribe = decor.unsubscribe
        server.dispatch = decor.dispatch

        -- register the client as an event server
        copas.eventer.serverregister(server, server.events)
    end,
}

-- Register own events and the copas events with the eventer.
copas.eventer.serverregister(copas.eventer, myevents)
copas.eventer.decorate(copas, { "loopstarting", "loopstarted", "loopstopping", "loopstopped" } )

-- return eventer
return copas.eventer
