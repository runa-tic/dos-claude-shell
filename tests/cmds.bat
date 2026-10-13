@ECHO OFF
REM The same commands (P2.BAT, internal commands) and batch file (P3.BAT,
REM the batch language) run by CLAUDE.COM and, as the reference, by the
REM system's own shell; P2.BAT each in an empty directory.
MD C:\OURS
MD C:\REF
CD C:\OURS
C:\CLAUDE.COM /C C:\T\P2.BAT > C:\OURS.TXT
CD C:\REF
%COMSPEC% /C C:\T\P2.BAT > C:\REF.TXT
CD C:\
C:\CLAUDE.COM /C C:\T\P3.BAT one two three > C:\OURS3.TXT
%COMSPEC% /C C:\T\P3.BAT one two three > C:\REF3.TXT
FDAPM POWEROFF
