@ECHO OFF
ECHO args: [%1] [%2] [%3] [%4]
SET P3=from-env
ECHO env: [%P3%] [%NOSUCH%] 100%%
IF "%1"=="" ECHO wrong: no first arg
IF "%1"=="one" ECHO first arg is one
IF NOT "%1"=="two" ECHO first arg is not two
IF %2==two ECHO bare compare works
SHIFT
ECHO after shift: [%1] [%2] [%3]
IF EXIST C:\T\HELLO.COM ECHO hello.com exists
IF NOT EXIST C:\T\NOSUCH.COM ECHO nosuch.com does not
IF EXIST C:\T\*.BAT ECHO there are batch files
IF EXIST C:\T\NUL ECHO a directory, through NUL
C:\T\HELLO abc
IF ERRORLEVEL 4 ECHO errorlevel at least 4
IF ERRORLEVEL 5 ECHO wrong: errorlevel 5
IF NOT ERRORLEVEL 5 ECHO errorlevel below 5
FOR %%F IN (a b c) DO ECHO item %%F
FOR %%F IN (C:\T\P*.EXE) DO ECHO file %%F
FOR %%F IN (1,2;3) DO ECHO sep %%F
GOTO skip
ECHO wrong: not skipped
:skip
ECHO after goto
CALL C:\T\P3SUB.BAT x y
ECHO back from call, P3SUB is [%P3SUB%]
GOTO end
ECHO wrong: after goto end
:END
ECHO the label's case does not matter
ECHO ON
FOR %%F IN (x y) DO REM %%F
@ECHO OFF
SET P3=
SET P3SUB=
