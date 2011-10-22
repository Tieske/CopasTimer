@echo off
cls
set my_version=0.4.0
set my_rsrev=1
set my_filelist=docs source test rockspec
set my_name=copastimer
set my_dir=distr

echo Creating distribution files;
echo ==============================================================
echo Creating application: %my_name%
echo Using version       : %my_version%
echo Rockspec revision   : %my_rsrev%
echo.
echo.
pause


rem setup names and directories
set my_target=%my_dir%\%my_name%
set my_fileversion=%my_target%-%my_version%
set my_fullversion=%my_fileversion%-%my_rsrev%

rem delete old files
del %my_fullversion%.tar.gz
del %my_fullversion%.tar.gz.md5.txt

rem pack files in named tar
"c:\program files\unxutils\tar" -c %my_filelist% > %my_target%.tar

rem create dir with version and unpack there, remove intermediate file
md %my_fileversion%
cd %my_fileversion%
"c:\program files\unxutils\tar" -x < ..\..\%my_target%.tar
del ..\..\%my_target%.tar

rem pack again in tar, now with initial dir including version, delete intermediate directory
cd ..
"c:\program files\unxutils\tar" -c %my_name%-%my_version% > ..\%my_fullversion%.tar
rmdir /S /Q %my_name%-%my_version%


rem now compress using gzip and delete intermediate tar file
cd ..
"c:\program files\unxutils\gzip" -c %my_fullversion%.tar > %my_fullversion%.tar.gz
del %my_fullversion%.tar

rem create an MD5 checksum
"c:\program files\unxutils\md5sum" %my_fullversion%.tar.gz > %my_fullversion%.tar.gz.md5.txt

echo.
echo.
echo Created archive     : %my_fullversion%
echo.

pause
