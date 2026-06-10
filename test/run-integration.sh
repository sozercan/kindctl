#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KINDCTL="$ROOT/bin/kindctl"

skip_or_fail() {
  if [ "${KINDCTL_INTEGRATION_REQUIRE:-}" = "1" ]; then
    echo "FAIL: $*" >&2
    exit 1
  fi
  echo "SKIP: $*"
  exit 0
}

for cmd in kind docker kubectl python3 git; do
  command -v "$cmd" >/dev/null 2>&1 || skip_or_fail "missing $cmd"
done
if ! docker info >/dev/null 2>&1; then
  skip_or_fail "Docker daemon is not reachable"
fi

create_args=(--tag mw)
if [ -n "${KINDCTL_INTEGRATION_K8S_VERSION:-}" ]; then
  create_args+=(--k8s-version "$KINDCTL_INTEGRATION_K8S_VERSION")
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/kindctl-it.XXXXXX")"
cluster1=""
cluster2=""
cleanup() {
  set +e
  if [ -d "$tmp/wt-a/app" ]; then
    (cd "$tmp/wt-a/app" && HOME="$tmp/home" "$KINDCTL" delete --tag mw >/dev/null 2>&1 || true)
  fi
  if [ -d "$tmp/wt-b/app" ]; then
    (cd "$tmp/wt-b/app" && HOME="$tmp/home" "$KINDCTL" delete --tag mw >/dev/null 2>&1 || true)
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/home" "$tmp/wt-a/app" "$tmp/wt-b"
cd "$tmp/wt-a/app"
git init -q
git config user.email test@example.com
git config user.name Test
printf 'hello\n' > README.md
git add README.md
git commit -q -m init
git worktree add -q -b feature "$tmp/wt-b/app"

# Create a real kind cluster for worktree A.
cd "$tmp/wt-a/app"
HOME="$tmp/home" "$KINDCTL" create "${create_args[@]}"
path1="$(HOME="$tmp/home" "$KINDCTL" path --tag mw)"
cluster1="$(basename "$path1" .kubeconfig)"
printf 'worktree-a cluster=%s kubeconfig=%s\n' "$cluster1" "$path1"

# Existing worktree reuse: subdirectories in the same worktree derive the same
# cluster/kubeconfig and kubectl targets that same cluster.
mkdir -p nested/deeper
cd nested/deeper
path1_sub="$(HOME="$tmp/home" "$KINDCTL" path --tag mw)"
[ "$path1_sub" = "$path1" ] || { echo "worktree A did not reuse existing kubeconfig" >&2; exit 1; }
HOME="$tmp/home" "$KINDCTL" kubectl --tag mw get nodes

# Create a real kind cluster for a second git worktree of the same repo.
cd "$tmp/wt-b/app"
HOME="$tmp/home" "$KINDCTL" create "${create_args[@]}"
path2="$(HOME="$tmp/home" "$KINDCTL" path --tag mw)"
cluster2="$(basename "$path2" .kubeconfig)"
printf 'worktree-b cluster=%s kubeconfig=%s\n' "$cluster2" "$path2"

[ "$cluster1" != "$cluster2" ] || { echo "two worktrees derived the same cluster name" >&2; exit 1; }
[ "$path1" != "$path2" ] || { echo "two worktrees derived the same kubeconfig path" >&2; exit 1; }

clusters="$(kind get clusters)"
printf 'live clusters after create:\n%s\n' "$clusters"
printf '%s\n' "$clusters" | grep -Fx "$cluster1" >/dev/null
printf '%s\n' "$clusters" | grep -Fx "$cluster2" >/dev/null

# Repeated command from worktree B reuses its existing cluster.
path2_again="$(HOME="$tmp/home" "$KINDCTL" path --tag mw)"
[ "$path2_again" = "$path2" ] || { echo "worktree B did not reuse existing kubeconfig" >&2; exit 1; }
HOME="$tmp/home" "$KINDCTL" kubectl --tag mw get nodes

# Operational commands still work with the scoped, worktree-specific cluster.
HOME="$tmp/home" "$KINDCTL" hibernate --tag mw
HOME="$tmp/home" "$KINDCTL" resume --tag mw
HOME="$tmp/home" "$KINDCTL" doctor

# Delete both clusters explicitly from their owning worktrees.
cd "$tmp/wt-b/app"
HOME="$tmp/home" "$KINDCTL" delete --tag mw
cd "$tmp/wt-a/app"
HOME="$tmp/home" "$KINDCTL" delete --tag mw

clusters_after="$(kind get clusters)"
if printf '%s\n' "$clusters_after" | grep -Fx "$cluster1" >/dev/null || \
   printf '%s\n' "$clusters_after" | grep -Fx "$cluster2" >/dev/null; then
  echo "integration clusters still present after cleanup" >&2
  printf '%s\n' "$clusters_after" >&2
  exit 1
fi

echo "integration ok: unique real clusters per worktree and reuse within existing worktrees verified"
