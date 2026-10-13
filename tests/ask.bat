@ECHO OFF
REM Phase 6, under CLAUDE.COM as the only shell: Claude through the shim.
VER > C:\RESULT.TXT
ECHO === ASK >> C:\RESULT.TXT
ASK What is 2+2? Answer with the number only. >> C:\RESULT.TXT
ECHO === the conversation remembers >> C:\RESULT.TXT
ASK My favourite colour is teal. Reply with OK only. >> C:\RESULT.TXT
ASK What is my favourite colour? One word. >> C:\RESULT.TXT
ECHO === NEW forgets >> C:\RESULT.TXT
NEW >> C:\RESULT.TXT
ASK What is my favourite colour? If you do not know, say UNKNOWN only. >> C:\RESULT.TXT
ECHO === DONE >> C:\RESULT.TXT
FDAPM POWEROFF
