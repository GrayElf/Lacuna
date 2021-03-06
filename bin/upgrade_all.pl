#!/usr/bin/perl
#
# Simple program for upgrading buildings

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client;
use Getopt::Long qw(GetOptions);
use JSON;
use Exception::Class;

  my %opts = (
        h => 0,
        v => 0,
        maxlevel => 30,
        config => "lacuna.yml",
        dumpfile => "log/all_builds.js",
        station => 0,
        wait    => 8 * 60 * 60,
  );

  GetOptions(\%opts,
    'h|help',
    'v|verbose',
    'planet=s@',
    'config=s',
    'dumpfile=s',
    'maxlevel=i',
    'wait=i',
    'space',
#    'match=s@',
    'match=s',
    'skip=s@',
    'type=s@',
  );

  usage() if $opts{h};
  
  my $glc = Games::Lacuna::Client->new(
    cfg_file => $opts{config} || "lacuna.yml",
    # debug    => 1,
  );

  my $json = JSON->new->utf8(1);
  $json = $json->pretty([1]);
  $json = $json->canonical([1]);
  open(OUTPUT, ">", $opts{dumpfile}) || die "Could not open $opts{dumpfile} for writing";

  my $status;
  my $empire = $glc->empire->get_status->{empire};
  print "Starting RPC: $glc->{rpc_count}\n";

# Get planets
  my %planets = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};
  $status->{planets} = \%planets;
  my $short_time = $opts{wait} + 1;

  my $keep_going = 1;
  do {
    my $pname;
    my @skip_planets;
    for $pname (sort keys %planets) {
      if ($opts{planet} and not (grep { $pname eq $_ } @{$opts{planet}})) {
        push @skip_planets, $pname;
        next;
      }
      print "Inspecting $pname\n";
      my $planet    = $glc->body(id => $planets{$pname});
      my $result    = $planet->get_buildings;
      my $buildings = $result->{buildings};
      my $station = $result->{status}{body}{type} eq 'space station' ? 1 : 0;
      if ($station) {
        push @skip_planets, $pname;
        next;
      }
      my ($sarr, $pending) = bstats($buildings, $station);
      my $seconds = $opts{wait} + 1;
      $seconds = $pending if ($pending > 0);
      for my $bld (@$sarr) {
        printf "%7d %10s l:%2d x:%2d y:%2d\n",
                 $bld->{id}, $bld->{name},
                 $bld->{level}, $bld->{x}, $bld->{y};
        my $ok;
        my $bldstat = "Bad";
        $ok = eval {
          my $type = get_type_from_url($bld->{url});
          my $bldpnt = $glc->building( id => $bld->{id}, type => $type);
          $bldstat = $bldpnt->upgrade();
          $seconds = $bldstat->{building}->{pending_build}->{seconds_remaining} - 15;
        };
        unless ($ok) {
          print "$@ Error; sleeping 60\n";
#          sleep 60;
        }
      }
      $status->{"$pname"} = $sarr;
      if ($seconds > $opts{wait}) {
        print "Queue of ", sec2str($seconds),
              " is longer than wait period of ",sec2str($opts{wait}), ", taking $pname off of list.\n";
        push @skip_planets, $pname;
      }
      elsif ($seconds < $short_time) {
        $short_time = $seconds;
      }
    }
    print "Done with: ",join(":", sort @skip_planets), "\n";
    for $pname (@skip_planets) {
      delete $planets{$pname};
    }
    if (keys %planets) {
      print "Clearing Queue for ",sec2str($short_time),".\n";
      sleep $short_time;
    }
    else {
      print "Nothing Else to do.\n";
      $keep_going = 0;
    }
  } while ($keep_going);

 print OUTPUT $json->pretty->canonical->encode($status);
 close(OUTPUT);
 print "Ending   RPC: $glc->{rpc_count}\n";

exit;

sub bstats {
  my ($bhash, $station) = @_;

  my $bcnt = 0;
  my $dlevel = $station ? 121 : 0;
  my @sarr;
  my $pending = 0;
  for my $bid (keys %$bhash) {
    next if ($bhash->{$bid}->{name} =~ /Platform/);
    if ($bhash->{$bid}->{name} eq "Development Ministry") {
      $dlevel = $bhash->{$bid}->{level};
    }
    if ( defined($bhash->{$bid}->{pending_build})) {
      $bcnt++;
      $pending = $bhash->{$bid}->{pending_build}->{seconds_remaining} if ($bhash->{$bid}->{pending_build}->{seconds_remaining} > $pending);
    }
    else {
      next if ($opts{match} and !($bhash->{$bid}->{name} =~ /$opts{match}/));
      if ($opts{space} or ( $bhash->{$bid}->{name} ne "Space Port" and !($bhash->{$bid}->{name} =~ /Space Station Lab|Lost City/ ) )) {
        print "Doing $bhash->{$bid}->{name}\n";
        my $ref = $bhash->{$bid};
        $ref->{id} = $bid;
        push @sarr, $ref if ($ref->{level} < $opts{maxlevel} && $ref->{efficiency} == 100);
      }
      else {
        print "Skip  $bhash->{$bid}->{name}\n";
      }
    }
  }
  @sarr = sort { $a->{level} <=> $b->{level} ||
                 $a->{x} <=> $b->{x} ||
                 $a->{y} <=> $b->{y} } @sarr;
  if (scalar @sarr > ($dlevel + 1 - $bcnt)) {
    splice @sarr, ($dlevel + 1 - $bcnt);
  }
  return (\@sarr, $pending);
}

sub sec2str {
  my ($sec) = @_;

  my $day = int($sec/(24 * 60 * 60));
  $sec -= $day * 24 * 60 * 60;
  my $hrs = int( $sec/(60*60));
  $sec -= $hrs * 60 * 60;
  my $min = int( $sec/60);
  $sec -= $min * 60;
  return sprintf "%04d:%02d:%02d:%02d", $day, $hrs, $min, $sec;
}

sub get_type_from_url {
  my ($url) = @_;

  my $type;
  eval {
    $type = Games::Lacuna::Client::Buildings::type_from_url($url);
  };
  if ($@) {
    print "Failed to get building type from URL '$url': $@";
    return 0;
  }
  return 0 if not defined $type;
  return $type;
}

sub usage {
    diag(<<END);
Usage: $0 [options]

This program upgrades planets on your planet. Faster than clicking each port.
It will upgrade in order of level up to maxlevel.

Options:
  --help             - This info.
  --verbose          - Print out more information
  --config <file>    - Specify a GLC config file, normally lacuna.yml.
  --planet <name>    - Specify planet
  --dumpfile         - data dump for all the info we don't print
  --maxlevel         - do not upgrade if this level has been achieved.
END
  exit 1;
}

sub verbose {
    return unless $opts{v};
    print @_;
}

sub output {
    return if $opts{q};
    print @_;
}

sub diag {
    my ($msg) = @_;
    print STDERR $msg;
}

sub normalize_planet {
    my ($planet_name) = @_;

    $planet_name =~ s/\W//g;
    $planet_name = lc($planet_name);
    return $planet_name;
}
