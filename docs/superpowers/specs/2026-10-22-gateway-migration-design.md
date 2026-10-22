# From ingress-nginx to the Gateway API

**Status:** design, 22 Oct 2026. Awaiting the owner's choice of controller.

## Why

The lab's internet-facing entry point is **ingress-nginx v1.12.1**. Upstream retired the project: best-effort maintenance ended in March 2026, and there are no security fixes since. Every vendor, and the upstream announcement, points to the Gateway API.

The controller is also the one part of the lab **not in git**. It came from the plain bare-metal manifest, and was then changed by hand: the NodePort pinned to 30870, the metrics flag, the Cloudflare real-IP ConfigMap, the Linkerd annotations. Git cannot rebuild it.

## What depends on it (inventory, 22 Oct)

| Dependency | Where | What changes |
|---|---|---|
| 4 Ingresses: `lab.hetops.dev` `/chaos` (SSE: buffering off, 3600 s read timeout), `/api`, `/` (clinic); `/timeline` and `/owner/timeline` (SSE); `kibana.hetops.dev` | apps/chaos, apps/clinic/base, apps/timeline, platform/logging | each becomes an HTTPRoute; the SSE timeouts become route timeouts or a policy |
| The Cloudflare tunnel's target (port 30870) | Cloudflare dashboard, not git | the final switch, and the instant rollback |
| `scripts/gameday.sh`, and the chaos prober calling the lab "the way a visitor does" | localhost:30870 with a Host header | the new port, after the switch |
| Real client IP from `CF-Connecting-IP`; `proxy-real-ip-cidr 192.168.0.0/16` | ingress-nginx ConfigMap | the controller's own trusted-address setting |
| CrowdSec acquisition `namespace: ingress-nginx, podName: ingress-nginx-controller-*, program: nginx` | argo/apps/crowdsec.yaml | the new pods; keep an nginx-format access log so the nginx parsers keep working |
| Filebeat routing of `ingress-nginx` logs | platform/logging/filebeat.yaml | the new namespace |
| Metrics ServiceMonitor | platform/monitoring/extras/ingress-nginx-metrics.yaml | the controller's metrics |
| NetworkPolicies allowing ingress from namespace `ingress-nginx` | apps/chaos, apps/clinic/base, apps/timeline | the new namespace |
| Falco's API-contact exemption | argo/apps/falco.yaml | the new namespace, only if the controller watches the API (it does) |
| Linkerd: ingress pods meshed, skip-inbound 80,443,8443; `hetops.dev/mesh=required` | pod annotation, platform/namespaces.yaml | the data-plane pods meshed the same way |
| **Gateway API CRDs:** today v1.1.1 **experimental**, routes only, installed by **Linkerd** (`installGatewayAPI: true`) | argo/apps/linkerd.yaml | the controller needs v1.5.x **standard**, including Gateway and GatewayClass. Ownership moves to a new app, see the risks |

## The choice (the owner's)

| Controller | For | Against |
|---|---|---|
| **NGINX Gateway Fabric** (F5), recommended | nginx under the hood, so access logs stay nginx-format: CrowdSec's nginx collection and the Filebeat pipeline keep working; generally available and among the top Gateway API conformance; 2.6.0 supports Kubernetes 1.31+ and Gateway API 1.5.1 | another vendor's project; a newer codebase than ingress-nginx |
| Envoy Gateway (CNCF) | the most featureful Gateway API implementation; strong project | Envoy's log format: CrowdSec and Filebeat parsing must change |
| Traefik | simple; a well-known CrowdSec bouncer plugin | its own log format; the bouncer at Cloudflare's edge already exists |

## Plan (each step reversible)

1. **CRDs:** a new Argo app owns Gateway API v1.5.x standard. The existing route CRDs are adopted with `Prune=false`, so the hand-over from linkerd-crds can never delete them, and then linkerd-crds gets `installGatewayAPI: false`. Check that Linkerd's policy controller works with v1.5 first. **This is the riskiest step**: deleting the HTTPRoute CRD would delete every route and break Linkerd's policies.
2. **Controller in parallel:** an Argo app installs the controller on a **new NodePort (30871)**, meshed, with the real-IP settings. ingress-nginx keeps serving.
3. **Routes in parallel:** HTTPRoutes next to the Ingresses; test every path through 30871 with a Host header, including the SSE streams staying open.
4. **Side systems:** CrowdSec acquisition, Filebeat, the ServiceMonitor, NetworkPolicies and Falco for the new namespace, with both namespaces allowed during the overlap.
5. **Switch:** the Cloudflare tunnel's target goes from 30870 to 30871 (the owner, in the dashboard). **Rollback:** point it back.
6. **A week later:** delete the Ingresses and ingress-nginx; the scripts and prober move to the new port; the portfolio's watch list says "Gateway API".

**Rehearsal:** a CI job installs the controller and the routes on the throwaway cluster (Bedrock's rebuild) and curls every path, before anything reaches the lab.
