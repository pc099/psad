#!/usr/bin/perl -w

#============== config ===============
my $touchCmd = "/bin/touch";
my $mknodCmd = "/bin/mknod";
my $grepCmd = "/bin/grep";
my $cpCmd = "/bin/cp";
my $idCmd = "/usr/bin/id";
my $unameCmd = "/bin/uname";
my $ifconfigCmd = "/sbin/ifconfig";
my $ipchainsCmd = "/sbin/ipchains";
my $iptablesCmd = "/usr/local/bin/iptables";
#============ end config ============

my %Cmds = (
	"touch"		=> $touchCmd,
	"mknod"         => $mknodCmd,
	"grep"		=> $grepCmd,
	"cp"		=> $cpCmd,
	"id"		=> $idCmd,
	"uname"		=> $unameCmd,
	"ifconfig"	=> $ifconfigCmd,
	"ipchains"      => $ipchainsCmd,
	"iptables"	=> $iptablesCmd
);

%Cmds = check_commands(\%Cmds);

my $uid = (split /\s+/, `$Cmds{'id'}`)[0];
($uid) = ($uid =~ /^uid\=(\d+)/);
die "You need to be root (or equivalent UID 0 account) to install psad!\n" if $uid;
unless (-e "/var/log/psadfifo") {
	print "*** Creating named pipe /var/log/psadfifo\n";
	# create the named pipe
	`$Cmds{'mknod'} -m 600 /var/log/psadfifo p`;	# die does not seem to work right here.
}
unless (`$Cmds{'grep'} psadfifo /etc/syslog.conf`) {
	print "*** Modifying /etc/syslog.conf\n";
	open SYSLOG, ">> /etc/syslog.conf";
	print SYSLOG "kern.info  |/var/log/psadfifo\n\n";  #reinstate kernel logging to our named pipe
	close SYSLOG;
	print "*** Restarting syslog\n";
	system("/etc/rc.d/init.d/syslog restart");      # restart syslog
}
unless (-e "/var/log/psad") {
	print "*** Creating /var/log/psad/\n";
	mkdir "/var/log/psad",400;
}
unless (-e "/var/log/psad/fwdata") {
	print "*** Creating /var/log/psad/fwdata file\n";
	`$Cmds{'touch'} /var/log/psad/fwdata`;
	chmod 0600, "/var/log/psad/fwdata";
}
unless (-e "/etc/psad") {
	print "*** Creating /etc/psad/\n";
	mkdir "/etc/psad",400;
}
print "*** Copying psad,kmsgsd,diskmond -> /usr/local/bin/\n";
`$Cmds{'cp'} psad /usr/local/bin/psad`;
chmod 0500, "/usr/local/bin/psad";
`$Cmds{'cp'} kmsgsd /usr/local/bin/kmsgsd`;
chmod 0500, "/usr/local/bin/kmsgsd";
`$Cmds{'cp'} diskmond /usr/local/bin/diskmond`;
chmod 0500, "/usr/local/bin/diskmond";
print "*** Copying psad-init -> /etc/rc.d/init.d/psad-init\n";
`$Cmds{'cp'} psad-init /etc/rc.d/init.d/psad-init`;
print "*** Copying psad.conf,psad_signatures -> /etc/psad/\n";
`$Cmds{'cp'} psad.conf /etc/psad/psad.conf`;
chmod 0600, "/etc/psad/psad.conf";
`$Cmds{'cp'} psad_signatures /etc/psad/psad_signatures`;
chmod 0600, "/etc/psad/psad_signatures";

if(check_firewall_rules(\%Cmds)) {
	print "*** To execute psad, run \"/etc/rc.d/init.d/psad-init start\"\n";
} else {
	print "*** After setting up your firewall per the above note, execute \"/etc/rc.d/init.d/psad-init start\" to start psad\n";
}
exit 0;
#==================== end mail =====================
sub check_firewall_rules() {
	my $Cmds_href = shift;
	my @localips;
	my $kernel = (split /\s/, `$Cmds_href->{'uname'} -a`)[2];
        my $iptables = 1 if ($kernel =~ /^2.3/ || $kernel =~ /^2.4/);
        my $ipchains = 1 if ($kernel =~ /^2.2/); # and also 2.0.x ?
	my @localips_tmp = `$Cmds_href->{'ifconfig'} -a |$Cmds_href->{'grep'} inet`;
 	push @localips, (split /:/, (split /\s+/, $_)[2])[1] foreach (@localips_tmp);
	if ($iptables) {
# target     prot opt source               destination
# LOG        tcp  --  anywhere             anywhere           tcp flags:SYN,RST,ACK/SYN LOG level warning prefix `DENY '
# DROP       tcp  --  anywhere             anywhere           tcp flags:SYN,RST,ACK/SYN

# ACCEPT     tcp  --  0.0.0.0/0            64.44.21.15        tcp dpt:80 flags:0x0216/0x022
# LOG        tcp  --  0.0.0.0/0            0.0.0.0/0          tcp flags:0x0216/0x022 LOG flags 0 level 4 prefix `DENY '
# DROP       tcp  --  0.0.0.0/0            0.0.0.0/0          tcp flags:0x0216/0x022
		my @rules = `$Cmds_href->{'iptables'} -nL`;
		my $drop_rule = 0;
		FWPARSE: foreach my $rule (@rules) {
			next FWPARSE if ($rule =~ /^Chain/ || $rule =~ /^target/);
			if ($rule =~ /^(LOG)\s+(\w+)\s+\S+\s+\S+\s+(\S+)\s.+prefix\s\`(.+)\'/) {
				($target, $proto, $dst, $prefix) = ($1, $2, $3, $4);
				if ($target eq "LOG" && $proto =~ /all|tcp/ && $prefix =~ /drop|reject|deny/i) { # only tcp supported right now...
				# this needs work... see above _two_ rules.
					if (check_destination($dst, \@localips)) {
						print STDOUT "*** Your firewall setup looks good.  Unauthorized tcp packets will be logged.\n";
						return 1;
					}
				}
			}
		}
		print STDOUT "*** Your firewall does not include rules that will log dropped/rejected packets.  Psad will not work with such a firewall setup.\n";
		return 0;
	} elsif ($ipchains) {
# target     prot opt     source                destination           ports
# DENY       tcp  ----l-  anywhere             anywhere              any ->   telnet

#Chain input (policy ACCEPT):
#target     prot opt     source                destination           ports
#ACCEPT     tcp  ------  0.0.0.0/0            0.0.0.0/0             * ->   22
#DENY       tcp  ----l-  0.0.0.0/0            0.0.0.0/0             * ->   *
		my @rules = `$Cmds_href->{'ipchains'} -nL`;
		FWPARSE: foreach my $rule (@rules) {
			chomp $rule;
                        next FWPARSE if ($rule =~ /^Chain/ || $rule =~ /^target/);
			if ($rule =~ /^(\w+)\s+(\w+)\s+(\S+)\s+\S+\s+(\S+)\s+(\*)\s+\-\>\s+(\*)/) {
				my ($target, $proto, $opt, $dst, $srcpt, $dstpt) = ($1, $2, $3, $4, $5, $6);
                        	if ($target =~ /drop|reject|deny/i && $proto =~ /all|tcp/ && $opt =~ /....l./) {
					if (check_destination($dst, \@localips)) {
						print STDOUT "*** Your firewall setup looks good.  Unauthorized tcp packets will be dropped and logged.\n"; 
                                		return 1;
					}
				}
                        }
                }
		print STDOUT "*** Your firewall does not include rules that will log dropped/rejected packets.  Psad will not work with such a firewall setup.\n";
                return 0;
	} else {
		die "*** The linux kernel version you are currently running (v $kernel) does not seem to support ipchains or iptables.  psad will not run!\n";
	}
} 
sub check_destination() {
	my ($dst, $localips_aref) = @_;
	return 1 if ($dst =~ /0\.0\.0\.0\/0/);
	foreach my $ip (@$localips_aref) {
		my ($oct) = ($ip =~ /^(\d{1,3}\.\d{1,3})/);
		return 1 if ($dst =~ /^$oct/);
	}
	return 0;
}
sub check_commands() {
	my $Cmds_href = shift;
	CMD: foreach my $cmd (keys %$Cmds_href) {
		unless (-e $Cmds_href->{$cmd}) {
			$real_location = `which $cmd 2> /dev/null`;
			chomp $real_location;
			if ($real_location) {
				print "*** $cmd is not located at $Cmds_href->{$cmd}.  Using $real_location\n";
				$Cmds_href->{$cmd} = $real_location;
			} else {
				if ($cmd ne "ipchains" && $cmd ne "iptables") {
					die "Could not find $cmd anywhere!!!  Please edit the config section to include the path to $cmd.\n";
				} elsif (defined $Cmds_href->{'uname'}) {
        				my $kernel = (split /\s+/, `$Cmds_href->{'uname'} -a`)[2];
        				if ($kernel =~ /^2.3/ || $kernel =~ /^2.4/) {
						if ($cmd eq "ipchains") {
							next CMD;
						} else {
							die "*** You appear to be running kernel $kernel so you should be running iptables but iptables is not\nlocated at $Cmds_href->{'iptables'}.  Please edit the config section to include the path to iptables.\n";	
						}
					}      
  					if ($kernel =~ /^2.2/) { # and also 2.0.x ?
						if ($cmd eq "iptables") {
							next CMD;
						} else {
							die "*** You appear to be running kernel $kernel so you should be running ipchains but ipchains is not\nlocated at $Cmds_href->{'ipchains'}.  Please edit the config section to include the path to ipchains.\n";
						}
					}
				}
			}
		}
	}
	return %$Cmds_href;
}
