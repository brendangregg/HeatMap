#!/usr/bin/perl -w
#
# trace2heatmap.pl 	Generate a heat map SVG from a trace of event latency.
#
# This is a quick program to prototype heat maps.
#
# USAGE: ./trace2heatmap.pl [options] trace.txt > heatmap.svg
#
# The input trace.txt is two numerical columns, a time and a latency. eg:
#
#	$ more trace.txt
#	17442020318913 8026
#	17442020325950 6798
#	17442020333082 6907
#	17442020339374 6065
#	[...]
#
# If these columns were in microseconds, it could be processed using:
#
# ./trace2heatmap.pl --unitstime=us --unitslatency=us trace.txt > heatmap.svg
#
# --unitstime is necessary to set for the x-axis (columns). --unitstime is
# optional for the y-axis (labels).
#
# If your input file needs some massaging, you can pipe from grep/sed/awk:
#
#	awk '...' raw.txt | ./trace2heatmap.pl [options] > heatmap.svg
#
# Options are listed in the usage message (--help).
#
# The input may be other event types: eg, utilization, offset, I/O size.  The
# --title can be changed to reflect the type shown.
#
# HISTORY
#
# See "Visualizing System Latency", ACMQ 2010, for the origin of latency
# heat maps: http://queue.acm.org/detail.cfm?id=1809426"
#
# Copyright 2013 Brendan Gregg.  All rights reserved.
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at docs/cddl1.txt or
# http://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at docs/cddl1.txt.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
# BUGS: probably many. I wrote this in about 3 hours.
#
# 18-May-2013	Brendan Gregg	Created this.

use strict;

use Getopt::Long;

# tunables
my $fonttype = "Verdana";
my $boxsize = 8;		# height and width of boxes
my $fontsize = 12;		# base text size
my $titletext = "Latency Heat Map";     # centered heading
my $xaxistext = "Time";         # centered heading
my $rows = 50;			# number of latency rows
my $max_col;			# max column to draw
my $step_lat;			# instead of rows, use fixed latency step
my $step_sec = 1;		# seconds per column
my $min_lat = 0;		# min latency to include
my $max_lat;			# max latency to include
my $units_lat = "";		# latency units (eg, "us")
my $units_time;			# time units (eg, "us")
my $timefactor = 1;		# divisor for time column
my $limit_col = 10000;		# max permitted columns
my $debugmsg = 0;		# print debug messages
my $grid = 0;			# draw grid lines

GetOptions(
    'fonttype=s'     => \$fonttype,
    'fontsize=i'     => \$fontsize,
    'boxsize=i'      => \$boxsize,
    'minlat=i'       => \$min_lat,
    'maxlat=i'       => \$max_lat,
    'steplat=i'      => \$step_lat,
    'stepsec=f'      => \$step_sec,
    'rows=i'         => \$rows,
    'maxcol=i'       => \$max_col,
    'title=s'        => \$titletext,
    'unitslatency=s' => \$units_lat,
    'unitstime=s'    => \$units_time,
    'grid'           => \$grid
) or die <<USAGE_END;
USAGE: $0 [options] infile > outfile.svg\n
	--titletext		# change title text
	--unitstime		# column 1 units: "s" (default), "ms", "us",
				  or "ns".
	--unitslatency		# column 2 units (any string; used for labels)
	--minlat		# minimum latency to include
	--maxlat		# maximum latency to include
	--rows			# number of heat map rows (default 50)
	--steplat		# instead of --rows, you can specify a latency
				  step, from which row count is automatic.
	--stepsec		# seconds per column (fractions ok)
	--maxcol		# maximum number of columns to draw (truncate)
	--fonttype		# font type (default "Verdana")
	--fontsize		# font size (default 12)
	--boxsize		# heat map box size in pixels (default 8)
	--grid			# draw grid lines
    eg,
	$0 --unitstime=us --unitslatency=us --minlat=2000 --maxlat=10000 \\
	    trace.txt > heatmap.svg
USAGE_END

# internals
my $ypad1 = $fontsize * 3;	# pad top, include title
my $ypad2 = $fontsize * 4.5;	# pad bottom, include labels
$ypad2 += $fontsize * 1.2 if $grid;
my $xpad = 10;			# pad left and right
if (defined $units_time) {
	if ($units_time eq "s") { $timefactor = 1; }
	elsif ($units_time eq "ms") { $timefactor = 1000; }
	elsif ($units_time eq "us") { $timefactor = 1000000; }
	elsif ($units_time eq "ns") { $timefactor = 1000000000; }
	else { die "Can't parse time units \"$units_time\". Try \"ms\" etc." }
}

# SVG functions
{ package SVG;
	sub new {
		my $class = shift;
		my $self = {};
		bless ($self, $class);
		return $self;
	}

	sub header {
		my ($self, $w, $h) = @_;
		$self->{svg} .= <<SVG;
<?xml version="1.0" standalone="no"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" width="$w" height="$h" onload="init(evt)" viewBox="0 0 $w $h" xmlns="http://www.w3.org/2000/svg" >
SVG
	}

	sub include {
		my ($self, $content) = @_;
		$self->{svg} .= $content;
	}

	sub colorAllocate {
		my ($self, $r, $g, $b) = @_;
		return "rgb($r,$g,$b)";
	}

	sub filledRectangle {
		my ($self, $x1, $y1, $x2, $y2, $fill, $extra) = @_;
		$x1 = sprintf "%0.1f", $x1;
		$x2 = sprintf "%0.1f", $x2;
		my $w = sprintf "%0.1f", $x2 - $x1;
		my $h = sprintf "%0.1f", $y2 - $y1;
		$extra = defined $extra ? $extra : "";
		$self->{svg} .= qq/<rect x="$x1" y="$y1" width="$w" height="$h" fill="$fill" $extra \/>\n/;
	}

	sub line {
		my ($self, $x1, $y1, $x2, $y2, $line) = @_;
		$self->{svg} .= qq/<line x1="$x1" y1="$y1" x2="$x2" y2="$y2" stroke="$line" stroke-width="1" \/>\n/;
	}

	sub stringTTF {
		my ($self, $color, $font, $size, $angle, $x, $y, $str, $loc, $extra) = @_;
		$loc = defined $loc ? $loc : "left";
		$extra = defined $extra ? $extra : "";
		$self->{svg} .= qq/<text text-anchor="$loc" x="$x" y="$y" font-size="$size" font-family="$font" fill="$color" $extra >$str<\/text>\n/;
	}

	sub svg {
		my $self = shift;
		return "$self->{svg}</svg>\n";
	}
	1;
}

sub color {
	my $type = shift;
	my $ratio = shift;	# 0 = lowest, 1 = highest
	if (defined $type and $type eq "linear") {
		return "rgb(255,255,255)" if $ratio == 0;
		my $r = 255;
		my $g = 240 - (240 * ($ratio));
		my $b = 220 - (220 * ($ratio));
		return sprintf("rgb(%.0f,%.0f,%.0f)", $r, $g, $b);
	}
	return "rgb(0,0,0)";
}

sub debug {
	print STDERR @_ if $debugmsg;
}

# Parse input
my @lines = <>;
shift @lines if $lines[0] =~ m/[a-zA-Z]/;	# remove header
my ($start_time, $rest) = split ' ', $lines[0];
my $end_time = $start_time;
my $largest_latency = 0;
foreach my $line (@lines) {
	my ($time, $latency) = split ' ', $line;
	next if !defined $time or $time eq "";
	next if !defined $latency or $latency eq "";
	$end_time = $time if $time > $end_time;
	$largest_latency = $latency if $latency > $largest_latency;
}
debug "Input start/end times: $start_time/$end_time\n";
if ((($end_time - $start_time) / $timefactor) > $limit_col) {
	die "Too many columns (>$limit_col); try setting --unitstime ?";
}
$max_lat ||= $largest_latency;
$step_lat ||= int(($max_lat - $min_lat) / $rows);
die "Row resolution too high" if $step_lat == 0;

# Build map
my @map;
debug "Building map.\n";
my $largest_col = 0;
my $largest_count = 0;
foreach my $line (@lines) {
	my ($time, $latency) = split ' ', $line;
	next if !defined $time or $time eq "";
	next if !defined $latency or $latency eq "";
	next if $latency < $min_lat;
	next if defined $max_lat and $latency > $max_lat;
	my $col = int((($time - $start_time) / $timefactor) / $step_sec);
	next if defined $max_col and $col > $max_col;
	my $lat = int(($latency - $min_lat) / $step_lat);
	$map[$col][$lat]++;
	$largest_col = $col if $col > $largest_col;
	$largest_count = $map[$col][$lat] if $map[$col][$lat] > $largest_count;
}
my $imagewidth ||= $largest_col * $boxsize + $xpad * 2;
my $imageheight ||= int(($max_lat - $min_lat) / $step_lat) * $boxsize + $ypad1 + $ypad2;

# Draw canvas
debug "Creating image, height/width: $imageheight, $imagewidth\n";
my $im = SVG->new();
$im->header($imagewidth, $imageheight);
my $inc = <<INC;
<style type="text/css">
	.func_g:hover { stroke:black; stroke-width:0.5; }
</style>
<script type="text/ecmascript">
<![CDATA[
	var details;
	function init(evt) { details = document.getElementById("details").firstChild; }
	function s(s, l, c, acc, total) {
		var pct = Math.floor(c / total * 100);
		var apct = Math.floor(acc / total * 100);

		details.nodeValue = "time " + s + "s, range " + l + ", count: " + c + ", pct: " + pct + "%, acc: " + acc + ", acc pct: " + apct + "%";
	}
	function c() { details.nodeValue = ' '; }
]]>
</script>
INC
$im->include($inc);
my ($white, $black, $vvdgrey, $dgrey, $grey) = (
	$im->colorAllocate(255, 255, 255),
	$im->colorAllocate(0, 0, 0),
	$im->colorAllocate(60, 60, 60),
	$im->colorAllocate(190, 190, 190),
	$im->colorAllocate(230, 230, 230),
    );
$im->filledRectangle(0, 0, $imagewidth, $imageheight, $white);
$im->stringTTF($black, $fonttype, $fontsize + 5, 0.0, int($imagewidth / 2), $fontsize * 2, $titletext, "middle");
$im->stringTTF($black, $fonttype, $fontsize, 0.0, int($imagewidth / 2), $imageheight - $fontsize - 1, $xaxistext);
$im->stringTTF($black, $fonttype, $fontsize, 0.0, $xpad, $imageheight - (2.5 * $fontsize), " ", "", 'id="details"');

# Draw grid lines
my $largest_row = int(($max_lat - $min_lat) / $step_lat);
my ($ytop, $ybot);
if ($grid) {
	$ytop = $imageheight - ($ypad2 + $largest_row * $boxsize - $boxsize);
	$ybot = $imageheight - $ypad2 + $boxsize;
	$im->line($xpad, $ybot, $xpad + $largest_col * $boxsize, $ybot, $grey);
	$im->line($xpad, $ytop, $xpad + $largest_col * $boxsize, $ytop, $grey);
	for (my $s = 0; $s < $largest_col; $s += 10) {
		my $x = $xpad + $s * $boxsize;
		$im->line($x, $ybot, $x, $ytop, $grey);
		my $slabel = ($s * $step_sec) . "s";
		$im->stringTTF($dgrey, $fonttype, $fontsize, 0.0, $x, $ybot + $fontsize, $slabel);
	}
}

# Draw boxes
debug "Writing SVG.\n";
for (my $s = 0; $s < $largest_col; $s++) {
	my $acc = 0;
	my $total = 0;
	for (my $l = 0; $l < $largest_row; $l++) {
		my $c = $map[$s][$l];
		next unless defined $c;
		$total += $c;
	}
	for (my $l = 0; $l < $largest_row; $l++) {
		my $c = $map[$s][$l];
		$c = 0 unless defined $c;
		next if $c == 0;
		$acc += $c;
		my $color = color("linear", $c / $largest_count);
		my $x1 = $xpad + $s * $boxsize;
		my $x2 = $x1 + $boxsize;
		my $y1 = $imageheight - ($ypad2 + $l * $boxsize);
		my $y2 = $y1 + $boxsize;
		my $lr = ($min_lat + $l * $step_lat) . "-" .
		    ($min_lat + (($l + 1) * $step_lat)) . $units_lat;
		my $tr = $s * $step_sec;
		$tr .= "-" . ($s * $step_sec - 1 + $step_sec) if $step_sec > 1;
		$im->filledRectangle($x1, $y1, $x2, $y2, $color,
		    'onmouseover="s(' . "'$tr','$lr',$c,$acc,$total" . ')" onmouseout="c()"');
	}
}

if ($grid) {
	$im->stringTTF($vvdgrey, $fonttype, $fontsize, 0.0, $xpad + 5, $ybot - $fontsize + 4, $min_lat . $units_lat);
	$im->stringTTF($vvdgrey, $fonttype, $fontsize, 0.0, $xpad + 5, $ytop + $fontsize + 4, $max_lat . $units_lat);
}

print $im->svg;
