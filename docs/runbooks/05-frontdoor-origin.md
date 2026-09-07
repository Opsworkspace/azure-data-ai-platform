# Runbook 05 — A Front Door origin is unhealthy

**Symptom:** one region receiving no traffic; Front Door health probe failing;
or, during setup, a Private Link origin stuck in `Pending`.

## Context

Front Door removes an origin from rotation when its health probe fails. That
is the failover mechanism working correctly — the alert is telling you a region
is *out*, not that Front Door is broken.

There are two distinct situations, and they are unrelated:

- **A.** A previously healthy origin has started failing (§1)
- **B.** A new Private Link origin has never been healthy (§4)

## 1. Confirm the probe state

```kusto
AzureDiagnostics
| where Category == "FrontDoorHealthProbeLog"
| where TimeGenerated > ago(1h)
| summarize Successes = countif(httpStatusCode_s startswith "2"),
            Failures  = countif(httpStatusCode_s !startswith "2"),
            LastResult = arg_max(TimeGenerated, httpStatusCode_s, result_s)
          by originName_s
```

## 2. Is the origin genuinely unhealthy?

The probe hits `/healthz/ready`, which is a **deep** check — it verifies the
region's own dependencies. A failing probe usually means the region genuinely
cannot serve.

```bash
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl exec -n purple deploy/purple-api -- curl -s localhost:8000/healthz/ready"
```

| Response | Meaning |
|---|---|
| `503` naming a failed critical dependency | **Correct behaviour.** Fix the dependency; see [runbook 01](01-api-error-budget-burn.md) §2 |
| `200` | The pods are fine — the problem is between Front Door and the ingress (§3) |

## 3. Pods healthy but the probe fails

The probe is failing somewhere in the path, not at the application.

Work outward from the pod:

```bash
# a. Does the Service have endpoints?
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl get endpoints purple-api -n purple"
# Empty => readiness is failing, or the Service selector does not match the pods.

# b. Does the ingress route correctly?
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl get ingress -n purple -o wide"
```

Then check the things that are easy to get wrong at the edge:

| Check | Symptom when wrong |
|---|---|
| Certificate valid and not expired | Probe fails with a TLS error; `certificate_name_check_enabled` is doing its job |
| `origin_host_header` matches the cert SAN | TLS name mismatch |
| The NSG allows `AzureFrontDoor.Backend` | Probe times out with no server-side log at all |
| The probe path is not behind auth | Probe gets `401` and the origin is marked unhealthy |

That last one is a classic: adding authentication middleware to every route
silently takes the whole region out of rotation, because the probe now gets a
401.

## 4. A Private Link origin stuck in `Pending`

**This is expected on first creation and is not a fault.**

A Private Link origin creates a private endpoint connection to your origin,
and that connection requires **manual approval on your side**. Until it is
approved, the origin is unreachable and the probe fails.

```bash
# List pending connections on the target (the ingress Private Link Service).
az network private-endpoint-connection list \
  --id <private-link-service-resource-id> \
  --query "[?properties.privateLinkServiceConnectionState.status=='Pending']" -o table

# Approve.
az network private-endpoint-connection approve \
  --id <connection-resource-id> \
  --description "Approved for Front Door origin"
```

Allow a few minutes, then re-check the probe. This step is why the
`private_link` block in `modules/front-door/main.tf` is commented rather than
enabled: it cannot be completed by Terraform alone, and it depends on a
Private Link Service that does not exist until the ingress controller is
running.

## 5. Emergency: force traffic to one region

```
Portal → Front Door → Origin groups → api-origins
  → the bad origin → Priority = 5   (higher number = lower preference)
```

Effective within ~60 seconds. No DNS change is involved, which is exactly why
Front Door was chosen over Traffic Manager — see
[availability model](../architecture/02-availability-model.md).

**Remember to set it back.** A priority left at 5 means the region never takes
traffic again, and you will not notice until you need it.

## 6. Verify

```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(15m)
| summarize Requests = count() by originName_s, bin(TimeGenerated, 1m)
| render timechart
```

Both origins taking traffic again, roughly in proportion to their weights.

## 7. Afterwards

If the probe was passing while the region was actually broken, the readiness
check is too shallow — and that is a more serious finding than the incident
itself. A shallow probe means the failover mechanism does not work, which
invalidates a large part of the availability model.
