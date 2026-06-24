#!/usr/bin/env python3
"""Manage this repo's SOPS-encrypted secrets — the one tool for the workflow in docs/secrets.md.

The committed source of truth for every secret is a SOPS+age-encrypted `*.enc.yaml`, co-located with
the chart that consumes it (cluster/<tier>/<chart>/<name>.enc.yaml). Two shapes (see docs/secrets.md):
  - out-of-band k8s Secret manifests (only data/stringData encrypted) — applied with this tool
  - the cloudflared helm-secrets values overlay cluster/infra/cloudflared/secrets.enc.yaml (whole file
    encrypted, decrypted in-line at deploy by helm-secrets — NOT applied with this tool)
Nothing plaintext is ever committed.

Commands:
  secrets.py pull  <ns> <name> [path]   snapshot a LIVE Secret -> encrypted file (safe migration)
  secrets.py edit  <path>               open decrypted in $EDITOR, re-encrypt on save
  secrets.py view  <path>               print the decrypted file to stdout
  secrets.py encrypt <path>             encrypt a freshly-authored plaintext file in place
  secrets.py apply <path>               decrypt and `kubectl apply -f -`  (out-of-band Secrets only)
  secrets.py rekey [path ...]           re-encrypt to the current .sops.yaml recipients
  secrets.py lint                       fail if any *.enc.yaml is not encrypted / stray plaintext

Kube context: defaults to the current context. Only mgmt-01[-remote] is accepted, so a stray
current-context for a downstream cluster can never be targeted by accident. Override with
SECRETS_KUBE_CONTEXT (e.g. if your RKE2 kubeconfig still names the context `default`).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from shutil import which
from typing import NoReturn

# This repo's cluster. When replicating this script to a sibling repo, change this one line.
CONTEXT_PREFIX = "mgmt-01"

REPO_ROOT = Path(__file__).resolve().parent.parent
# macOS sops defaults to ~/Library/Application Support/...; pin the XDG path so the workflow
# is OS-agnostic and the same fleet age key decrypts every repo.
os.environ.setdefault("SOPS_AGE_KEY_FILE", str(Path.home() / ".config/sops/age/keys.txt"))


def die(msg: str) -> NoReturn:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def need(tool: str) -> None:
    if which(tool) is None:
        die(f"{tool} not installed (brew install sops age)")


def kube_context() -> str:
    ctx = os.environ.get("SECRETS_KUBE_CONTEXT", "")
    if not ctx:
        r = subprocess.run(["kubectl", "config", "current-context"],
                           capture_output=True, text=True)
        ctx = r.stdout.strip() if r.returncode == 0 else ""
    if ctx not in (CONTEXT_PREFIX, f"{CONTEXT_PREFIX}-remote"):
        die(f"refusing kube context {ctx!r} (expected {CONTEXT_PREFIX} or "
            f"{CONTEXT_PREFIX}-remote). Name your mgmt-01 context accordingly, or set "
            f"SECRETS_KUBE_CONTEXT.")
    return ctx


def is_encrypted(path: Path) -> bool:
    """A SOPS file carries a top-level `sops:` metadata block."""
    try:
        return any(line.startswith("sops:") for line in path.read_text().splitlines())
    except OSError:
        return False


def find_enc_files(paths: list[str]) -> list[Path]:
    return [Path(p) for p in paths] if paths else sorted(REPO_ROOT.rglob("*.enc.yaml"))


def default_path(namespace: str, name: str) -> Path:
    """Fallback landing spot for a freshly pulled Secret when no explicit path is given.
    Secrets are normally co-located next to their chart
    (cluster/<tier>/<chart>/<name>.enc.yaml) — pass that path explicitly. This bare
    fallback is just a holding area; move the file next to its chart before committing."""
    return REPO_ROOT / f"{name}.enc.yaml"


def minimal_manifest(secret: dict) -> str:
    """A minimal, apply-ready Secret manifest from `kubectl get secret -o json`, dropping
    server-side fields. base64 `data` values are emitted as-is so plaintext is never written
    to disk un-encrypted — SOPS encrypts the base64 strings."""
    meta = secret["metadata"]
    data = secret.get("data", {})
    lines = [
        "apiVersion: v1",
        "kind: Secret",
        "metadata:",
        f"  name: {meta['name']}",
        f"  namespace: {meta['namespace']}",
        f"type: {secret.get('type', 'Opaque')}",
        "data:",
        *[f"  {k}: {data[k]}" for k in sorted(data)],
    ]
    return "\n".join(lines) + "\n"


# --- commands ---------------------------------------------------------------

def cmd_pull(args: argparse.Namespace) -> None:
    need("sops")
    ctx = kube_context()
    path = Path(args.path) if args.path else default_path(args.namespace, args.name)
    r = subprocess.run(["kubectl", "--context", ctx, "-n", args.namespace, "get", "secret",
                        args.name, "-o", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"could not read secret {args.name} in {args.namespace}: {r.stderr.strip()}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(minimal_manifest(json.loads(r.stdout)))
    if subprocess.run(["sops", "--encrypt", "--in-place", str(path)]).returncode != 0:
        path.unlink(missing_ok=True)
        die(f"sops encrypt failed — removed plaintext {path}")
    print(f"pulled {args.namespace}/{args.name} -> {path} (encrypted)")


def cmd_edit(args: argparse.Namespace) -> None:
    need("sops")
    path = Path(args.path)
    if not path.exists():
        die(f"no {path} — create it with: secrets.py pull <ns> <name> {path}")
    raise SystemExit(subprocess.run(["sops", str(path)]).returncode)


def cmd_view(args: argparse.Namespace) -> None:
    need("sops")
    raise SystemExit(subprocess.run(["sops", "-d", args.path]).returncode)


def cmd_encrypt(args: argparse.Namespace) -> None:
    need("sops")
    path = Path(args.path)
    if not path.exists():
        die(f"no such file: {path}")
    if is_encrypted(path):
        die(f"{path} is already SOPS-encrypted")
    raise SystemExit(subprocess.run(["sops", "--encrypt", "--in-place", str(path)]).returncode)


def cmd_apply(args: argparse.Namespace) -> None:
    need("sops")
    ctx = kube_context()
    path = Path(args.path)
    if not path.exists():
        die(f"no such file: {path}")
    dec = subprocess.run(["sops", "-d", str(path)], capture_output=True, text=True)
    if dec.returncode != 0:
        die(f"sops decrypt failed for {path}: {dec.stderr.strip()}")
    ap = subprocess.run(["kubectl", "--context", ctx, "apply", "-f", "-"],
                        input=dec.stdout, text=True)
    raise SystemExit(ap.returncode)


def cmd_rekey(args: argparse.Namespace) -> None:
    need("sops")
    files = find_enc_files(args.path)
    if not files:
        die("no *.enc.yaml files found")
    failed = 0
    for f in files:
        if subprocess.run(["sops", "updatekeys", "-y", str(f)]).returncode == 0:
            print(f"rekeyed {f}")
        else:
            failed += 1
            print(f"FAILED {f}", file=sys.stderr)
    print("review the diff, then re-apply each out-of-band secret: secrets.py apply <path>")
    raise SystemExit(1 if failed else 0)


def cmd_lint(args: argparse.Namespace) -> None:
    problems = 0
    for f in find_enc_files([]):
        if not is_encrypted(f):
            problems += 1
            print(f"PLAINTEXT *.enc.yaml (not SOPS-encrypted): {f}", file=sys.stderr)
    for pat in ("*.dec.yaml", "*.plain.yaml"):
        for f in REPO_ROOT.rglob(pat):
            problems += 1
            print(f"stray plaintext secret file (gitignored, delete it): {f}", file=sys.stderr)
    if problems:
        die(f"{problems} secret hygiene problem(s) found")
    print("ok: all *.enc.yaml are encrypted; no stray plaintext")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("pull", help="snapshot a live Secret into an encrypted file")
    sp.add_argument("namespace")
    sp.add_argument("name")
    sp.add_argument("path", nargs="?")
    sp.set_defaults(func=cmd_pull)

    for name, fn, helptext in [
        ("edit", cmd_edit, "open decrypted in $EDITOR, re-encrypt on save"),
        ("view", cmd_view, "print the decrypted file to stdout"),
        ("encrypt", cmd_encrypt, "encrypt a freshly-authored plaintext file in place"),
        ("apply", cmd_apply, "decrypt and kubectl apply (out-of-band Secrets only)"),
    ]:
        s = sub.add_parser(name, help=helptext)
        s.add_argument("path")
        s.set_defaults(func=fn)

    sr = sub.add_parser("rekey", help="re-encrypt to the current .sops.yaml recipients")
    sr.add_argument("path", nargs="*")
    sr.set_defaults(func=cmd_rekey)

    sl = sub.add_parser("lint", help="fail if any *.enc.yaml is not encrypted")
    sl.set_defaults(func=cmd_lint)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
