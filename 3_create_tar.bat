set my_target=copastimer
del %my_target%.tar.gz
del %my_target%.tar.gz.md5.txt
"c:\program files\unxutils\tar" -c docs source test rockspec > %my_target%.tar
"c:\program files\unxutils\gzip" -c %my_target%.tar > %my_target%.tar.gz
"c:\program files\unxutils\md5sum" %my_target%.tar.gz > %my_target%.tar.gz.md5.txt
del %my_target%.tar
