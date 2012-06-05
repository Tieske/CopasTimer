@echo off
cls
rem ===============================================================
rem   Update the lines below with newest version information
rem   and files/directories to be included
rem ===============================================================
set my_version=0.4.3
set my_rsrev=1
set my_name=copastimer
set my_dir=distr
set my_filelist=doc source test rockspec readme.txt
rem ===============================================================

echo Creating distribution files;
echo ==============================================================
echo Creating application: %my_name%
echo Using version       : %my_version%
echo Rockspec revision   : %my_rsrev%
echo.
echo If this is not correct, stop and update the initial lines of this batchfile
echo.
echo PS: must run this batchfile as administrator
echo.
pause

rem move to directory containing this batch file
cd %~dp0

rem setup names and directories
set my_target=%my_dir%\%my_name%
set my_fileversion=%my_target%-%my_version%
set my_fullversion=%my_fileversion%-%my_rsrev%

rem delete old files
del %my_fileversion%.tar.gz
del %my_fileversion%.tar.gz.md5.txt

rem pack files in named tar
md %my_dir%
"c:\program files\unxutils\tar" -c %my_filelist% > %my_target%.tar

rem create dir with version and unpack there, remove intermediate file
md %my_fileversion%
cd %my_fileversion%
"c:\program files\unxutils\tar" -x < ..\..\%my_target%.tar
del ..\..\%my_target%.tar

rem pack again in tar, now with initial dir including version, delete intermediate directory
cd ..
"c:\program files\unxutils\tar" -c %my_name%-%my_version% > ..\%my_fileversion%.tar
rmdir /S /Q %my_name%-%my_version%


rem now compress using gzip and delete intermediate tar file
cd ..
"c:\program files\unxutils\gzip" -c %my_fileversion%.tar > %my_fileversion%.tar.gz
del %my_fileversion%.tar

rem create an MD5 checksum
"c:\program files\unxutils\md5sum" %my_fileversion%.tar.gz > %my_fileversion%.tar.gz.md5.txt

echo.
echo.
echo Created archive     : %my_fileversion%.tar.gz
echo.

pause
