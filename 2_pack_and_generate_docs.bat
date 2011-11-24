@echo off
echo off
cls
rem =================================================================
rem The following variables should be defined;
rem   LUA_DEV         - path to the Lua environment
rem                     usually; c:\program files\lua\5.1
rem   LUA_EDITOR      - path including executable of lua editor
rem                     usually; %LUA_DEV%\scite\scite.exe
rem   LUA_SOURCEPATH  - path to Lua source code
rem                     usually; %LUA_DEV%\lua
rem =================================================================
rem
rem USE: batch file collects main files from the lua sourcepath and
rem      copies the (modified) files into the project directory source
rem      directory.
rem      Then it starts the LuaDoc generator on the source directory.


rem copy main files back to project directory
copy "%LUA_SOURCEPATH%\copas\*.lua" source\copas

rem go to source directory and start LuaDoc
cd source
"%LUA_SOURCEPATH%\luadoc_start.lua" -d ..\doc copas\*.lua 
start ..\doc\index.html
pause



