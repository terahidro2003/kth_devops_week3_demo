1. Make canary deployments work
    - prepare the bad version (so we could quickly switch between them)
    - setup canary deployment 
    - setup automatic rollback
    - make scripts that we can use in demo
2. In the presentation (under 7 minutes):
    - explain the problem and the solution
    - briefly present the technologies and the architecture (make a quick graph)
    - show that the "good" version works and has good acceptable metrics (30s)
    - quickly show ArgoCD UI (10s)
    - we can go through important configs
    - deploy "bad" version
    - show that "bad" version gets ~50% of traffic (2 of 4 pods)
    - show bad metrics
    - show auto rollback
    - show that its relevant to devops
    - limitations/tradeoffs of this approach
    - reflection