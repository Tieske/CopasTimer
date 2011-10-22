copy "c:\Program Files\Lua\5.1\lua\copastimer.lua" source
copy "c:\Program Files\Lua\5.1\lua\copastimertest.lua" test\test.lua
cd source
"c:\Program Files\Lua\5.1\lua\luadoc_start.lua" -d ..\docs *.lua 
start ..\docs\index.html
pause



