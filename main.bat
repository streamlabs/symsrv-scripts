@echo on
:: /d is required - without it cd sets the target drive's directory but stays on the
:: current drive, and the relative script paths below then resolve somewhere else
cd /d %1
powershell.exe -ExecutionPolicy Bypass -Command %2

:: Exit with non-zero so GitHub action knows there was an issue
if %errorlevel% neq 0 exit /b %errorlevel%