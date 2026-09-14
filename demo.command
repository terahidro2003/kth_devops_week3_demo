#!/bin/bash
# Compatible with the Bash supplied by macOS. All app builds/tests run in Docker.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

# Finder's Terminal session may not include Docker Desktop's user CLI directory.
export PATH="${HOME}/.docker/bin:/usr/local/bin:${PATH}"

pause_menu() {
    printf '\nPress Enter to return to the menu... '
    IFS= read -r unused || exit 0
}

run_docker() {
    if docker compose -f compose.yaml "$@"; then
        return 0
    fi
    printf '\nThe operation failed. Read or copy the error above.\n'
    printf 'Check that Docker Desktop is running. Build images with option 2 before starting them.\n'
    return 1
}

if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker was not found. Check your Docker Desktop installation.\n'
    printf 'Press Enter to close... '
    IFS= read -r unused
    exit 1
fi

while true; do
    printf '\n======================================================\n'
    printf '  STOCKHOLM WEATHER - Local rehearsal\n'
    printf '======================================================\n'
    printf '  1. Run app, frontend and generator tests in Docker\n'
    printf '  2. Build both images: v1 and v2\n'
    printf '  3. Start v1 and v2 together, without rebuilding\n'
    printf '  4. Open both pages in the browser\n'
    printf '  5. Show recent app logs\n'
    printf '  6. Stop and remove these local containers\n'
    printf '  7. Start traffic and choose its destination\n'
    printf '  8. Show traffic generator results\n'
    printf '  9. Stop only the traffic generator\n'
    printf '  0. Close the menu, leaving containers running\n\n'
    printf 'Choose a number, then press Enter: '
    IFS= read -r selection || exit 0

    case "$selection" in
        1)
            printf '\nTests start temporary apps inside Docker, not on ports 8082 or 8083.\n'
            if run_docker run --build --rm test && run_docker run --build --rm frontend-test && run_docker run --build --rm loadgen-test; then
                printf '\nTests passed.\n'
            fi
            ;;
        2)
            printf '\nBuilding weather:v1 and weather:v2. This does not start the apps.\n'
            if run_docker build app app-bad; then
                printf '\nImages ready. Choose 3 to start both apps.\n'
            fi
            ;;
        3)
            if run_docker up -d --no-build app app-bad; then
                printf '\nContainers started. Java may still need a few seconds.\n'
                printf 'v1: http://localhost:8082 - always cold and cloudy\n'
                printf 'v2: http://localhost:8083 - sunshine and HTTP 500 every second request\n'
                printf 'Choose 4 to open the pages, or 5 to inspect startup logs.\n'
                printf 'This local comparison does not split traffic or perform rollbacks.\n'
            fi
            ;;
        4)
            printf '\nOpening pages. This does not start the containers.\n'
            if [ "$(uname -s)" = Darwin ]; then
                /usr/bin/open 'http://localhost:8082'
                /usr/bin/open 'http://localhost:8083'
            else
                printf 'Open http://localhost:8082 and http://localhost:8083 in your browser.\n'
            fi
            printf 'If a page is unreachable, wait for startup and refresh it.\n'
            ;;
        5)
            run_docker logs --tail 60 app app-bad
            ;;
        6)
            if run_docker --profile comparison --profile traffic down; then
                printf '\nLocal containers removed. Images are kept for next time.\n'
            fi
            ;;
        7)
            printf '\nSend approximately 10 requests per second to ONE destination:\n'
            printf '  1. Local v1 - always HTTP 200\n'
            printf '  2. Local v2 - approximately 50 percent errors\n'
            printf '  3. Kubernetes cluster - shared address on port 8080\n'
            printf '  0. Return to menu\n'
            printf 'Destination: '
            IFS= read -r destination || exit 0
            case "$destination" in
                1) traffic_target='http://app:8080/hello-world' ;;
                2) traffic_target='http://app-bad:8080/hello-world' ;;
                3) traffic_target='http://host.docker.internal:8080/hello-world' ;;
                0) continue ;;
                *) printf 'Unknown destination.\n'; pause_menu; continue ;;
            esac
            printf '\nDestination: %s\n' "$traffic_target"
            printf 'The target must already be running. This does not restart apps.\n'
            if LOADGEN_TARGET_URL="$traffic_target" run_docker up -d --build --no-deps --force-recreate loadgen; then
                printf '\nGenerator started. Wait at least 5 seconds, then choose 8.\n'
                printf 'Choose 9 to stop traffic. Option 0 leaves the generator running.\n'
            fi
            ;;
        8)
            run_docker logs --tail 10 loadgen
            ;;
        9)
            if run_docker stop loadgen; then
                printf '\nGenerator stopped. The apps keep running.\n'
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            printf '\nChoose a number from 0 to 9.\n'
            ;;
    esac
    pause_menu
done
