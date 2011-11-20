copy "c:\Program Files\Lua\5.1\lua\copas\*.lua" source\copas
copy "c:\Program Files\Lua\5.1\lua\copastimertest.lua" test\test.lua
copy "c:\Program Files\Lua\5.1\lua\copaseventertest.lua" test\evtest.lua
cd source
"c:\Program Files\Lua\5.1\lua\luadoc_start.lua" -d ..\doc copas\*.lua 
start ..\doc\index.html
pause



