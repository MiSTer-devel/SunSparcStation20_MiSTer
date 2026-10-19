#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# ub.sh build | run [COPIES] [TESTS...] - byte-unixbench's System Benchmarks
# Index tests without its Perl driver, for a NetBSD/sparc with no Perl
# (pkgsrc has no binary packages for sparc32). Run from the UnixBench
# directory (pgms/, src/, testdir/ from github.com/kdlucas/byte-unixbench).
#
#   build   compiles the 12 index tests' programs with the system cc
#   run     runs each test as UnixBench's Run does (the same commands and
#           options, the last COUNT/TIME a program prints as Run keeps,
#           10 passes for the "long" tests and 3 for the others,
#           `sync; sleep 1; sync; sleep 2` before each, COPIES copies in
#           parallel, default 1) and prints one line per copy and pass:
#             UB|test|pass|copy|elapsed|COUNT|count|timebase|label[|TIME|t]
#           tools/unixbench/ubscore.py turns those lines into the index
#           against UnixBench's baseline, a SPARCstation 20-61 (= 10.0).
# Elapsed times come from /usr/bin/time -p (10 ms); the tests run for 10 to
# 60 s each.

CC=${CC:-cc}
CFLAGS=${CFLAGS:-"-O2 -mcpu=supersparc"}
TESTS_ALL="dhry2reg whetstone-double execl fstime fsbuffer fsdisk pipe context1 spawn shell1 shell8 syscall"

build() {
	mkdir -p pgms tmp
	# execl passes its start time on as text and reads it back with
	# sscanf("%lu") straight into a time_t: with NetBSD's 64-bit time_t on
	# 32-bit big-endian SPARC that fills the wrong half and the test ends
	# after a few execs. Read it into an unsigned long first.
	sed 's/sscanf(argv\[4\], "%lu", (unsigned long \*) &start_time);/{ unsigned long st_; sscanf(argv[4], "%lu", \&st_); start_time = st_; }/' \
	    src/execl.c > src/execl-fixed.c || exit 1
	grep -q 'st_' src/execl-fixed.c || { echo "execl.c patch did not apply"; exit 1; }
	F="$CFLAGS -DTIME -I src"
	# spawn and looper end their run from SIGALRM with fprintf and exit;
	# when the alarm lands inside fork(), NetBSD 11's dynamic linker holds
	# its exclusive lock, exit() (and a first fprintf's lazy binding) waits
	# for it, and the process parks on itself for ever (seen on the board
	# and in QEMU in minutes). Their signal handlers run with a flag set,
	# and exit() leaves through fflush + _exit only then: the children's
	# exit() in the timed loop stays the real one. They bind at load (-z now).
	cat > src/ub_sigsafe.h <<'EOH'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static volatile sig_atomic_t ub_in_handler;
static void (*ub_handler)(int);
static void ub_exit(int c) { if (ub_in_handler) { fflush(NULL); _exit(c); } exit(c); }
static void ub_wrap(int sig) { ub_in_handler = 1; ub_handler(sig); ub_in_handler = 0; }
static void (*ub_signal(int sig, void (*f)(int)))(int)
{ if (f == SIG_IGN || f == SIG_DFL) return signal(sig, f); ub_handler = f; return signal(sig, ub_wrap); }
#define exit ub_exit
#define signal ub_signal
EOH
	S="-include src/ub_sigsafe.h -Wl,-z,now"
	set -x
	$CC $F -DHZ=100 -DREG=register -o pgms/dhry2reg src/dhry_1.c src/dhry_2.c || exit 1
	$CC $F -DDP -DGTODay -DUNIXBENCH -o pgms/whetstone-double src/whets.c -lm || exit 1
	$CC $F -o pgms/execl src/execl-fixed.c || exit 1
	for p in pipe fstime syscall context1; do
		$CC $F -o pgms/$p src/$p.c || exit 1
	done
	for p in spawn looper; do
		$CC $F $S -o pgms/$p src/$p.c || exit 1
	done
	set +x
	echo "UB-BUILD-DONE"
}

# the command line and pass count of a test (UnixBench's Run, testParams)
params() {
	B=$UB_BINDIR; T=$UB_TMPDIR
	case $1 in
	dhry2reg)         N=10; CMD="$B/dhry2reg 10" ;;
	whetstone-double) N=10; CMD="$B/whetstone-double" ;;
	syscall)          N=10; CMD="$B/syscall 10" ;;
	context1)         N=10; CMD="$B/context1 10" ;;
	pipe)             N=10; CMD="$B/pipe 10" ;;
	spawn)            N=3;  CMD="$B/spawn 30" ;;
	execl)            N=3;  CMD="$B/execl 30" ;;
	fstime)           N=3;  CMD="$B/fstime -c -t 30 -d $T -b 1024 -m 2000" ;;
	fsbuffer)         N=3;  CMD="$B/fstime -c -t 30 -d $T -b 256 -m 500" ;;
	fsdisk)           N=3;  CMD="$B/fstime -c -t 30 -d $T -b 4096 -m 8000" ;;
	shell1)           N=3;  CMD="$B/looper 60 $B/multi.sh 1" ;;
	shell8)           N=3;  CMD="$B/looper 60 $B/multi.sh 8" ;;
	*) echo "unknown test $1" >&2; exit 2 ;;
	esac
}

run() {
	COPIES=${1:-1}; shift 2>/dev/null
	TESTS=${*:-$TESTS_ALL}
	UB_BINDIR=$(pwd)/pgms UB_TMPDIR=$(pwd)/tmp UB_TESTDIR=$(pwd)/testdir
	export UB_BINDIR UB_TMPDIR UB_TESTDIR
	mkdir -p "$UB_TMPDIR"
	cp -f pgms/multi.sh pgms/tst.sh "$UB_BINDIR"/ 2>/dev/null
	echo "UB-START copies=$COPIES $(uname -a)"
	for t in $TESTS; do
		params $t
		p=1
		while [ $p -le $N ]; do
			sync; sleep 1; sync; sleep 2
			( cd "$UB_TESTDIR" || exit 1
			  c=1
			  while [ $c -le $COPIES ]; do
				( /usr/bin/time -p $CMD > "$UB_TMPDIR/o.$c" 2> "$UB_TMPDIR/e.$c" ) &
				c=$((c + 1))
			  done
			  wait )
			c=1
			while [ $c -le $COPIES ]; do
				el=$(awk '$1 == "real" { print $2 }' "$UB_TMPDIR/e.$c")
				cnt=$(cat "$UB_TMPDIR/o.$c" "$UB_TMPDIR/e.$c" | grep '^COUNT|' | tail -1)
				tm=$(cat "$UB_TMPDIR/o.$c" "$UB_TMPDIR/e.$c" | grep '^TIME|' | tail -1)
				echo "UB|$t|$p|$c|$el|$cnt${tm:+|$tm}"
				c=$((c + 1))
			done
			p=$((p + 1))
		done
	done
	echo "UB-DONE"
}

case $1 in
build) build ;;
run)   shift; run "$@" ;;
*)     echo "usage: $0 build | run [COPIES] [TESTS...]" >&2; exit 2 ;;
esac
