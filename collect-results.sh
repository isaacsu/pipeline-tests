#!/bin/sh
# Aggregates per-job result CSVs into a single CSV artifact and a summary
# annotation comparing the default and unaccelerated queues. Rounds are
# inferred per queue from job start order.
#
# Usage: collect-results.sh [docker|skopeo]
#   docker (default): results-*.csv from pull-bench.sh
#   skopeo:           skopeo-results-*.csv from skopeo-bench.sh

set -eu

mode="${1:-docker}"
case "$mode" in
docker)
	prefix="results"
	title=":whale: Docker pull: default vs unaccelerated"
	note="Local image cache cleared before each pull. MB/s is uncompressed image size ÷ pull time."
	;;
skopeo)
	prefix="skopeo-results"
	title=":package: Skopeo pull: default (accelerator) vs unaccelerated"
	note="\`skopeo copy\` to a fresh \`dir:\` each pull, no Docker daemon involved. MB/s is compressed (transferred) size ÷ pull time."
	;;
*)
	echo "usage: $0 [docker|skopeo]" >&2
	exit 2
	;;
esac

dir=$(mktemp -d)
buildkite-agent artifact download "$prefix-*.csv" "$dir"

set -- $(find "$dir" -name "$prefix-*.csv" | sort)
if [ $# -eq 0 ]; then
	echo "no $prefix-*.csv artifacts found" >&2
	exit 1
fi

head -n 1 "$1" >"$prefix.csv"
for f in "$@"; do tail -n +2 "$f"; done >>"$prefix.csv"
buildkite-agent artifact upload "$prefix.csv"

awk -v title="$title" -v note="$note" '
BEGIN { FS = ","; A = "default"; B = "unaccelerated"; na = 1 }
NR == 1 { next }
{
	q = $1; j = $2; s = $4; img = $5; d = $6; ms = $7; by = $8
	a = (NF >= 9 && $9 != "") ? $9 + 0 : 1
	if (a > na) na = a
	if (!((q, j) in js)) { js[q, j] = s; nj[q]++; jobs[q, nj[q]] = j }
	if (!(img in isize)) { nimg++; imgs[nimg] = img }
	isize[img] = by
	t[q, j, img, a] = ms
	tot[q, j, "", a] += ms
	dg[q, j, img] = d
	if (!((img, d) in seen)) { seen[img, d] = 1; nd[img]++; dl[img, nd[img]] = d }
}

function sortjobs(q,   i, k, tmp) {
	for (i = 2; i <= nj[q]; i++) {
		tmp = jobs[q, i]; k = i - 1
		while (k >= 1 && js[q, jobs[q, k]] + 0 > js[q, tmp] + 0) { jobs[q, k + 1] = jobs[q, k]; k-- }
		jobs[q, k + 1] = tmp
	}
}

function sortv(n, v,   i, k, tmp) {
	for (i = 2; i <= n; i++) {
		tmp = v[i]; k = i - 1
		while (k >= 1 && v[k] + 0 > tmp + 0) { v[k + 1] = v[k]; k-- }
		v[k + 1] = tmp
	}
}

# Collects pull times for queue q into v (sorted) and returns the count.
# img == "" means per-job totals (sum over images for one attempt); r == 0
# means all rounds; attempts lo..hi inclusive.
function collect(q, img, r, lo, hi, v,   n, rr, r0, r1, a, j) {
	split("", v); n = 0
	r0 = r ? r : 1; r1 = r ? r : nj[q]
	for (rr = r0; rr <= r1 && rr <= nj[q]; rr++) {
		j = jobs[q, rr]
		for (a = lo; a <= hi; a++) {
			if (img == "") { if ((q, j, "", a) in tot) v[++n] = tot[q, j, "", a] }
			else if ((q, j, img, a) in t) v[++n] = t[q, j, img, a]
		}
	}
	sortv(n, v)
	return n
}

function med(q, img, r, lo, hi,   n, v) {
	n = collect(q, img, r, lo, hi, v)
	if (n == 0) return ""
	return (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
}

function range(q, img, r,   n, v) {
	n = collect(q, img, r, 1, na, v)
	if (n == 0) return "–"
	return sprintf("%.2f–%.2fs", v[1] / 1000, v[n] / 1000)
}

function sec(ms) { return (ms == "") ? "–" : sprintf("%.2fs", ms / 1000) }
function speedup(a, b) { return (a == "" || b == "" || a == 0) ? "–" : sprintf("%.2f×", b / a) }
function mbps(by, ms) { return (ms == "" || ms == 0) ? "–" : sprintf("%.0f", by / 1e6 / (ms / 1000)) }

function row(label, by, img,   a, b) {
	a = med(A, img, 0, 1, na); b = med(B, img, 0, 1, na)
	printf "| %s | %.0f MB | %s | %s | %s |", label, by / 1e6, sec(a), sec(b), speedup(a, b)
	if (na > 1)
		printf " %s | %s | %s | %s |", sec(med(A, img, 0, 1, 1)), sec(med(B, img, 0, 1, 1)), sec(med(A, img, 0, 2, na)), sec(med(B, img, 0, 2, na))
	printf " %s | %s | %s | %s |\n", range(A, img, 0), range(B, img, 0), mbps(by, a), mbps(by, b)
}

function rcell(q, r, img) {
	if (na == 1) return sec(med(q, img, r, 1, 1))
	return sec(med(q, img, r, 1, na)) " (" range(q, img, r) ")"
}

function roundrow(label, img,   r) {
	printf "| %s |", label
	for (r = 1; r <= rounds; r++) printf " %s | %s |", rcell(A, r, img), rcell(B, r, img)
	printf "\n"
}

END {
	sortjobs(A); sortjobs(B)
	rounds = (nj[A] > nj[B]) ? nj[A] : nj[B]
	for (i = 1; i <= nimg; i++) totsize += isize[imgs[i]]

	print "### " title
	print ""
	if (na > 1)
		printf "Median of all pulls across %d default and %d unaccelerated runs, %d pulls of each image back to back per run. 1st = first pull of each image in a run (may miss the accelerator cache); Repeat = pulls 2–%d. Range = fastest–slowest pull. ", nj[A], nj[B], na, na
	else
		printf "Median of %d default and %d unaccelerated runs. ", nj[A], nj[B]
	printf "%s Speedup = unaccelerated ÷ default.\n", note
	print ""
	printf "| Image | Size | default | unaccelerated | Speedup |"
	if (na > 1) printf " default 1st | unaccelerated 1st | default repeat | unaccelerated repeat |"
	printf " default range | unaccelerated range | default MB/s | unaccelerated MB/s |\n"
	printf "|---|--:|--:|--:|--:|"
	if (na > 1) printf "--:|--:|--:|--:|"
	printf "--:|--:|--:|--:|\n"
	for (i = 1; i <= nimg; i++) row("`" imgs[i] "`", isize[imgs[i]], imgs[i])
	row("**Total**", totsize, "")

	print ""
	print "<details><summary>Per-round times</summary>"
	print ""
	if (na > 1) { printf "Median of %d pulls (fastest–slowest).\n", na; print "" }
	printf "| Image |"
	for (r = 1; r <= rounds; r++) printf " R%d default | R%d unaccelerated |", r, r
	printf "\n|---|"
	for (r = 1; r <= rounds; r++) printf "--:|--:|"
	printf "\n"
	for (i = 1; i <= nimg; i++) roundrow("`" imgs[i] "`", imgs[i])
	roundrow("**Total**", "")
	print ""
	print "</details>"

	for (i = 1; i <= nimg; i++) {
		img = imgs[i]
		if (nd[img] < 2) continue
		if (!warned) { print ""; print "#### :warning: Digest drift"; print ""; warned = 1 }
		line = "- `" img "` resolved to " nd[img] " digests:"
		for (k = 1; k <= nd[img]; k++) {
			d = dl[img, k]; where = ""
			for (qi = 1; qi <= 2; qi++) {
				q = (qi == 1) ? A : B
				for (r = 1; r <= nj[q]; r++)
					if (dg[q, jobs[q, r], img] == d) where = where (where == "" ? "" : ", ") q " R" r
			}
			line = line (k > 1 ? ";" : "") " `" substr(d, 1, 19) "…` (" where ")"
		}
		print line
	}
}
' "$prefix.csv" >"summary-$mode.md"

cat "summary-$mode.md"
buildkite-agent annotate --style info --context "$mode-pull-bench" <"summary-$mode.md"
