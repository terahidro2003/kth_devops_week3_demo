@echo off
setlocal
pushd "%~dp0"
if errorlevel 1 exit /b 1

where docker >nul 2>&1
if errorlevel 1 goto missing_docker

:menu
echo.
echo ======================================================
echo   STOCKHOLM WEATHER - Local rehearsal
echo ======================================================
echo   1. Run app, frontend and generator tests in Docker
echo   2. Build both images: v1 and v2
echo   3. Start v1 and v2 together, without rebuilding
echo   4. Open both pages in the browser
echo   5. Show recent app logs
echo   6. Stop and remove these local containers
echo   7. Start traffic and choose its destination
echo   8. Show traffic generator results
echo   9. Stop only the traffic generator
echo   0. Close the menu, leaving containers running
echo.
choice /C 1234567890 /N /M "Choose a number: "
if errorlevel 10 goto finish
if errorlevel 9 goto stop_traffic
if errorlevel 8 goto traffic_logs
if errorlevel 7 goto traffic_menu
if errorlevel 6 goto stop_apps
if errorlevel 5 goto logs
if errorlevel 4 goto open_pages
if errorlevel 3 goto start_apps
if errorlevel 2 goto build_images
if errorlevel 1 goto test_apps
goto menu

:test_apps
echo.
echo Tests start temporary apps inside Docker and check their responses.
echo They do not start the website on ports 8082 or 8083.
docker compose -f compose.yaml run --build --rm test
if errorlevel 1 goto command_failed
docker compose -f compose.yaml run --build --rm frontend-test
if errorlevel 1 goto command_failed
docker compose -f compose.yaml run --build --rm loadgen-test
if errorlevel 1 goto command_failed
echo.
echo Tests passed.
echo Press any key to continue...
pause >nul
goto menu

:build_images
echo.
echo Building weather:v1 and weather:v2. This does not start the apps.
docker compose -f compose.yaml build app app-bad
if errorlevel 1 goto command_failed
echo.
echo Images ready. Choose 3 to start both apps.
echo Press any key to continue...
pause >nul
goto menu

:start_apps
echo.
echo Starting two separate containers: v1 on 8082, v2 on 8083.
docker compose -f compose.yaml up -d --no-build app app-bad
if errorlevel 1 goto command_failed
echo.
echo Containers started. Java may still need a few seconds.
echo v1: http://localhost:8082 - always cold and cloudy
echo v2: http://localhost:8083 - sunshine and HTTP 500 every second request
echo Choose 4 to open the pages, or 5 to inspect startup logs.
echo This local comparison does not split traffic or perform rollbacks.
echo Press any key to continue...
pause >nul
goto menu

:open_pages
echo.
echo Opening pages. This does not start the containers.
start "" "http://localhost:8082"
start "" "http://localhost:8083"
echo If a page is unreachable, wait for startup and refresh it.
echo Press any key to continue...
pause >nul
goto menu

:logs
docker compose -f compose.yaml logs --tail 60 app app-bad
if errorlevel 1 goto command_failed
echo Press any key to continue...
pause >nul
goto menu

:stop_apps
docker compose -f compose.yaml --profile comparison --profile traffic down
if errorlevel 1 goto command_failed
echo.
echo Local containers removed. Images are kept for next time.
echo Press any key to continue...
pause >nul
goto menu

:traffic_menu
echo.
echo Send approximately 10 requests per second to ONE destination.
echo   1. Local v1 - always HTTP 200
echo   2. Local v2 - approximately 50 percent errors
echo   3. Kubernetes cluster - shared address on port 8080
echo   0. Return to menu
choice /C 1230 /N /M "Destination: "
if errorlevel 4 goto menu
if errorlevel 3 goto traffic_cluster
if errorlevel 2 goto traffic_bad
if errorlevel 1 goto traffic_good
goto traffic_menu

:traffic_good
set "LOADGEN_TARGET_URL=http://app:8080/hello-world"
goto start_traffic

:traffic_bad
set "LOADGEN_TARGET_URL=http://app-bad:8080/hello-world"
goto start_traffic

:traffic_cluster
set "LOADGEN_TARGET_URL=http://host.docker.internal:8080/hello-world"
goto start_traffic

:start_traffic
echo.
echo Destination: %LOADGEN_TARGET_URL%
echo The cluster must already be running for option 3. This does not restart apps.
docker compose -f compose.yaml up -d --build --no-deps --force-recreate loadgen
if errorlevel 1 goto command_failed
echo.
echo Generator started. Wait at least 5 seconds, then choose 8.
echo Choose 9 to stop traffic. Option 0 leaves the generator running.
echo Press any key to continue...
pause >nul
goto menu

:traffic_logs
docker compose -f compose.yaml logs --tail 10 loadgen
if errorlevel 1 goto command_failed
echo Press any key to continue...
pause >nul
goto menu

:stop_traffic
docker compose -f compose.yaml stop loadgen
if errorlevel 1 goto command_failed
echo.
echo Generator stopped. The apps keep running.
echo Press any key to continue...
pause >nul
goto menu

:command_failed
echo.
echo The operation failed. Read or copy the error above.
echo Check that Docker Desktop is running with Linux containers.
echo To start without rebuilding, prepare the images with option 2 first.
echo Press any key to continue...
pause >nul
goto menu

:missing_docker
echo Docker was not found. Check your Docker Desktop installation.
echo Press any key to continue...
pause >nul

:finish
popd
endlocal
