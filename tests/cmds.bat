@ECHO OFF
REM Phase 2: the same commands (P2.BAT) run by CLAUDE.COM and, as the
REM reference, by the system's own shell, each in an empty directory.
MD C:\OURS
MD C:\REF
CD C:\OURS
C:\CLAUDE.COM /C C:\T\P2.BAT > C:\OURS.TXT
CD C:\REF
%COMSPEC% /C C:\T\P2.BAT > C:\REF.TXT
CD C:\
FDAPM POWEROFF
