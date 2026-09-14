# Stockholm Weather — canary demo app

A simulated Stockholm forecast with a Swedish winter joke and real HTTP responses.
The Spring Boot app serves both the web page and its API. No external weather API,
frontend server, or host Java/Node installation is required.

| Image | Docker build target | Forecast requests |
| --- | --- | --- |
| `weather:v1` | `good` | Always HTTP 200: cloudy, 3 °C. |
| `weather:v2` | `bad` | Odd requests: HTTP 200. Even requests: HTTP 500, sunny, 30 °C. |

Both images use the same application code with different baked-in environment
defaults (`APP_VERSION` and `FAILURE_EVERY`). This is **controlled fault injection**,
not a real weather correctness check. HTTP 500 is returned intentionally; it does
not terminate the Java process. The next request can succeed normally.

## Local walkthrough (Windows or macOS + Docker Desktop)

### Windows menu: no commands to type

Start Docker Desktop, then double-click **`demo.cmd`** in this directory.
A terminal window opens with numbered choices; you do not have to type commands.
The launcher uses Windows' built-in command interpreter and Docker, with no extra
Java, Node, Python, Bash or PowerShell script policy changes.

### macOS menu

The Windows `.cmd` launcher does not run on macOS. Use **`demo.command`** instead;
it offers the same numbered actions, in English, using the same Compose file and
application code. It uses macOS's built-in Bash and requires Docker Desktop.

To start immediately, open Terminal in the repository root and run:

```bash
bash demo.command
```

For double-click launching from Finder, first make the file executable once,
from the repository root:

```bash
chmod +x demo.command
```

Then double-click `demo.command`. On the Mac menu, type a number and press Enter.
Both app versions are built locally on that computer; there is no need to copy
Docker images built on Windows. No host Java, Maven, Node or Python is required.
The `.gitattributes` file keeps this launcher's line endings in the Unix format
when shared through Git, even if it was edited on Windows.

### Using either menu

Recommended first run:

1. Choose **1** to run the app tests and the traffic generator test in Docker.
2. Choose **2** to build both images.
3. Choose **3** to start **both versions simultaneously**.
4. After Java starts, choose **4** to open both pages in your browser.

| Local address | Separate Compose service | Expected behavior |
| --- | --- | --- |
| http://localhost:8082 | `app` (`weather:v1`) | Every weather request returns 200. |
| http://localhost:8083 | `app-bad` (`weather:v2`) | Weather requests alternate 200 and 500. |

Both containers remain running while you move between browser tabs. This is a
local comparison, not yet a canary: there is no common traffic router, percentage
split, rollout analysis, or automatic rollback. That belongs to the Kubernetes
integration. Tests are a separate verification step, not a running dependency of
either app, and are not needed every time you open the page.

Choice **5** shows app startup messages. Choice **6** stops/removes the containers
in this local Compose project, including the generator, retaining their images.
Choice **0** closes the menu without stopping apps or traffic. Choices **7**, **8**,
and **9** start, inspect and stop the traffic generator (see below).
Subsequent runs need only **3**, then **4**, unless you
have changed the source code; in that case rerun tests and rebuild with **1**, **2**.

The equivalent commands for building and running both versions are:

```powershell
docker compose -f compose.yaml build app app-bad
docker compose -f compose.yaml up -d --no-build app app-bad
```

The `app-bad` service has an opt-in `comparison` profile so a plain `up` does not
start it accidentally; explicitly naming the service enables it for that command.

### Traffic generator: automatic weather requests

The typed generator in `scripts/load-generator` is adapted from our earlier demo.
Node and TypeScript run **inside Docker**, with no host installation required.
It sends real GET requests to `/hello-world`; it does not fabricate metrics or
make rollback decisions. Prometheus collects the resulting metrics from the Java
app as before. Starting local Compose traffic does not start Prometheus or Argo.

With the local apps already started using **3**:

1. Choose **7**, then **1** for v1 or **2** for v2.
2. The script builds the generator image (cached on later runs) and starts it in
   the background. Switching destinations replaces only the generator container.
3. Wait at least five seconds, then choose **8** to read recent reports. This
   displays a snapshot; choose **8** again later for updated reports.
4. Choose **9** to stop requests. Both weather apps remain running.

Expected examples (actual counts and rates vary):

```text
# v1: roughly 50 successful requests in a five-second window
window_s=5.0 completed=50 success=50 http_errors=0 connection_errors=0 rps=10.0 http_error_pct=0.0% statuses=200:50

# v2: roughly half the requests return the deliberate sunny HTTP 500
window_s=5.0 completed=50 success=25 http_errors=25 connection_errors=0 rps=10.0 http_error_pct=50.0% statuses=200:25,500:25
```

Each report describes only the latest window. It therefore shows a recovery
without old errors permanently inflating the number. Shutdown prints cumulative
totals as well. `http_errors` counts non-2xx responses, including 500; `statuses`
shows the exact HTTP codes so a wrong endpoint returning 404 is visible.
`connection_errors` counts failures without a completed response, including
timeouts. These are reported separately and are excluded from `http_error_pct`;
with no completed HTTP responses, that percentage is `n/a`, not zero.

There is at most one request in flight, normally starting every 100 ms (about
10 requests/second). Slow responses or connection failures reduce the actual
rate; each request times out after two seconds. The generator keeps going after
HTTP 500 or a connection failure and stops on Docker's shutdown signal.
This is a small demo traffic source, not a stress-testing or precise-rate tool.

Requests close their HTTP connection so a plain Kubernetes Service can select
a pod for each new connection, instead of one persistent connection sending all
traffic to the same pod. This still does not guarantee exact traffic percentages;
the rollout's routing setup determines how traffic is distributed.

**While the generator runs, browser clicks need not alternate 200/500 on v2.**
Both sources advance the same per-instance weather counter. Browser history
still counts only your clicks, and refreshes only when you click its button.
Stop traffic with **9** to inspect the alternation manually again; the first
manual request may be 200 or 500 depending on where the counter stopped.

#### Targeting the Kubernetes demo

Choose **7**, then **3** after your teammate has started the cluster and exposed
its app on host port 8080. This sends traffic to
`http://host.docker.internal:8080/hello-world` from inside Docker Desktop, on both
Windows and macOS. It uses the host port already configured in `infra/kind/cluster.yaml`.
It does not create or configure Kubernetes. If the cluster is absent, connection
errors are expected: use a local destination until the cluster is ready.

All traffic for the real canary should go through that shared application address.
The generator must not deliberately choose v1 or v2 during the canary demonstration;
the cluster's routing decides which version handles each request. The generator's
percentage then describes the combined traffic. Argo Rollouts should query the
candidate-specific application metrics to judge the new version separately.

Inside a container, `localhost` refers to that container itself. Local Compose
targets therefore use service names (`app:8080` / `app-bad:8080`), while the host's
Kubernetes entry point uses `host.docker.internal:8080`.

For another cluster address, configure `LOADGEN_TARGET_URL` outside the menu:

```powershell
# PowerShell: substitute the shared address your teammate configured.
$env:LOADGEN_TARGET_URL = 'http://host.docker.internal:8080/hello-world'
docker compose -f compose.yaml up -d --build --no-deps --force-recreate loadgen
Remove-Item Env:LOADGEN_TARGET_URL
```

```bash
# macOS Terminal
LOADGEN_TARGET_URL=http://host.docker.internal:8080/hello-world \
  docker compose -f compose.yaml up -d --build --no-deps --force-recreate loadgen
```

The request interval, timeout and report interval are configurable in the
`loadgen.environment` section of `compose.yaml`. Docker logs are capped at two
5 MB files so leaving the generator running does not produce unbounded logs.

#### Generator verification

Menu **1** runs the two existing Java tests, followed by one Node integration
test for the generator. To run only the new generator test:

```powershell
docker compose -f compose.yaml run --build --rm loadgen-test
```

Expected Node summary: `tests 1`, `pass 1`, `fail 0`. The test starts a tiny HTTP
fixture inside the test container, produces successful responses, HTTP 500 and a
period of broken connections, and verifies the generator keeps sending requests,
counts the different outcomes and shuts down cleanly. No running weather app or
Kubernetes cluster is required for that test.

### Manual alternative: replace the version on a single local port

The following commands explain the earlier single-container workflow. Use the
menu above if you want to keep both versions running. The `compose.bad.yaml` file
overrides the **same** `app` service, whereas `app-bad` is a **second** service.
Changing which Compose files describe `app` can recreate it; that differs from
simply visiting the two browser tabs while both services run.

Run all commands from this repository's root, alongside `compose.yaml`.
Docker Desktop must be running with Linux containers.

### 1. Run the automated checks

```powershell
docker compose run --build --rm test
```

This builds a temporary Maven test image and runs the tests **inside Docker**.
`run` executes a one-off task; `--rm` removes that task's container when it exits.
It does not start the weather app on localhost. The first run downloads Maven
dependencies and can take several minutes.

Expected: `Tests run: 2, Failures: 0, Errors: 0, Skipped: 0` in the final test
summary, followed by `BUILD SUCCESS`.

The two integration tests start a real HTTP server on a temporary internal port:

- Healthy: the page/assets load, six requests return the correct HTTP 200 JSON,
  and health stays UP.
- Faulty: requests alternate 200/500/200/500/200/500; page, info and health still
  work after errors; Prometheus exposes three successes and three errors tagged
  `version="v2"`; a subsequent seventh request succeeds. Metric collection and
  health checks do not advance the weather counter.

These tests verify the fault-injection mechanism deliberately works. They are not
a production acceptance test claiming that a 50% error rate is acceptable.
The metric integration test enables Spring Boot's
[test observability support](https://docs.spring.io/spring-boot/3.3/reference/testing/spring-boot-applications.html#testing.spring-boot-applications.metrics).

### 2. Build both versions once

```powershell
docker compose build app
docker compose -f compose.yaml -f compose.bad.yaml build app
```

The first command builds `weather:v1`; the second builds `weather:v2`. Their shared
Java build layers can be cached. These commands create images, not running apps.
The packaging stage skips tests; run step 1 before using the images.

### 3. Start the healthy version

```powershell
docker compose up -d --no-build app
```

Open **http://localhost:8082** after Spring Boot has started. The port is separate
from the existing Kubernetes app (8080) and Argo CD (8081).

Click **Check the weather** and then **Refresh weather** several times. Every
response should show `v1`, `200 OK`, cloudy and 3 °C. There is no automatic weather
polling: each button click sends one weather request.

If the page is not yet reachable, wait a moment. To inspect startup or errors:

```powershell
docker compose logs --tail 60 app
```

### 4. Switch to the faulty version

```powershell
docker compose -f compose.yaml -f compose.bad.yaml up -d --no-build app
```

Both files describe the **same app service**. The second file overrides its image
and build target; Compose replaces that service's container. It does not run a
second app on the same port. No compilation occurs because both images exist.

After startup, refresh the browser page to clear its session history. Click the
weather button four times:

1. `v2` · `200 OK` · Cloudy & cold, 3 °C.
2. `v2` · `500 Internal Server Error` · Sunny & warm, 30 °C.
3. `v2` · `200 OK` · Cloudy & cold, 3 °C.
4. `v2` · `500 Internal Server Error` · Sunny & warm, 30 °C.

The sunny card says: “Something is clearly wrong. This cannot be Stockholm.”
The browser reads the JSON body of the 500 response, displays the joke, and keeps
the refresh button usable. A browser developer console may log failed HTTP 500
requests; these are expected during this scenario.

The counter lives in each running Java process and resets when its container is
replaced. Other callers of `/hello-world` also advance that instance's counter.
Refreshing the browser page alone does not reset the server counter.

### 5. Switch back, or finish

```powershell
docker compose up -d --no-build app
```

This returns to `v1`. To stop and remove this local Compose app:

```powershell
docker compose --profile comparison --profile traffic down
```

Images remain available for the next run. `docker compose stop app` only stops
the container and leaves it present; that is normal.

This local switch briefly interrupts service while the replacement starts. It is
**not yet a canary deployment**. Kubernetes/Argo Rollouts will run the stable and
candidate versions together later. After changing source files, rerun the tests
and rebuild both images before using `--no-build`.

## Integration agreement for the Kubernetes/Argo work

- Container port: `8080`.
- Web page: `/`.
- Weather endpoint: **`GET /hello-world`**. The existing route is preserved for
  Grafana queries; its response is now JSON rather than the old plain text.
- Metadata: `GET /api/info` returns `version` and `failureEvery` without advancing
  the forecast counter.
- Health: `/actuator/health` stays HTTP 200 / `UP` during the simulated forecast
  failures. Keep using it for readiness/liveness: the app is running even when
  its weather feature fails.
- Prometheus: `/actuator/prometheus`, with the existing HTTP metric names and a
  new common `version` label. Each version should have distinct labels.
- No fault-injection controls are exposed as HTTP endpoints.

Example weather response (the HTTP status for this example is **500**):

```json
{
  "version": "v2",
  "requestNumber": 2,
  "city": "Stockholm",
  "condition": "Sunny",
  "temperatureC": 30,
  "outcome": "error",
  "message": "Something is clearly wrong. This cannot be Stockholm."
}
```

Candidate error percentage, once Prometheus has scraped sufficient traffic:

```promql
100 * (
  sum(rate(http_server_requests_seconds_count{uri="/hello-world",version="v2",status=~"5.."}[1m]))
  or
  (0 * sum(rate(http_server_requests_seconds_count{uri="/hello-world",version="v2"}[1m])))
)
/ sum(rate(http_server_requests_seconds_count{uri="/hello-world",version="v2"}[1m]))
```

The fallback handles a candidate that has only successful requests and no 5xx
series yet. No traffic gives no usable percentage: the rollout analysis still
needs a minimum-traffic/warm-up policy and must not treat missing data as success.
Filter the weather route so health probes and static assets do not dilute errors.
Filter the candidate version so stable pods do not hide its 50% failure rate.
Counters are per pod; `rate` is evaluated per series before summing them.

Kubernetes canary infra (`infra/app`, `infra/scripts`) uses the same
`weather:v1` / `weather:v2` tags and Docker `good` / `bad` targets as local Compose.
`up.sh` loads both images into Kind; `deploy-good.sh` / `deploy-bad.sh` patch the
Rollout image and watch promote vs auto-rollback. Analysis judges canary pods by
`/hello-world` 5xx rate (fail above 10%). With `imagePullPolicy: Never`, both
images must be available on eligible nodes.

Grafana provisions a canary error-rate dashboard (`demo-canary-errors`). A load
generator should call `/hello-world`, not just the HTML page. With several pods
and mixed versions, browser clicks will not necessarily alternate globally.

Version tags are convenient for local rehearsal. Before a shared or published
deployment, use unique release tags/digests rather than rebuilding an already
deployed tag with different contents.
