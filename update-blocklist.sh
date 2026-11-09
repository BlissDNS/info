#!/usr/bin/env bash
# update-blocklist.sh: pull the Bliss DNS bad IP list and load it into dnsdist.
# Only restarts dnsdist when the list actually changed and the new config passes
# dnsdist --check-config. A failed download or a bad list leaves the old one in place.
set -euo pipefail
export LC_ALL=C

URL="https://raw.githubusercontent.com/BlissDNS/info/refs/heads/main/badips.txt"
OUT="/etc/dnsdist/blocked.txt"
CONF="/etc/dnsdist/dnsdist.conf"
MIN_ENTRIES=50
DRY_RUN=0

usage() {
	printf 'Usage: %s [-u url] [-o file] [-c dnsdist.conf] [-m min_entries] [-n]\n' "${0##*/}"
	printf '  -u  list URL (default: the BlissDNS/info badips.txt)\n'
	printf '  -o  output file dnsdist reads (default: %s)\n' "$OUT"
	printf '  -c  dnsdist config to check (default: %s)\n' "$CONF"
	printf '  -m  refuse lists with fewer valid entries than this (default: %s)\n' "$MIN_ENTRIES"
	printf '  -n  update and check the file, but do not restart dnsdist\n'
}

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

while getopts 'u:o:c:m:nh' opt; do
	case "$opt" in
		u) URL="$OPTARG" ;;
		o) OUT="$OPTARG" ;;
		c) CONF="$OPTARG" ;;
		m) MIN_ENTRIES="$OPTARG" ;;
		n) DRY_RUN=1 ;;
		h) usage; exit 0 ;;
		*) usage >&2; exit 1 ;;
	esac
done

case "$MIN_ENTRIES" in
	'' | *[!0-9]*) die "-m needs a whole number" ;;
esac

# Check every required command up front and report all missing ones at once.
missing=()
for cmd in dnsdist grep sed tr sort cmp cp mv rm chmod mkdir rmdir mktemp wc head; do
	command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
fetcher=""
if command -v curl >/dev/null 2>&1; then
	fetcher=curl
elif command -v wget >/dev/null 2>&1; then
	fetcher=wget
else
	missing+=("curl or wget")
fi
if [ "${#missing[@]}" -gt 0 ]; then
	printf 'error: missing required commands: %s\n' "${missing[*]}" >&2
	exit 1
fi

outdir="${OUT%/*}"
[ "$outdir" = "$OUT" ] && outdir="."
[ -d "$outdir" ] || die "output directory does not exist: $outdir"
[ -w "$outdir" ] || die "cannot write to $outdir (run as root?)"
[ -f "$CONF" ] || die "dnsdist config not found: $CONF"

# mkdir is atomic, so it works as a lock without flock.
LOCK="${OUT}.lock"
mkdir -- "$LOCK" 2>/dev/null || die "another run is in progress (remove $LOCK if it is stale)"

raw=""
cleaned=""
staged=""
backup=""
checklog=""
cleanup() {
	rm -f -- "$raw" "$cleaned" "$staged" "$backup" "$checklog"
	rmdir -- "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT

raw="$(mktemp "${TMPDIR:-/tmp}/badips-raw.XXXXXX")"
cleaned="$(mktemp "${TMPDIR:-/tmp}/badips-clean.XXXXXX")"
checklog="$(mktemp "${TMPDIR:-/tmp}/badips-check.XXXXXX")"
# Staged file lives next to the output so the final mv is an atomic rename.
staged="$(mktemp "$outdir/.blocked.XXXXXX")"

if [ "$fetcher" = curl ]; then
	curl -fsSL --max-time 60 -o "$raw" -- "$URL" || die "download failed: $URL"
else
	wget -q -T 60 -O "$raw" -- "$URL" || die "download failed: $URL"
fi

# Strip CRs, comments, whitespace and blank lines.
tr -d '\r' <"$raw" | sed -e 's/#.*//' -e 's/[[:space:]]//g' | grep -v '^$' >"$cleaned" || true

# Loose shape checks. dnsdist --check-config catches anything malformed that slips past.
v4='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'
v6='^[0-9A-Fa-f]*:[0-9A-Fa-f:.]*(/[0-9]{1,3})?$'

grep -E -e "$v4" -e "$v6" "$cleaned" | sort -u >"$staged" || true

# grep -c exits 1 on zero matches, which is fine here.
rejected=$(grep -E -c -v -e "$v4" -e "$v6" "$cleaned" || true)
rejected=$((rejected))
count=$(wc -l <"$staged")
count=$((count))

if [ "$rejected" -gt 0 ]; then
	printf 'warning: skipped %s line(s) that are not IPs or CIDRs, first few:\n' "$rejected" >&2
	grep -E -v -e "$v4" -e "$v6" "$cleaned" | head -n 5 >&2 || true
fi

if [ "$count" -lt "$MIN_ENTRIES" ]; then
	die "only $count valid entries (minimum $MIN_ENTRIES), keeping the current list"
fi

if [ -f "$OUT" ] && cmp -s -- "$staged" "$OUT"; then
	printf 'No changes (%s entries).\n' "$count"
	exit 0
fi

# mktemp creates files as 0600. dnsdist usually runs as its own user and needs to read this.
chmod 0644 -- "$staged"

had_old=0
if [ -f "$OUT" ]; then
	backup="$(mktemp "$outdir/.blocked-old.XXXXXX")"
	cp -p -- "$OUT" "$backup"
	had_old=1
fi

mv -- "$staged" "$OUT"
staged=""

if ! dnsdist --check-config -C "$CONF" >"$checklog" 2>&1; then
	if [ "$had_old" -eq 1 ]; then
		mv -- "$backup" "$OUT"
		backup=""
	else
		rm -f -- "$OUT"
	fi
	printf 'error: dnsdist --check-config failed with the new list, old list restored:\n' >&2
	head -n 20 "$checklog" >&2 || true
	exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
	printf 'Updated %s with %s entries. Config check passed. Not restarting (-n).\n' "$OUT" "$count"
	exit 0
fi

restart_dnsdist() {
	if command -v systemctl >/dev/null 2>&1; then
		systemctl restart dnsdist
	elif command -v rc-service >/dev/null 2>&1; then
		rc-service dnsdist restart
	elif command -v sv >/dev/null 2>&1; then
		sv restart dnsdist
	elif command -v service >/dev/null 2>&1; then
		service dnsdist restart
	else
		return 2
	fi
}

rc=0
restart_dnsdist || rc=$?
if [ "$rc" -eq 2 ]; then
	die "list updated, but no service manager found to restart dnsdist, restart it yourself"
elif [ "$rc" -ne 0 ]; then
	die "list updated and checked, but restarting dnsdist failed"
fi

printf 'Loaded %s entries into dnsdist.\n' "$count"
