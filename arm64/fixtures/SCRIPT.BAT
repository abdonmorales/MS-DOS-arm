@echo off
rem Native ARM64 batch integration fixture.
echo parameter:%1 all:%*
native exit7
if errorlevel 7 echo exit-code-ok
if not errorlevel 8 echo below-eight-ok
if exist ARMTEST.TXT echo existing-file-ok
if not exist MISSING.TXT echo missing-file-ok
call CHILD.BAT nested-argument
echo child-return:%ERRORLEVEL%
echo parent-resumed
goto finished
echo BAD-GOTO
:finished
echo script-finished
exit /b 3
echo BAD-EXIT
