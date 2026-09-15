# Demo plan — canary latency rollback (~5 min)

## Goal

Show progressive delivery: ship a slow canary at 20% weight, prove it with latency metrics, auto-rollback to the last stable ReplicaSet.

## Pre-demo

- Cluster already up (`./infra/scripts/up.sh`).
- Images loaded: `demo:v1` (good), `demo:v2` (~1500 ms latency).
- Argo CD open; Grafana dashboard **Demo canary latency** ready.
- Demo Application: **manual sync** (no selfHeal fight).

## Live path (8 steps)

1. Show Healthy 5× `demo:v1` in Argo CD / Rollouts.
2. Run `./infra/scripts/deploy-bad.sh` (patches Rollout image to `demo:v2`).
3. Show 1 of 5 canary @ 20% weight (analysis inconclusive without traffic).
4. Start `./infra/scripts/load.sh` (~10 rps).
5. Grafana: v1 fast + v2 p99 rising.
6. Analysis fails on canary latency SLO → rollback starts.
7. Confirm back on previous stable (not a hardcoded tag).
8. Grafana recovers to v1-only traffic.

## Talking points

- Why canary + automated analysis beats “deploy and hope”.
- Latency as the fault signal (not intentional HTTP 500s).
- Tradeoffs: needs real traffic, Prometheus scrape lag, Kind is not production scale.

## Out of scope for the talk

- Stockholm weather narrative / sunny-500 joke.
- Hardcoding rollback to a fixed image tag.
- Changing weight away from 20% / 5 pods.
