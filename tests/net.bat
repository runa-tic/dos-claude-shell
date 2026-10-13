@ECHO OFF
REM Phase 0 network check: DHCP, ping the host, one TCP connection to the shim.
VER > C:\RESULT.TXT
ECHO === DHCP >> C:\RESULT.TXT
DHCP >> C:\RESULT.TXT
ECHO === PING 10.0.2.2 >> C:\RESULT.TXT
PING 10.0.2.2 >> C:\RESULT.TXT
ECHO === HTGET the shim >> C:\RESULT.TXT
HTGET http://10.0.2.2:8765/v1/models >> C:\RESULT.TXT
ECHO === DONE >> C:\RESULT.TXT
FDAPM POWEROFF
