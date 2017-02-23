#!/usr/bin/perl -w
#
# offsets-perf	Turn Linux "perf script" output into times & time offsets,
#		for the generation of subsecond-offset heat maps.
#
# USAGE EXAMPLE:
#
# perf record -F 100 -a -- sleep 60
# perf script | ./offsets-perf.pl
#
# EXAMPLE OUTPUT:
#
# perf script | ./offsets-perf.pl
# 331669 730819
# 331669 730927
# 331669 730954
# 331669 730962
# 331669 730968
# 331669 740926
#
# The first column is the second of the event, and the second is the micro
# second. Use --ms to switch this second column to milliseconds.
#
# Options also exist to have time start at 0 (--timezero), or just the seconds
# column start at zero (--timezerosecs).
#
# This is intended for turning into a heatmap, eg:
#
# perf script | ./offsets-perf.pl --ms | ./trace2heatmap.pl --unitslabel=ms > heatmap.svg
#
# Copyright 2017 Netflix, Inc.
# Licensed under the Apache License, Version 2.0 (the "License")
#
# 23-Feb-2017	Brendan Gregg	Created this.

use strict;
use Getopt::Long;
use POSIX 'floor';

sub usage {
	die <<USAGE_END;
USAGE: $0 [options] < infile > outfile
	--timezero	# scale times to start at 0.0.
	--timezerosecs	# scale seconds only to start at 0.
USAGE_END
}

my $ms = 0;
my $timezero = 0;
my $timezerosecs = 0;
GetOptions(
	'timezero'      => \$timezero,
	'timezerosecs'  => \$timezerosecs,
	'ms'		=> \$ms,
) or usage();

#
# Parsing
#
# IP only examples:
# 
# java 52025 [026] 99161.926202: cycles: 
# java 14341 [016] 252732.474759: cycles:      7f36571947c0 nmethod::is_nmethod() const (/...
# java 14514 [022] 28191.353083: cpu-clock:      7f92b4fdb7d4 Ljava_util_List$size$0;::call (/tmp/perf-11936.map)
#      swapper     0 [002] 6035557.056977:   10101010 cpu-clock:  ffffffff810013aa xen_hypercall_sched_op+0xa (/lib/modules/4.9-virtual/build/vmlinux)
#         bash 25370 603are 6036.991603:   10101010 cpu-clock:            4b931e [unknown] (/bin/bash)
#         bash 25370/25370 6036036.799684: cpu-clock:            4b913b [unknown] (/bin/bash)
# other combinations are possible.
#
# Stack examples (-g):
#
# swapper     0 [021] 28648.467059: cpu-clock: 
#	ffffffff810013aa xen_hypercall_sched_op ([kernel.kallsyms])
#	ffffffff8101cb2f default_idle ([kernel.kallsyms])
#	ffffffff8101d406 arch_cpu_idle ([kernel.kallsyms])
#	ffffffff810bf475 cpu_startup_entry ([kernel.kallsyms])
#	ffffffff81010228 cpu_bringup_and_idle ([kernel.kallsyms])
#
# java 14375 [022] 28648.467079: cpu-clock: 
#	    7f92bdd98965 Ljava/io/OutputStream;::write (/tmp/perf-11936.map)
#	    7f8808cae7a8 [unknown] ([unknown])
#
# swapper     0 [005]  5076.836336: cpu-clock: 
#	ffffffff81051586 native_safe_halt ([kernel.kallsyms])
#	ffffffff8101db4f default_idle ([kernel.kallsyms])
#	ffffffff8101e466 arch_cpu_idle ([kernel.kallsyms])
#	ffffffff810c2b31 cpu_startup_entry ([kernel.kallsyms])
#	ffffffff810427cd start_secondary ([kernel.kallsyms])
#
# swapper     0 [002] 6034779.719110:   10101010 cpu-clock: 
#       2013aa xen_hypercall_sched_op+0xfe20000a (/lib/modules/4.9-virtual/build/vmlinux)
#       a72f0e default_idle+0xfe20001e (/lib/modules/4.9-virtual/build/vmlinux)
#       2392bf arch_cpu_idle+0xfe20000f (/lib/modules/4.9-virtual/build/vmlinux)
#       a73333 default_idle_call+0xfe200023 (/lib/modules/4.9-virtual/build/vmlinux)
#       2c91a4 cpu_startup_entry+0xfe2001c4 (/lib/modules/4.9-virtual/build/vmlinux)
#       22b64a cpu_bringup_and_idle+0xfe20002a (/lib/modules/4.9-virtual/build/vmlinux)
#
# bash 25370/25370 6035935.188539: cpu-clock: 
#                   b9218 [unknown] (/bin/bash)
#                 2037fe8 [unknown] ([unknown])
# other combinations are possible.
#
# This regexp matches the event line, and puts time in $1:
#
my $event_regexp = qr/ +([0-9\.]+): .+?:/;

#
# These match the process name and currently running function when a CPU is
# idle. When both are matched, we treat that sample as idle:
#
my $idle_process = "swapper";
my $idle_regexp = qr/(cpu_idle|cpu_bringup_and_idle|native_safe_halt|xen_hypercall_sched_op|xen_hypercall_vcpu_op)/;

my ($line, $next, $ts);
my @stack;
my $epoch = -1;

while (1) {
	undef $next;
	$line = <>;
haveline:
	last unless defined $line;
	next if $line =~ /^#/;		# skip comments

	if ($line =~ $event_regexp) {
		$ts = $1;

		$epoch = $ts if $epoch == -1;

		# attempt to pull in stack:
		@stack = ();
		while (1) {
			$next = <>;
			goto doexit unless defined $next;
			if ($next =~ $event_regexp) {
				# not a stack
				goto process;
			}
			push(@stack, $next);
		}

process:
		# skip idle:
		if (scalar @stack > 0) {
			goto done if ($line =~ $idle_process) and grep($idle_regexp, @stack);
		} else {
			goto done if $line =~ /$idle_process .* $idle_regexp/;
		}
	}

	if ($timezero) {
		$ts -= $epoch;
	} elsif ($timezerosecs) {
		$ts -= floor($epoch);
	}
	if ($ms) {
		$ts = sprintf("%.3f", $ts);
	} else {
		$ts = sprintf("%.6f", $ts);
	}
	$ts =~ tr/\./ /;
	print "$ts\n";
	
done:
	if (defined $next) {
		$line = $next;
		goto haveline;
	}
doexit:
}
