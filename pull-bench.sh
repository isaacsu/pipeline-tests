#!/bin/sh
# Docker pull benchmark: times a cold pull of each image on this agent's queue.
#
# The local image cache is cleared before every image so each pull is measured
# in isolation (no shared base layers from a previous pull). Results are written
# to results-<queue>-<job_id>.csv and uploaded as an artifact for
# collect-results.sh to aggregate.

set -eu

IMAGES="golang:latest node:latest python:latest ruby:latest rust:latest eclipse-temurin:latest php:latest"

queue="${BUILDKITE_AGENT_META_DATA_QUEUE:-unknown}"
job="${BUILDKITE_JOB_ID:-local}"
agent="${BUILDKITE_AGENT_NAME:-unknown}"
out="results-${queue}-${job}.csv"

# Milliseconds since the epoch; falls back to whole seconds where date lacks %N.
now_ms() {
	ns=$(date +%s%N 2>/dev/null || true)
	case "$ns" in
	"" | *[!0-9]*) echo $(($(date +%s) * 1000)) ;;
	*) if [ ${#ns} -ge 16 ]; then echo $((ns / 1000000)); else echo $(($(date +%s) * 1000)); fi ;;
	esac
}

section() { printf '\n=== %s ===\n' "$1"; }

section "context"
echo "queue=$queue job=$job agent=$agent"
echo "registry mirrors: $(docker info --format '{{json .RegistryConfig.Mirrors}}' 2>/dev/null || echo '?')"
case "$(date +%s%N 2>/dev/null || true)" in
"" | *[!0-9]*) echo "warning: date has no %N support; timings have 1s resolution" ;;
esac

job_start=$(now_ms)
echo "queue,job_id,agent,job_start_ms,image,digest,ms,bytes" >"$out"

section "pulls"
printf '%-24s %10s %10s\n' image seconds MB
for img in $IMAGES; do
	docker image prune -af >/dev/null

	t0=$(now_ms)
	docker pull -q "$img" >/dev/null
	t1=$(now_ms)

	ms=$((t1 - t0))
	repo_digest=$(docker image inspect -f '{{index .RepoDigests 0}}' "$img")
	digest="${repo_digest#*@}"
	bytes=$(docker image inspect -f '{{.Size}}' "$img")

	echo "$queue,$job,$agent,$job_start,$img,$digest,$ms,$bytes" >>"$out"
	awk -v i="$img" -v ms="$ms" -v b="$bytes" 'BEGIN { printf "%-24s %10.2f %10.0f\n", i, ms / 1000, b / 1e6 }'
done

docker image prune -af >/dev/null

if command -v buildkite-agent >/dev/null 2>&1; then
	buildkite-agent artifact upload "$out"
fi
