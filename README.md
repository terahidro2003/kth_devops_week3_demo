# Canary latency demo

Five-minute talk: stable **demo:v1** → canary **demo:v2** (artificial ~1500 ms delay) at 20% weight → load → Grafana shows v2 p99 spike → analysis fails → Rollouts rolls back to the previous stable ReplicaSet.

| Image | Build target | Behavior |
| --- | --- | --- |
| `demo:v1` | `good` | Fast responses (`DEMO_LATENCY_MS=0`) |
| `demo:v2` | `bad` | ~1500 ms delay on `/hello-world` |

Fault signal is **latency**, not HTTP 500s. Metric `version` still comes from `demo.version` / `DEMO_VERSION`.

## Pre-demo (not timed)

```bash
./infra/scripts/up.sh
```

Builds/loads `demo:v1` and `demo:v2` into Kind, then deploys **local** `infra/app` manifests (source of truth). Kind is **1 CP + 3 workers** (roles: prometheus, grafana, app), plus Argo CD + Rollouts, 5× `demo:v1`.

If `origin` still has a stale Rollout image (e.g. `weather:v1`), `up.sh` does **not** leave the cluster on that tag: it reloads local images, deletes any Git-synced demo Rollout, and applies local manifests. Demo Application stays **manual sync** so a live image set is not fought by selfHeal. Push `infra/app` when you want Git and cluster to match.

| URL | Creds |
| --- | --- |
| http://localhost:8080 | app / UI |
| http://localhost:9090 | Prometheus |
| http://localhost:3000 | Grafana `admin` / `admin` |
| https://localhost:8081 | Argo CD `admin` / (printed by `up.sh`) |

## 8-step talk

1. **Healthy baseline** — Argo CD / Rollouts: 5 pods on `demo:v1`, Healthy.
2. **Deploy bad** — one command (resets to Healthy `demo:v1` first, then canaries `demo:v2`):

   ```bash
   ./infra/scripts/deploy-bad.sh
   ```

3. **Show canary** — 1 of 5 pods on v2, weight **20%**. Analysis is inconclusive until there is traffic.
4. **Start load** — `./infra/scripts/load.sh` (~10 rps, status + avg latency).
5. **Grafana** — dashboard **Demo canary latency**: RPS by version + **p99 by version** (v2 rises).
6. **Analysis fail** — canary p99 > 1s → Rollout aborts (~15–30s after load).
7. **Rollback** — traffic back on the **previous stable** ReplicaSet; canary pods scale down immediately (`abortScaleDownDelaySeconds: 0`).
8. **Recover** — Grafana returns to v1-only. Clear Argo CD **Degraded** with:

   ```bash
   ./infra/scripts/deploy-good.sh
   ```

   (Also runs automatically at the start of `deploy-bad.sh`.)

## Analysis (latency SLO)

PromQL on canary pods (`pod=~"demo-<hash>-.*"`):

- `histogram_quantile(0.99, … http_server_requests_seconds_bucket{uri="/hello-world"} …) or vector(-1)`
- No traffic → `-1` → **inconclusive** (does not abort; wait for load or promote-full)
- Fail when p99 **> 1s**; pass when `0 ≤ p99 ≤ 1`
- Timing: `initialDelay: 5s`, `interval: 5s`, `count: 24`, `failureLimit: 1`, `inconclusiveLimit: 24` (~2 min talk window before load; Rollouts requires `count >= inconclusiveLimit`)

## Layout

| Path | Role |
| --- | --- |
| `infra/app/` | Rollout (5 replicas, 20% canary), Services, AnalysisTemplate |
| `infra/monitoring/` | Prometheus (scrape Service `demo` only), Grafana |
| `infra/argocd/` | Applications (`demo` manual; prometheus/grafana auto) |
| `infra/kind/` | 1 CP + 3 workers |
| `infra/scripts/` | `up.sh`, `deploy-bad.sh`, `deploy-good.sh`, `load.sh`, `lib-rollout.sh` |

## Local Compose (optional)

App workstream owns Compose/UI details. Same images (`demo:v1` / `demo:v2`), endpoint **`GET /hello-world`**. Cluster canary traffic should hit the shared NodePort (`localhost:8080`), not a single version URL.
