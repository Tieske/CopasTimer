Copas Timer is free software under the MIT/X11 license.
Copyright 2011-2012 Thijs Schreijer

Documentation: http://tieske.github.com/CopasTimer/
Source: http://github.com/Tieske/CopasTimer

Changelog;
===================================================================
04-Jun-2012; release 0.4.2
 - fixed undefined behaviour when arming an already armed timer
 - removed default 1 second interval, now throws an error
   if the first call to arm does not provide an interval.
 - bugfix, worker could not remove itself from the worker queue
 - added method copas.waitforcondition() to the timer module

-------------------------------------------------------------------
07-Nov-2011; release 0.4.1
 - bugfix, timer could not be cancelled from its own handler.
 - bugfix, worker completed elswhere is no longer resumed.
 - changed exitloop and isexiting members, see docs for use 
   (this is breaking!)
 - added an optional eventer module that fires events as background
   tasks
 - restructured files, no longer 'copastimer.lua' but now
   'copas/timer.lua' (and 'copas/eventer.lua'). (this is breaking!)

-------------------------------------------------------------------
24-Oct-2011; Initial release 0.4.0