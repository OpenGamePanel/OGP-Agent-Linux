use strict;
use warnings;
use lib ".";
use FastDownload::Settings; # Daemon Settings
use Cwd;					# Fast way to get the current directory
use Fcntl ':flock';			# Import LOCK_* constants for file locking
use File::Copy;				# Simple file copy functions
use Path::Class::File;		# Handle files and directories.
use HTTP::Daemon;			# Create the Fast Download Daemon.
use URI::Escape;			# Translate url code for example: %20 to space
use Socket qw( inet_aton );	# Work with network addresses.

use constant RUN_DIR => getcwd();
use constant FD_DIR => Path::Class::Dir->new(RUN_DIR, 'FastDownload');
use constant FD_ALIASES_DIR => Path::Class::Dir->new(FD_DIR, 'aliases');
use constant FD_PID_FILE => Path::Class::File->new(FD_DIR, 'fd.pid');
use constant FD_LOG_FILE => Path::Class::File->new(FD_DIR, 'fastdownload.log');

### Logger function.
### @param line the line that is put to the log file.
sub logger
{
	my $logcmd	 = $_[0];
	my $also_print = 0;

	if (@_ == 2)
	{
		($also_print) = $_[1];
	}

	$logcmd = localtime() . " $logcmd\n";

	if ($also_print == 1)
	{
		print "$logcmd";
	}

	open(LOGFILE, '>>', FD_LOG_FILE)
	  or die("Can't open " . FD_LOG_FILE . " - $!");
	flock(LOGFILE, LOCK_EX) or die("Failed to lock log file.");
	seek(LOGFILE, 0, 2) or die("Failed to seek to end of file.");
	print LOGFILE "$logcmd" or die("Failed to write to log file.");
	flock(LOGFILE, LOCK_UN) or die("Failed to unlock log file.");
	close(LOGFILE) or die("Failed to close log file.");
}

# Rotate the log file
if (-e FD_LOG_FILE)
{
	if (-e FD_LOG_FILE . ".bak")
	{
		unlink(FD_LOG_FILE . ".bak");
	}
	logger "Rotating log file";
	move(FD_LOG_FILE, FD_LOG_FILE . ".bak");
	logger "New log file created";
}

if (open(PIDFILE, '>', FD_PID_FILE))
{
	print PIDFILE $$;
	close(PIDFILE);
}

$SIG{'PIPE'} = 'IGNORE';

my $fd = HTTP::Daemon->new(LocalAddr=>$FastDownload::Settings{ip},
						   LocalPort=>$FastDownload::Settings{port},
						   ReuseAddr=>'1') || die;

logger "Fast Download Daemon Started at: <URL:" . $fd->url . "> - PID $$",1;

my %aliases;
if(-d FD_ALIASES_DIR)
{
	if( !opendir(ALIASES, FD_ALIASES_DIR) )
	{
		logger "Error openning aliases directory " . FD_ALIASES_DIR . ", $!";
	}
	else
	{
		while (my $alias = readdir(ALIASES))
		{
			# Skip . and ..
			next if $alias =~ /^\./;
			if( !open(ALIAS, '<', Path::Class::Dir->new(FD_ALIASES_DIR, $alias)) )
			{
				logger "Error reading alias '$alias', $!";
			}
			else
			{
				my @file_lines = ();
				my $i = 0;
				while (<ALIAS>)
				{
					chomp $_;
					$file_lines[$i] = $_;
					$i++;
				}
				close(ALIAS);
				$aliases{$alias}{home}                  = $file_lines[0];
				$aliases{$alias}{match_file_extension}  = $file_lines[1];
				$aliases{$alias}{match_client_ip}       = $file_lines[2];
			}
		}
		closedir(ALIASES);
	}
}
else
{
	logger "Aliases directory '" . FD_ALIASES_DIR . "' does not exist or is inaccessible.";
}

$SIG{CHLD} = 'IGNORE';
while (my $c = $fd->accept) {
	my $pid = fork();
	if (not defined $pid)
	{
		logger "Could not allocate resources for Fast Download Client.",1;
	}
	# Only the forked child goes here.
	elsif ($pid == 0)
	{
		if(%aliases)
		{
			while(my $r = $c->get_request) {
				process_client_request($FastDownload::Settings{listing}, $r, $c);
				$c->close;
			}
		}
		else
		{
			while(my $r = $c->get_request) {
				$c->send_error(403,"");
				$c->close;
			}
		}
		undef($c);
		# Child process must exit.
		exit(0);
	}
}

sub process_client_request
{
	my($listing, $r, $c) = @_;
	my @uri_alias = split /\//, $r->uri->path;
	if(defined $uri_alias[1])
	{
		my $alias = $uri_alias[1];
		if ($r->method eq 'GET' and defined $aliases{$alias})
		{
			my $home = $aliases{$alias}{home};
			my (@extensions,@subnets);
			if(defined $aliases{$alias}{match_file_extension})
			{
				@extensions = split /,/, $aliases{$alias}{match_file_extension};
			}
			if(defined $aliases{$alias}{match_client_ip})
			{
				@subnets = split /,/, $aliases{$alias}{match_client_ip};
			}
			my $client = getpeername($c);
			my ($port, $iaddr) = unpack_sockaddr_in($client);
			my $client_ip = inet_ntoa($iaddr);
			my $uri = uri_unescape($r->uri->path);
			my $escaped_alias = "\/" . $alias;
			$uri =~ s/^$escaped_alias//g;
			my $location = $home . $uri;
			my $is_subnet;
			if(!grep {defined($_)} @subnets)
			{
				$is_subnet = 1;
			}
			else
			{
				foreach my $subnet (@subnets)
				{
					$is_subnet = in_subnet($client_ip, $subnet);
					if($is_subnet)
					{
						last;
					}
				}
			}
			if($is_subnet)
			{
				if(-d $location)
				{
					my $index = $location . "/" . "index.html";
					if(-f $index)
					{
						$c->send_file_response($index);
					}
					else
					{
						if($listing == 1)
						{
							# Loop through all files and folders
							my @dirs = ();
							my @bins = ();
							my @files = ();
							opendir(DIR, $location);
							while (my $entry = readdir(DIR))
							{
								# Skip . and ..
								next if $entry =~ /^\./;
								my $link_location = $location."/".$entry;
								if(-d $link_location)
								{
									push(@dirs, $entry);
								}
								elsif(-B $link_location)
								{
									push(@bins, $entry);
								}
								else
								{
									push(@files, $entry);
								}
							}
							closedir(DIR);
							@dirs = sort @dirs;
							@bins = sort @bins;
							@files = sort @files;
							my ($content, $href);
							foreach my $dir (@dirs)
							{
								$href = Path::Class::Dir->new($r->uri->path, $dir);
								$content .= "<a href='" . $href . "' >".$dir."</a><br>";
							}
							foreach my $bin (@bins)
							{
								$href = Path::Class::File->new($r->uri->path, $bin);
								$content .= "<a href='" . $href . "' >".$bin."</a><br>";
							}
							foreach my $file (@files)
							{
								$href = Path::Class::File->new($r->uri->path, $file);
								$content .= "<a href='" . $href . "' >".$file."</a><br>";
							}
							my $response = HTTP::Response->new(200);
							$response->content($content);
							$response->header("Content-Type" => "text/html");
							$c->send_response($response);
						}
						else
						{
							$c->send_error(403,"");
						}
					}
				}
				else
				{
					my @extension = split /\./, $uri;
					my $extension = $extension[-1];
					if(grep {$_ eq $extension} @extensions or !grep {defined($_)} @extensions)
					{
						$c->send_file_response($location);
					}
					else
					{
						$c->send_error(403,"");
					}
				}
			}
			else
			{
				$c->send_error(403,"");
			}
		}
		else
		{
			$c->send_error(403,"");
		}
	}
	else
	{
		$c->send_error(403,"");
	}
}

sub ip2long($)
{
	return( unpack( 'N', inet_aton(shift) ) );
}

sub in_subnet($$)
{
	my $ip = shift;
	my $subnet = shift;
	my $ip_long = ip2long( $ip );
	if( $subnet=~m|(^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$| )
	{
		my $subnet = ip2long($1);
		my $mask = ip2long($2);
		if( ($ip_long & $mask)==$subnet )
		{
			return 1;
		}
	}
	elsif( $subnet=~m|(^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$| )
	{
		my $subnet = ip2long($1);
		my $bits = $2;
		my $mask = -1<<(32-$bits);
		$subnet&= $mask;
		if( ($ip_long & $mask)==$subnet )
		{
			return 1;
		}
	}
	elsif( $subnet=~m|(^\d{1,3}\.\d{1,3}\.\d{1,3}\.)(\d{1,3})-(\d{1,3})$| )
	{
		my $start_ip = ip2long($1.$2);
		my $end_ip = ip2long($1.$3);
		if( $start_ip<=$ip_long and $end_ip>=$ip_long )
		{
			return 1;
		}
	}
	elsif( $subnet=~m|^[\d\*]{1,3}\.[\d\*]{1,3}\.[\d\*]{1,3}\.[\d\*]{1,3}$| )
	{
		my $search_string = $subnet;
		$search_string=~s/\./\\\./g;
		$search_string=~s/\*/\.\*/g;
		if( $ip=~/^$search_string$/ )
		{
				return 1;
		}
	}
	return 0;
}