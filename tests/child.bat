@ECHO OFF
REM Phase 1, run by the system's own shell (FreeCOM or COMMAND.COM):
REM CLAUDE.COM as its child, with its environment and PATH. Output goes
REM to C:\RESULT.TXT; the errorlevel checks are made by the parent shell.
VER > C:\RESULT.TXT
SET PATH=%PATH%;C:\T
ECHO === 1 explicit path without extension, errorlevel 8 >> C:\RESULT.TXT
C:\CLAUDE.COM /C C:\T\HELLO one two >> C:\RESULT.TXT
IF ERRORLEVEL 8 IF NOT ERRORLEVEL 9 ECHO errorlevel 8 >> C:\RESULT.TXT
ECHO === 2 found along PATH, errorlevel 4 >> C:\RESULT.TXT
C:\CLAUDE.COM /C hello abc >> C:\RESULT.TXT
IF ERRORLEVEL 4 IF NOT ERRORLEVEL 5 ECHO errorlevel 4 >> C:\RESULT.TXT
ECHO === 3 an EXE along PATH, errorlevel 7 >> C:\RESULT.TXT
C:\CLAUDE.COM /C hellox x >> C:\RESULT.TXT
IF ERRORLEVEL 7 IF NOT ERRORLEVEL 8 ECHO errorlevel 7 >> C:\RESULT.TXT
ECHO === 4 COM before EXE, so PICK is HELLO >> C:\RESULT.TXT
C:\CLAUDE.COM /C pick >> C:\RESULT.TXT
ECHO === 5 EXE before BAT, so PICK2 is HELLOX >> C:\RESULT.TXT
C:\CLAUDE.COM /C pick2 >> C:\RESULT.TXT
ECHO === 6 an extension typed, so PICK.EXE is HELLOX >> C:\RESULT.TXT
C:\CLAUDE.COM /C pick.exe >> C:\RESULT.TXT
ECHO === 7 a batch file along PATH >> C:\RESULT.TXT
C:\CLAUDE.COM /C sub >> C:\RESULT.TXT
ECHO === 8 not found, not a program, no such drive >> C:\RESULT.TXT
C:\CLAUDE.COM /C nosuch >> C:\RESULT.TXT
C:\CLAUDE.COM /C C:\T\INPUT.TXT >> C:\RESULT.TXT
C:\CLAUDE.COM /C Q: >> C:\RESULT.TXT
ECHO === 9 commands from a file, ending in EXIT >> C:\RESULT.TXT
C:\CLAUDE.COM < C:\T\INPUT.TXT >> C:\RESULT.TXT
ECHO === 10 commands from a file that ends without EXIT >> C:\RESULT.TXT
C:\CLAUDE.COM < C:\T\NOEXIT.TXT >> C:\RESULT.TXT
ECHO === DONE >> C:\RESULT.TXT
FDAPM POWEROFF
