
local copas = require ("copastimer")
local socket = require ("socket")

local servers = {}
setmetatable(servers, {__mode = "k"})   -- server table weak keys
local clients = {}
setmetatable(clients, {__mode = "k"})   -- client table weak keys

-- TODO:
--    * create copas directory with timer and eventer located inside
--    * add some basic tests

-------------------------------------------------------------------------------
-- The eventer is an event dispatcher. It works on top of Copas Timer using the
-- workers to create event threads. The eventer uses a publish/subscribe mechanism with servers and clients.
-- The servers should register before firing any events, and the clients should
-- subscribe to server events.<br/>
-- <br/>Dispatching creates a separate worker
-- (thread/coroutine) for each client that has to receive the event. This means that separate threads
-- will have been scheduled but not executed when an event is dispatched. Execution follows later when
-- the Copas Timer loop continues to handle its worker queue in the background.
-- The eventer will create a global table; <code>copas.eventer</code>, but that should generally not be used except for
-- the <code>copas.eventer.decorate()</code> method which will provide an object/table with event capabilities.


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
    -- @name s.events
    -- @see decorate
    events = function() end,         -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Dispatches an event for this server. It functions as a shortcut to
    -- <code>serverdispatch()</code>.
    -- @name s.dispatch
    -- @param event event string of the event to dispatch
    -- @param ... any additional event parameters
    -- @see s.events
    -- @see decorate
    -- @see serverdispatch
    -- @usage# -- create an object and decorate it with event capabilities
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
    -- @name s.subscribe
    -- @param client the client identifier (usually the client object table)
    -- @param handler the handler function for the event
    -- @param event the event to subscribe to or <code>nil</code> to subscribe to all events
    -- @see s.events
    -- @see decorate
    -- @see clientsubscribe
    -- @usage# -- create an object and decorate it with event capabilities
    -- local obj1 = {}
    -- copas.eventer.decorate(obj1, { "start", "error", "stop" } )
    -- &nbsp
    -- -- create another object and subscribe to events of obj1
    -- local obj2 = {
    --     eventhandler = function(self, sender, event, ...)
    --         print ("received event: " .. event)
    --     end
    -- }
    -- obj1:subscribe(obj2, obj1.events.stop)
    -- &nbsp
    -- ..... do some stuff, start the copas loop, etc.
    -- &nbsp
    -- -- raise the stop event
    -- local e = obj1:dispatch(obj1.events.stop)
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
    -- @name s.unsubscribe
    -- @param client the client identifier (usually the client object table), must be the same as
    -- used while subscribing.
    -- @param event the event to unsubscribe from or <code>nil</code> to unsubscribe from all events
    -- @see s.events
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
    -- @name e.event
    event = function() end,         -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Table with threads (coroutines) created. One for each event handler dispatched.
    -- @name e.threads
    threads = function() end,       -- unused dummy for luadoc

    -------------------------------------------------------------------------------
    -- Removes all event related workers from the copas background worker queue.
    -- Threads will remain in the event object itself, but will no longer be
    -- executed as background workers.
    -- @name e.cancel
    cancel = function(self)
        for k, v in pairs(self.threads) do
            copas.removeworker(v)
        end
    end,

    -------------------------------------------------------------------------------
    -- Waits for an event to be completed. That is; all event threads spawned have died,
    -- this does not include additional threads spawned from them. Current thread will
    -- yield while waiting (so cannot be used from the mainthread!).
    -- @name e.waitfor
    -- @param timeout timeout (in seconds), use <code>nil</code> for no timeout
    -- @return <code>true</code> when completed, or <code>nil, "timeout"</code> in case of a timeout.
    -- @see e.finish
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
    -- and workers will not run in the mean time, so executing this method may take a long time so use carefully!<br/>
    -- If it should not block, then use <code>waitfor()</code>.
    -- @name e.finish
    -- @param timeout timeout (in seconds), use <code>nil</code> for no timeout
    -- @return <code>true</code> when completed, or <code>nil, "timeout"</code> in case of a timeout.
    -- @see e.waitfor
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
        local events = {}    -- table with events of server
        setmetatable(events, {__mode = "k"})   -- event client table weak keys
        for i, v in pairs(eventlist) do
            events[v] = {}      -- client list for this event
        end
        servers[server] = events
        -- raise my own event
        copas.eventer:dispatch(copas.eventer.events.register, server, eventlist)
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
            copas.eventer:dispatch(copas.eventer.events.unregister, server)
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
    -- unsubscribes a client from events
    -- @param client unique client parameter (self)
    -- @param server a unique key to identify the specific server, <nil>nil</nil> to unsubscribe all
    -- @param event string, <code>nil</code> to unsubscribe from all events
    clientunsubscribe = function(client, server, event)
        assert(client, "Client parameter cannot be nil")

        local unsubserv = function(server)
            -- unsubscribe from 1 specific server
            local stable = servers[server]
            if not event then
                -- unsubscribe from all events
                for event, etable in pairs(stable) do
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
    -- dispatches an event from a server
    -- @param server a unique key to identify the specific server
    -- @param event string
    -- @param ... other arguments to be passed on as arguments to the eventhandler
    -- @return eventobject, see the 'see' section below.
    -- @see e.event
    -- @see e.threads
    -- @see e.cancel
    -- @see e.waitfor
    -- @see e.finish
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
        local t
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
    -- @usage# local list = copas.eventer.getclients(copas)     -- get list of Copas clients
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
                for client, hndlr in pairs(etable) do
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
-- immediately be finished (see <code>e.finish()</code>). So while the event threads
-- run there will be no timers, sockets, nor workers running. Only the threads created
-- for the 'loopstarting' event will run.
-- @field loopstarted Fired when the Copas loop has started, by now timers, sockets
-- and workers are running.
-- @field loopstopping Fired the Copas loop starts exiting. For as long as not all
-- event threads (for this specific event) have finished, the timers, sockets and
-- workers will keep running.
-- @field loopstopped Fired <strong>after</strong> the Copas loop has finished, this event will
-- immediately be finished (see <code>e.finish()</code>), so the timers,
-- sockets and workers no longer run.
cevents = { "loopstarting", "loopstarted", "loopstopping", "loopstopped" }
copas.eventer.decorate(copas, cevents )




--[[      change the 2 dashes '--' to 3 dashes '---' to make the test run
local test = function()
    print ("----------------------------------------------------------" )
    print (" Starting Eventer test")
    local obj1 = {}
    assert(copas.eventer.getclients(obj1) == nil, "Was never registered as server, so should be nil")
    copas:subscribe(obj1, function() end)  -- subscribe to all
    local el = copas.eventer.getclients(copas)
    assert(el, "obj1 should have been subscribed")
    assert(el[copas.events.loopstarted][1] == obj1, "should have been subscribed to loopstarted")
    assert(el[copas.events.loopstarting][1] == obj1, "should have been subscribed to loopstarting")
    assert(el[copas.events.loopstopping][1] == obj1, "should have been subscribed to loopstopped")
    assert(el[copas.events.loopstopped][1] == obj1, "should have been subscribed to loopstopping")
    copas:unsubscribe(obj1, copas.events.loopstarted)
    local el = copas.eventer.getclients(copas)
    assert(#el[copas.events.loopstarted] == 0, "should have been unsubscribed from loopstarted")
    copas:unsubscribe(obj1) -- unsubscribe from all
    local el = copas.eventer.getclients(copas)
    assert(#el[copas.events.loopstarting] == 0, "should have been unsubscribed from loopstarting")
    assert(#el[copas.events.loopstopping] == 0, "should have been unsubscribed from loopstopping")
    assert(#el[copas.events.loopstopped] == 0, "should have been unsubscribed from loopstopped")

    assert(copas.eventer.getsubscriptions(obj1) == nil, "Was never subscribed to anything, so should be nil")
    copas:subscribe(obj1, function() end)  -- subscribe to all
    el = copas.eventer.getsubscriptions(obj1)
    assert(el[copas], "Should have subscribed to copas")
    el = el[copas]
    assert(#el == 4, "Should have been 4 as copas has 4 events")
    copas:unsubscribe(obj1, copas.events.loopstarted)
    el = copas.eventer.getsubscriptions(obj1)[copas]
    assert(#el == 3, "Should have been 3 as copas has 4 events and we unsubscribed from 1")
    copas:unsubscribe(obj1) -- unsubscribe all
    el = copas.eventer.getsubscriptions(obj1)
    assert(el == nil, "Should have been nil, as the object has no more subscriptions")
    print (" Eventer test completed; succes!")
    print ("----------------------------------------------------------" )
end
test()
--]]





-- return eventer
return copas.eventer
