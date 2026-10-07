# Zero-Downtime CI/CD Engine

Infrastructure-as-code (Terraform), a containerized service, Kubernetes manifests and **blue-green** and
**canary** release tooling with automated analysis, automatic rollback and a self-healing drill — all
verified end-to-end in GitHub Actions on a real (kind) Kubernetes cluster.

```
 git push ─► ci.yml            unit tests · terraform fmt/validate · shellcheck · manifest schema validation
          └► zero-downtime-e2e kind cluster: blue-green + canary + bad-release + chaos, under live traffic
 manual   ─► deploy.yml        test → build → push (immutable tag = SHA) → ECR → EKS  (OIDC, no stored AWS keys)

 terraform/  VPC (3 AZ) · EKS · ECR (immutable tags, scan on push) · GitHub OIDC deploy role
 k8s/        Deployments (probes, PDB, hardened securityContext) · Services · kind config
 scripts/    bluegreen.sh · rollback.sh · canary.sh · chaos.sh · e2e.sh
 app/        Go demo service with readiness gating, graceful drain, injectable errors, /crash
```

## How "zero downtime" is actually achieved

| Mechanism | Where |
|---|---|
| **Readiness probes** keep unready pods out of the Service | `k8s/*/deployment.yaml`, app `/readyz` (+ startup delay to prove gating) |
| **maxUnavailable: 0** rolling updates, PodDisruptionBudget | deployments |
| **Graceful shutdown**: app keeps serving 5 s after SIGTERM (endpoint propagation), then drains in-flight requests | `app/main.go` |
| **Blue-green**: new colour deployed beside the old, smoke-tested via port-forward *before* it sees traffic, then one atomic Service-selector patch flips traffic; old colour stays up so **rollback is one patch** | `scripts/bluegreen.sh`, `rollback.sh` |
| **Canary**: 10 → 30 → 60 → 100 % of pods; at each step 300 real requests are sampled through the Service; error rate > 1 % ⇒ canary scaled to 0 and stable restored | `scripts/canary.sh` |
| **Self-healing**: Deployments + liveness probes recreate killed pods; `chaos.sh` force-deletes a pod and crashes processes under load, then asserts recovery and ≥ 95 % availability | `scripts/chaos.sh` |
| **Immutable image tags** (git SHA) so a version always means the same bits | ECR config, `deploy.yml` |

## What the e2e test asserts (`scripts/e2e.sh`)

1. Blue-green 1.0.0 → 2.0.0 while a background probe hits the service every ~20 ms → **0 failed requests**.
2. Rollback to 1.0.0 under load → **0 failed requests**.
3. A release whose image can't start never receives traffic; previous version stays live.
4. Canary 2.0.0 promoted under load → **0 failed requests**.
5. Canary 3.0.0 with 50 % injected errors → **detected, rolled back automatically**, users still get 2.0.0.
6. Chaos: random pod force-killed + two crashed processes → all replicas Ready again, availability ≥ 95 %.

Run it yourself (needs docker, kind, kubectl, envsubst, curl):

```bash
./scripts/e2e.sh
```

Or manually:

```bash
kind create cluster --config k8s/kind.yaml
docker build -t demo:1.0.0 app && kind load docker-image demo:1.0.0
./scripts/bluegreen.sh demo:1.0.0 1.0.0      # first deploy
curl localhost:8080/api/hello
./scripts/canary.sh demo:1.0.0 1.0.0 && curl localhost:8081/api/hello
```

## Deploy to AWS

```bash
cd terraform && terraform init && terraform apply     # VPC + EKS + ECR + OIDC role
```

Then set repository variables `AWS_DEPLOY_ROLE_ARN`, `AWS_REGION`, `ECR_REPOSITORY`, `EKS_CLUSTER` (from `terraform output`)
and run the **deploy** workflow. (Creates billable AWS resources: EKS control plane, NAT gateway, nodes. `terraform destroy` when done.)

## Honest status

* Written and unit-tested for the app on Windows without Docker/Kubernetes/Terraform available, so the **e2e workflow and Terraform
  validation first ran in GitHub Actions** — see the Actions tab for the current status badge/results.
* The Terraform has been `validate`d in CI only; it has not been `apply`'d against a live AWS account.
* The README does not claim any "released N times / X minutes" figures — measure them from your own Actions run
  history (the `deploy` workflow duration is your release time).

## Next steps

Argo Rollouts / Flagger for metric-based (Prometheus) canary analysis and traffic-weighted routing via an ingress/mesh,
Argo CD GitOps, HPA, Cosign image signing + admission policy.

MIT licensed.
