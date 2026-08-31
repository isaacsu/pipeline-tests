#!/bin/sh
# State-carryover probe for the dind-runner pool.
#
# Run this as a Buildkite job command twice in a row on the same queue and
# compare the SECOND job's output. It reports whether workspace files, Docker
# volumes, containers, and networks survived from the previous job, and confirms
# the image cache persists (which it should in BOTH single-use and multi-use).
#
# Expected results on the second job:
#
#   SINGLE_USE=true  (fixed):  workspace clean, 0 leftover volumes/containers/nets
#   SINGLE_USE=false (pool):   workspace + volumes + networks carried over
#   image cache:               present in BOTH modes
#
# Pipeline usage:
#   steps:
#     - command: examples/dind-runner/probe.sh
#       agents: { queue: default }
#     - wait
#     - command: examples/dind-runner/probe.sh   # inspect THIS job's output
#       agents: { queue: default }
#
# Safe to run repeatedly: it cleans up the leftovers it created for the NEXT
# job only where that would defeat the test, so it deliberately leaves markers
# behind. It never touches the image/build cache.

set -u

carryover=0
ws_marker="/workspace/carryover.txt"

section() { printf '\n=== %s ===\n' "$1"; }

section "context"
echo "build=${BUILDKITE_BUILD_NUMBER:-?} job=${BUILDKITE_JOB_ID:-?}"
echo "agent=${BUILDKITE_AGENT_NAME:-?} at $(date -u 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 1. Workspace filesystem carryover
# ---------------------------------------------------------------------------
section "workspace marker from previous job"
if [ -f "$ws_marker" ]; then
	echo "!! WORKSPACE CARRYOVER:"
	cat "$ws_marker"
	carryover=1
else
	echo "clean workspace (no marker)"
fi

# Leave a marker for the next job.
echo "build=${BUILDKITE_BUILD_NUMBER:-?} agent=${BUILDKITE_AGENT_NAME:-?} at $(date -u 2>/dev/null || true)" \
	>"$ws_marker" 2>/dev/null || echo "could not write $ws_marker (is /workspace mounted?)"

section "/workspace tree"
ls -la /workspace /workspace/builds /workspace/plugins 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Docker daemon state (volumes / containers / networks)
# ---------------------------------------------------------------------------
if docker info >/dev/null 2>&1; then
	section "volumes left by previous job"
	docker volume ls
	vol_count=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
	echo "volume count: $vol_count"
	# Only the probe's own named volume signals carryover, mirroring the
	# container (^(leaker|anon-leaker)$) and network (^carryover-net$)
	# checks below. Stray anonymous volumes (hex-named) are ignored: they
	# can survive a legitimate cleanup race (in-use at prune time) or be
	# created implicitly by images with a VOLUME directive, so they are
	# not a reliable carryover signal.
	if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -Eq '^carryover-named$'; then
		echo "!! VOLUME CARRYOVER (carryover-named)"
		carryover=1
	else
		echo "no probe named volume left over"
	fi

	section "carryover containers/networks from previous job"
	if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^(leaker|anon-leaker)$'; then
		echo "!! CONTAINER CARRYOVER"
		docker ps -a
		carryover=1
	else
		echo "no probe containers left over"
	fi
	if docker network ls --format '{{.Name}}' 2>/dev/null | grep -Eq '^carryover-net$'; then
		echo "!! NETWORK CARRYOVER (carryover-net)"
		carryover=1
	else
		echo "no probe network left over"
	fi

	section "creating leftovers for the next job"
	docker run -d --name leaker -v carryover-named:/data busybox sleep 3600 >/dev/null 2>&1 \
		&& echo "created container 'leaker' + named volume 'carryover-named'"
	docker run -d --name anon-leaker -v /data busybox sleep 3600 >/dev/null 2>&1 \
		&& echo "created container 'anon-leaker' + anonymous volume"
	docker network create carryover-net >/dev/null 2>&1 \
		&& echo "created network 'carryover-net'"

	# -------------------------------------------------------------------
	# 3. Image cache (must persist in BOTH modes)
	# -------------------------------------------------------------------
	section "image cache"
	docker images
	echo "pulling hello-world (should be cached on the second job):"
	docker pull hello-world:latest 2>&1 | grep -i -e 'up to date' -e 'downloaded' -e 'pull complete' \
		|| echo "(pull output suppressed)"
else
	section "docker"
	echo "docker daemon not reachable from this job; skipping daemon checks"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
section "verdict"
if [ "$carryover" -eq 1 ]; then
	echo "STATE CARRIED OVER from a previous job (expected in multi-use / SINGLE_USE=false)"
else
	echo "clean slate (expected in single-use / SINGLE_USE=true)"
fi
