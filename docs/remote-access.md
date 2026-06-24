# Remote access — SSH + kubectl over the Cloudflare tunnel

Reach `mgmt-01` from anywhere (not just the LAN) for **SSH** to the node and **kubectl**
against the RKE2 API server — over the *same* cloudflared tunnel that already fronts
`rancher.cellarwood.org`.

> **Why this and not an open port:** SSH (22) and the kube-API (6443) are TCP, not HTTP, so
> they can't ride the existing HTTP public hostnames. We expose them as **TCP public
> hostnames** on the tunnel and gate them with **Cloudflare Access** — no inbound firewall
> hole on the NUC, every session authenticated at Cloudflare's edge first.

Nothing changes in the cloudflared chart (`cluster/infra/cloudflared`) — the tunnel is
**dashboard-managed** (token), so the connector carries TCP automatically and all routing is
added in the Zero Trust dashboard. The in-cluster cloudflared pod reaches the node's `:22`
(host) and the API server (in-cluster Service) directly.

---

## 1. Dashboard — add the public hostnames

**Zero Trust → Networks → Tunnels → `mgmt-01` → Public Hostname → Add**, two entries
(extends the table in [`manual-setup.md`](./manual-setup.md) §5):

| Public hostname | Type | Service URL | Reaches |
|---|---|---|---|
| `ssh.cellarwood.org` | `SSH` | `<nuc-lan-ip>:22` | node sshd (host) |
| `k8s.cellarwood.org` | `TCP` | `tcp://kubernetes.default.svc.cluster.local:443` | RKE2 kube-apiserver |

Cloudflare auto-creates the proxied DNS records on `cellarwood.org`.

- `<nuc-lan-ip>` is the NUC's fixed IP from `manual-setup.md` §1 (the cloudflared pod reaches
  the host over the LAN — pods can route to the node IP).
- The kube-API target is the in-cluster Service, so it survives a node-IP change and needs no
  host port. TLS is **end-to-end**: cloudflared proxies raw TCP; kubectl still does a full TLS
  handshake with the apiserver (see §5 on the cert SAN).

## 2. Protect both with Cloudflare Access (do this *before* the routes go live)

A TCP public hostname is reachable by the world until an Access policy fronts it. For **each**
hostname: **Zero Trust → Access → Applications → Add → Self-hosted**.

- **Application domain:** the hostname (`ssh.cellarwood.org`, then `k8s.cellarwood.org`).
- **Policy:** action *Allow*, rule *Emails* → `lukas.kellerstein@gmail.com` (tighten/add
  operators later). Everything else is denied by default.
- For SSH, leave the app as a normal self-hosted app — `cloudflared access ssh` (client, §4)
  performs the Access login. Optionally enable **short-lived SSH certificates** later to drop
  static `authorized_keys` entirely.

> Without these policies you have published SSH and the Kubernetes API to the internet. Add
> the Access apps in the same sitting as the routes.

## 3. Client — install cloudflared

On the laptop you connect *from*:

```bash
brew install cloudflared            # macOS; see CF docs for Linux/Windows
```

The first `cloudflared access ...` call opens a browser for the Access login; the token is
cached, so subsequent sessions are non-interactive until it expires.

## 4. SSH from anywhere

`cloudflared access ssh` is used as an SSH `ProxyCommand` — it speaks the Access handshake,
then pipes the TCP stream to the tunnel. Add to `~/.ssh/config`:

```sshconfig
Host mgmt-01
  HostName ssh.cellarwood.org
  User <your-node-user>
  ProxyCommand cloudflared access ssh --hostname %h
```

Then just:

```bash
ssh mgmt-01
```

(One-off without the config block:
`ssh -o ProxyCommand='cloudflared access ssh --hostname ssh.cellarwood.org' <user>@ssh.cellarwood.org`.)

## 5. kubectl from anywhere

Bind a local port to the API server through the tunnel, then point a kubeconfig at it.

```bash
# leave this running (or daemonise it — launchd/systemd/tmux)
cloudflared access tcp --hostname k8s.cellarwood.org --url 127.0.0.1:6443
```

Use the **RKE2 kubeconfig as-is**: `/etc/rancher/rke2/rke2.yaml` already has
`server: https://127.0.0.1:6443` and the cluster CA. Copy it to the laptop and select it:

```bash
scp mgmt-01:/etc/rancher/rke2/rke2.yaml ~/.kube/mgmt-01.yaml   # via the SSH host from §4
export KUBECONFIG=~/.kube/mgmt-01.yaml
kubectl get nodes
```

**Why this verifies cleanly:** the apiserver serving cert includes `127.0.0.1` as a SAN, and
you're connecting to `https://127.0.0.1:6443` (the local proxy port) — so TLS validation
against the RKE2 CA passes with no `--insecure-skip-tls-verify` and no `--tls-server-name`.
Keep the proxy on `127.0.0.1:6443` to match the cert/kubeconfig.

> If you prefer a public name in the kubeconfig (`server: https://k8s.cellarwood.org:6443`),
> add `k8s.cellarwood.org` to RKE2's `tls-san` list (`/etc/rancher/rke2/config.yaml`) and
> restart `rke2-server` so the apiserver cert carries that SAN. The 127.0.0.1 route above
> avoids that.

---

## Recap

- Routes + Access policies: **dashboard** (§1–§2) — external-account config, like the rest of
  the tunnel.
- Client: `cloudflared` + an SSH `ProxyCommand` (§4) and a TCP proxy for kubectl (§5).
- Repo: **unchanged** — same connector, no new manifest or values change.
