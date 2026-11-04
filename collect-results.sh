#!/bin/sh
# Aggregates the results-*.csv artifacts written by pull-bench.sh into a single
# results.csv artifact and a summary annotation comparing the default and
# unaccelerated queues. Rounds are inferred per queue from job start order.

set -eu

dir=$(mktemp -d)
buildkite-agent artifact download "results-*.csv" "$dir"

set -- $(find "$dir" -name 'results-*.csv' | sort)
if [ $# -eq 0 ]; then
	echo "no results-*.csv artifacts found" >&2
	exit 1
fi

head -n 1 "$1" >results.csv
for f in "$@"; do tail -n +2 "$f"; done >>results.csv
buildkite-agent artifact upload results.csv

awk '
BEGIN { FS = ","; A = "default"; B = "unaccelerated" }
NR == 1 { next }
{
	q = $1; j = $2; s = $4; img = $5; d = $6; ms = $7; by = $8
	if (!((q, j) in js)) { js[q, j] = s; nj[q]++; jobs[q, nj[q]] = j }
	if (!(img in isize)) { nimg++; imgs[nimg] = img }
	isize[img] = by
	t[q, j, img] = ms
	tot[q, j] += ms
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

function median(n, v,   i, k, tmp) {
	if (n == 0) return ""
	for (i = 2; i <= n; i++) {
		tmp = v[i]; k = i - 1
		while (k >= 1 && v[k] + 0 > tmp + 0) { v[k + 1] = v[k]; k-- }
		v[k + 1] = tmp
	}
	return (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
}

# Time for one round; img == "" means the per-job total.
function cell(q, r, img,   j) {
	if (r > nj[q]) return ""
	j = jobs[q, r]
	if (img == "") return ((q, j) in tot) ? tot[q, j] : ""
	return ((q, j, img) in t) ? t[q, j, img] : ""
}

function med(q, img,   n, r, x, v) {
	split("", v); n = 0
	for (r = 1; r <= nj[q]; r++) { x = cell(q, r, img); if (x != "") v[++n] = x }
	return median(n, v)
}

function sec(ms) { return (ms == "") ? "–" : sprintf("%.2fs", ms / 1000) }
function speedup(a, b) { return (a == "" || b == "" || a == 0) ? "–" : sprintf("%.2f×", b / a) }
function mbps(by, ms) { return (ms == "" || ms == 0) ? "–" : sprintf("%.0f", by / 1e6 / (ms / 1000)) }

function row(label, by, img,   a, b) {
	a = med(A, img); b = med(B, img)
	printf "| %s | %.0f MB | %s | %s | %s | %s | %s |\n", label, by / 1e6, sec(a), sec(b), speedup(a, b), mbps(by, a), mbps(by, b)
}

function roundrow(label, img,   r) {
	printf "| %s |", label
	for (r = 1; r <= rounds; r++) printf " %s | %s |", sec(cell(A, r, img)), sec(cell(B, r, img))
	printf "\n"
}

END {
	sortjobs(A); sortjobs(B)
	rounds = (nj[A] > nj[B]) ? nj[A] : nj[B]
	for (i = 1; i <= nimg; i++) totsize += isize[imgs[i]]

	print "### :whale: Docker pull: default vs unaccelerated"
	print ""
	printf "Median of %d default and %d unaccelerated runs; local image cache cleared before each pull. Speedup = unaccelerated ÷ default. MB/s is uncompressed image size ÷ pull time.\n", nj[A], nj[B]
	print ""
	print "| Image | Size | default | unaccelerated | Speedup | default MB/s | unaccelerated MB/s |"
	print "|---|--:|--:|--:|--:|--:|--:|"
	for (i = 1; i <= nimg; i++) row("`" imgs[i] "`", isize[imgs[i]], imgs[i])
	row("**Total**", totsize, "")

	print ""
	print "<details><summary>Per-round times</summary>"
	print ""
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
' results.csv >summary.md

cat summary.md
buildkite-agent annotate --style info --context pull-bench <summary.md
