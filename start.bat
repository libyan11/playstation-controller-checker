@echo off
rem Serves the checker on localhost (WebHID needs a secure origin) and opens it in Chrome.
cd /d "%~dp0"
start "" "C:\Program Files\Google\Chrome\Application\chrome.exe" "http://127.0.0.1:8790/index.html"
echo Serving on http://127.0.0.1:8790  - close this window to stop.
py -m http.server 8790 --bind 127.0.0.1
