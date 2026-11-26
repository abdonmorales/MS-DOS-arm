@echo off
for %%f in (one two three) do echo item:%%f
for %%f in (*.TXT) do echo txt:%%f
:loop
if "%1"=="" goto done
echo arg:%1
shift
goto loop
:done
if "%ARMDOS%"=="1" echo env-ok
if not abc==abd echo compare-ok
echo end-features
