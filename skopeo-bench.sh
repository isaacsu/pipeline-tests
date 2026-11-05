#!/bin/sh
# Skopeo pull benchmark: times `skopeo copy` of each image from Docker Hub into
# a scratch dir: on this agent's queue, bypassing the Docker daemon's image store.
#
# When ACCELERATOR_PROXY is set, skopeo is routed through that HTTPS
# pull-through caching proxy, trusting the CA it serves at /ca.crt. Otherwise
# it goes direct to Docker Hub.
#
# Skopeo runs in one long-lived container per job (docker cp + exec rather than
# bind mounts, so it works with a remote/DinD daemon), so container start-up is
# not part of the timings. Results are written to
# skopeo-results-<queue>-<job_id>.csv and uploaded as an artifact for
# `collect-results.sh skopeo` to aggregate.

set -eu

IMAGES="golang:latest node:latest python:latest ruby:latest rust:latest eclipse-temurin:latest php:latest"
SKOPEO_IMAGE="quay.io/skopeo/stable:v1.22.3"

queue="${BUILDKITE_AGENT_META_DATA_QUEUE:-unknown}"
job="${BUILDKITE_JOB_ID:-local}"
agent="${BUILDKITE_AGENT_NAME:-unknown}"
proxy="${ACCELERATOR_PROXY:-}"
out="skopeo-results-${queue}-${job}.csv"
ctr="skopeo-bench-${job}"

# Milliseconds since the epoch; falls back to whole seconds where date lacks %N.
now_ms() {
	ns=$(date +%s%N 2>/dev/null || true)
	case "$ns" in
	"" | *[!0-9]*) echo $(($(date +%s) * 1000)) ;;
	*) if [ ${#ns} -ge 16 ]; then echo $((ns / 1000000)); else echo $(($(date +%s) * 1000)); fi ;;
	esac
}

section() { printf '\n=== %s ===\n' "$1"; }

sk() { docker exec "$ctr" "$@"; }

tmp=$(mktemp -d)
cleanup() {
	docker rm -f "$ctr" >/dev/null 2>&1 || true
	rm -rf "$tmp"
}
trap cleanup EXIT

section "context"
arch=$(docker version --format '{{.Server.Arch}}')
echo "queue=$queue job=$job agent=$agent arch=$arch"
echo "proxy=${proxy:-<none, direct to Docker Hub>}"
case "$(date +%s%N 2>/dev/null || true)" in
"" | *[!0-9]*) echo "warning: date has no %N support; timings have 1s resolution" ;;
esac

section "setup"
docker pull -q "$SKOPEO_IMAGE" >/dev/null

set -- --name "$ctr" --entrypoint sleep
if [ -n "$proxy" ]; then
	set -- "$@" \
		-e "HTTPS_PROXY=$proxy" -e "https_proxy=$proxy" \
		-e "HTTP_PROXY=$proxy" -e "http_proxy=$proxy" \
		-e "SSL_CERT_DIR=/tmp/certs:/etc/ssl/certs:/etc/pki/tls/certs"
fi
docker run -d "$@" "$SKOPEO_IMAGE" infinity >/dev/null
echo "skopeo: $(sk skopeo --version)"

if [ -n "$proxy" ]; then
	ca_url="${proxy%/}/ca.crt"
	if command -v curl >/dev/null 2>&1; then
		curl -fsS --noproxy '*' -o "$tmp/proxy-ca.crt" "$ca_url"
	elif command -v wget >/dev/null 2>&1; then
		no_proxy='*' wget -q -O "$tmp/proxy-ca.crt" "$ca_url"
	else
		sk curl -fsS --noproxy '*' "$ca_url" >"$tmp/proxy-ca.crt"
	fi
	if ! grep -q 'BEGIN CERTIFICATE' "$tmp/proxy-ca.crt"; then
		echo "error: $ca_url did not return a PEM certificate" >&2
		exit 1
	fi
	sk mkdir -p /tmp/certs
	docker cp -q "$tmp/proxy-ca.crt" "$ctr:/tmp/certs/proxy-ca.crt"
	echo "trusting proxy CA from $ca_url"
fi

auth="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
set --
if [ -f "$auth" ]; then
	docker cp -q "$auth" "$ctr:/tmp/auth.json"
	set -- --authfile /tmp/auth.json
	echo "using registry credentials from $auth"
	if grep -Eq '"(credsStore|credHelpers)"' "$auth"; then
		echo "warning: $auth uses a credential helper, which skopeo cannot use inside the container"
	fi
else
	echo "warning: no $auth; pulling anonymously"
fi

job_start=$(now_ms)
echo "queue,job_id,agent,job_start_ms,image,digest,ms,bytes" >"$out"

section "pulls"
printf '%-24s %10s %10s\n' image seconds MB
for img in $IMAGES; do
	sk rm -rf /tmp/out

	t0=$(now_ms)
	sk skopeo copy -q "$@" --override-os linux --override-arch "$arch" \
		"docker://docker.io/library/$img" dir:/tmp/out >/dev/null
	t1=$(now_ms)

	ms=$((t1 - t0))
	digest="sha256:$(sk sha256sum /tmp/out/manifest.json | cut -d' ' -f1)"
	bytes=$(sk sh -c 'cat /tmp/out/[0-9a-f]* | wc -c' | tr -d ' ')

	echo "$queue,$job,$agent,$job_start,$img,$digest,$ms,$bytes" >>"$out"
	awk -v i="$img" -v ms="$ms" -v b="$bytes" 'BEGIN { printf "%-24s %10.2f %10.0f\n", i, ms / 1000, b / 1e6 }'
done

if command -v buildkite-agent >/dev/null 2>&1; then
	buildkite-agent artifact upload "$out"
fi
