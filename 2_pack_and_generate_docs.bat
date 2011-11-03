copy "c:\Program Files\Lua\5.1\lua\copastimer.lua" source
copy "c:\Program Files\Lua\5.1\lua\cteventer.lua" source
copy "c:\Program Files\Lua\5.1\lua\copastimertest.lua" test\test.lua
copy "c:\Program Files\Lua\5.1\lua\cteventertest.lua" test\evtest.lua
cd source
"c:\Program Files\Lua\5.1\lua\luadoc_start.lua" -d ..\docs *.lua 
start ..\docs\index.html
pause



