#!/usr/bin/perl
#
# OGP - Open Game Panel
# Copyright (C) 2008 - 2018 The OGP Development Team
#
# http://www.opengamepanel.org/
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

use warnings;
use strict;

use Cwd;			 # Fast way to get the current directory
use lib getcwd();
use Frontier::Daemon::OGP::Forking;	# Forking XML-RPC server
use File::Copy;				   # Simple file copy functions
use File::Copy::Recursive
  qw(fcopy rcopy dircopy fmove rmove dirmove pathempty pathrmdir)
  ;							   # Used to copy whole directories
use File::Basename; # Used to get the file name or the directory name from a given path
use Crypt::XXTEA;	# Encryption between webpages and agent.
use Cfg::Config;	 # Config file
use Cfg::Preferences;   # Preferences file
use Fcntl ':flock';  # Import LOCK_* constants for file locking
use LWP::UserAgent; # Used for fetching URLs
use MIME::Base64;	# Used to ensure data travelling right through the network.
use Getopt::Long;	# Used for command line params.
use Path::Class::File;	# Used to handle files and directories.
use File::Path qw(mkpath);
use Archive::Extract;	 # Used to handle archived files.
use File::Find;
use Schedule::Cron; # Used for scheduling tasks

# Compression tools
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error); # Used to compress files to bz2.
use Compress::Zlib; # Used to compress file download buffers to zlib.
use Archive::Tar; # Used to create tar, tgz or tbz archives.
use Archive::Zip qw( :ERROR_CODES :CONSTANTS ); # Used to create zip archives.

# Current location of the agent.
use constant AGENT_RUN_DIR => getcwd();

# Load our config file values
use constant AGENT_KEY	  => $Cfg::Config{key};
use constant AGENT_IP	   => $Cfg::Config{listen_ip};
use constant AGENT_LOG_FILE => $Cfg::Config{logfile};
use constant AGENT_PORT	 => $Cfg::Config{listen_port};
use constant AGENT_VERSION  => $Cfg::Config{version};
use constant WEB_ADMIN_API_KEY  => $Cfg::Config{web_admin_api_key};
use constant WEB_API_URL => $Cfg::Config{web_api_url};
use constant STEAM_DL_LIMIT => $Cfg::Config{steam_dl_limit};
use constant SCREEN_LOG_LOCAL  => $Cfg::Preferences{screen_log_local};
use constant DELETE_LOGS_AFTER  => $Cfg::Preferences{delete_logs_after};
use constant LINUX_USER_PER_GAME_SERVER  => $Cfg::Preferences{linux_user_per_game_server};
use constant AGENT_PID_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'ogp_agent.pid');
use constant AGENT_RSYNC_GENERIC_LOG =>
  Path::Class::File->new(AGENT_RUN_DIR, 'rsync_update_generic.log');
use constant STEAM_LICENSE_OK => "Accept";
use constant STEAM_LICENSE	=> $Cfg::Config{steam_license};
use constant MANUAL_TMP_DIR   => Path::Class::Dir->new(AGENT_RUN_DIR, 'tmp');
use constant SHARED_GAME_TMP_DIR   => Path::Class::Dir->new(AGENT_RUN_DIR, 'shared');
use constant STEAMCMD_CLIENT_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'steamcmd');
use constant STEAMCMD_CLIENT_BIN =>
  Path::Class::File->new(STEAMCMD_CLIENT_DIR, 'steamcmd.sh');
use constant SCREEN_LOGS_DIR =>
  Path::Class::Dir->new(AGENT_RUN_DIR, 'screenlogs');
use constant GAME_STARTUP_DIR =>
  Path::Class::Dir->new(AGENT_RUN_DIR, 'startups');
use constant SCREENRC_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'ogp_screenrc');
use constant SCREENRC_FILE_BK =>
  Path::Class::File->new(AGENT_RUN_DIR, 'ogp_screenrc_bk');
use constant SCREENRC_TMP_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'ogp_screenrc.tmp');
use constant SCREEN_TYPE_HOME   => "HOME";
use constant SCREEN_TYPE_UPDATE => "UPDATE";
use constant SERVER_RUNNER_USER => "ogp_server_runner";
use constant FD_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'FastDownload');
use constant FD_ALIASES_DIR => Path::Class::Dir->new(FD_DIR, 'aliases');
use constant FD_PID_FILE => Path::Class::File->new(FD_DIR, 'fd.pid');
use constant SCHED_PID => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.pid');
use constant SCHED_TASKS => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.tasks');
use constant SCHED_LOG_FILE => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.log');

$Cfg::Config{sudo_password} =~ s/('+)/'\"$1\"'/g;
our $SUDOPASSWD = $Cfg::Config{sudo_password};
my $no_startups	= 0;
my $clear_startups = 0;
our $log_std_out = 0;

GetOptions(
		   'no-startups'	=> \$no_startups,
		   'clear-startups' => \$clear_startups,
		   'log-stdout'	 => \$log_std_out
		  );

# Starting the agent as root user is not supported anymore.
if ($< == 0)
{
	print "ERROR: You are trying to start the agent as root user.";
	print "This is not currently supported. If you wish to start the";
	print "you need to create a normal user account for it.";
	exit 1;
}

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

	if ($log_std_out == 1)
	{
		print "$logcmd";
		return;
	}
	if ($also_print == 1)
	{
		print "$logcmd";
	}

	open(LOGFILE, '>>', AGENT_LOG_FILE)
	  or die("Can't open " . AGENT_LOG_FILE . " - $!");
	flock(LOGFILE, LOCK_EX) or die("Failed to lock log file.");
	seek(LOGFILE, 0, 2) or die("Failed to seek to end of file.");
	print LOGFILE "$logcmd" or die("Failed to write to log file.");
	flock(LOGFILE, LOCK_UN) or die("Failed to unlock log file.");
	close(LOGFILE) or die("Failed to close log file.");
}

# Rotate the log file
if (-e AGENT_LOG_FILE)
{
	if (-e AGENT_LOG_FILE . ".bak")
	{
		unlink(AGENT_LOG_FILE . ".bak");
	}
	logger "Rotating log file";
	move(AGENT_LOG_FILE, AGENT_LOG_FILE . ".bak");
	logger "New log file created";
}

# If for some reason the screenrc file doesn't exist, restore it from the backup copy
# I've seen this happen a few times
if (! -e SCREENRC_FILE)
{
	copy(SCREENRC_FILE_BK,SCREENRC_FILE);
}

open INPUTFILE, "<", SCREENRC_FILE or die $!;
open OUTPUTFILE, ">", SCREENRC_TMP_FILE or die $!;
my $dest = SCREEN_LOGS_DIR . "/screenlog.%t";
while (<INPUTFILE>) 
{
	$_ =~ s/logfile.*/logfile $dest/g;
	print OUTPUTFILE $_;
}
close INPUTFILE;
close OUTPUTFILE;
unlink SCREENRC_FILE;
move(SCREENRC_TMP_FILE,SCREENRC_FILE);

# Check the screen logs folder
if (!-d SCREEN_LOGS_DIR && !mkdir SCREEN_LOGS_DIR)
{
	logger "Could not create " . SCREEN_LOGS_DIR . " directory $!.", 1;
	exit -1;
}

if ( ! chmod 0777, SCREEN_LOGS_DIR ){
	logger "Could not chmod 777 " . SCREEN_LOGS_DIR . " directory $!.", 1;
	exit -1;
}

my $groupCommandScreenLogs = "chmod -Rf g-s '" . SCREEN_LOGS_DIR . "'";
sudo_exec_without_decrypt($groupCommandScreenLogs);

$groupCommandScreenLogs = "find '" . SCREEN_LOGS_DIR  . "' -type d | xargs chmod g+s";
sudo_exec_without_decrypt($groupCommandScreenLogs);

$groupCommandScreenLogs = "find '" . SCREEN_LOGS_DIR  . "' -type d | xargs setfacl -d -m u::rwX,g::rwX,o::-";
sudo_exec_without_decrypt($groupCommandScreenLogs);

# Check the global shared games folder
if (!-d SHARED_GAME_TMP_DIR && !mkdir SHARED_GAME_TMP_DIR)
{
	logger "Could not create " . SHARED_GAME_TMP_DIR . " directory $!.", 1;
	exit -1;
}

if (check_steam_cmd_client() == -1)
{
	print "ERROR: You must download and uncompress the new steamcmd package.";
	print "BE SURE TO INSTALL IT IN " . AGENT_RUN_DIR . "/steamcmd directory,";
	print "so it can be managed by the agent to install servers.";
	exit 1;
}

# create the directory for startup flags
if (!-e GAME_STARTUP_DIR)
{
	logger "Creating the startups directory " . GAME_STARTUP_DIR . "";
	if (!mkdir GAME_STARTUP_DIR)
	{
		my $message =
			"Failed to create the "
		  . GAME_STARTUP_DIR
		  . " directory - check permissions. Errno: $!";
		logger $message, 1;
		exit 1;
	}
}
elsif ($clear_startups)
{
	opendir(STARTUPDIR, GAME_STARTUP_DIR);
	while (my $startup_file = readdir(STARTUPDIR))
	{

		# Skip . and ..
		next if $startup_file =~ /^\./;
		$startup_file = Path::Class::File->new(GAME_STARTUP_DIR, $startup_file);
		logger "Removing " . $startup_file . ".";
		unlink($startup_file);
	}
	closedir(STARTUPDIR);
}
# If the directory already existed check if we need to start some games.
elsif ($no_startups != 1)
{

	# Loop through all the startup flags, and call universal startup
	opendir(STARTUPDIR, GAME_STARTUP_DIR);
	logger "Reading startup flags from " . GAME_STARTUP_DIR . "";
	while (my $dirlist = readdir(STARTUPDIR))
	{

		# Skip . and ..
		next if $dirlist =~ /^\./;
		logger "Found $dirlist";
		open(STARTFILE, '<', Path::Class::Dir->new(GAME_STARTUP_DIR, $dirlist))
		  || logger "Error opening start flag $!";
		while (<STARTFILE>)
		{
			my (
				$home_id,   $home_path,   $server_exe,
				$run_dir,   $startup_cmd, $server_port,
				$server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log
			   ) = split(',', $_);

			if (is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) ==
				1)
			{
				logger
				  "This server ($server_exe on $server_ip : $server_port) is already running (ID: $home_id).";
				next;
			}

			logger "Starting server_exe $server_exe from home $home_path.";
			universal_start_without_decrypt(
										 $home_id,   $home_path,   $server_exe,
										 $run_dir,   $startup_cmd, $server_port,
										 $server_ip, $cpu,	$nice, $preStart, $envVars, $game_key, $console_log
										   );
		}
		close(STARTFILE);
	}
	closedir(STARTUPDIR);
}

# Create the pid file
open(PID, '>', AGENT_PID_FILE)
  or die("Can't write to pid file - " . AGENT_PID_FILE . "\n");
print PID "$$\n";
close(PID);

logger "Open Game Panel - Agent started - "
  . AGENT_VERSION
  . " - port "
  . AGENT_PORT
  . " - PID $$", 1;

# Stop previous scheduler process if exists
scheduler_stop();	
# Create new object with default dispatcher for scheduled tasks
my $cron = new Schedule::Cron( \&scheduler_dispatcher, {
                                        nofork => 1,
                                        loglevel => 0,
                                        log => sub { print $_[1], "\n"; }
                                       } );

$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
# Run scheduler
$cron->run( {detach=>1, pid_file=>SCHED_PID} );

if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
{
	require "FastDownload/Settings.pm"; # Settings for Fast Download Daemon.
	if(defined($FastDownload::Settings{autostart_on_agent_startup}) && $FastDownload::Settings{autostart_on_agent_startup} eq "1")
	{
		start_fastdl();
	}
}

my $d = Frontier::Daemon::OGP::Forking->new(
			 methods => {
				 is_screen_running				=> \&is_screen_running,
				 universal_start			  	=> \&universal_start,
				 renice_process					=> \&renice_process,
				 cpu_count						=> \&cpu_count,
				 rfile_exists				 	=> \&rfile_exists,
				 quick_chk						=> \&quick_chk,
				 steam_cmd						=> \&steam_cmd,
				 fetch_steam_version			=> \&fetch_steam_version,
				 installed_steam_version		=> \&installed_steam_version,
				 automatic_steam_update			=> \&automatic_steam_update,
				 get_log					  	=> \&get_log,
				 stop_server				  	=> \&stop_server,
				 send_rcon_command				=> \&send_rcon_command,
				 dirlist						=> \&dirlist,
				 dirlistfm						=> \&dirlistfm,
				 readfile					 	=> \&readfile,
				 writefile						=> \&writefile,
				 rebootnow						=> \&rebootnow,
				 what_os					  	=> \&what_os,
				 start_file_download		  	=> \&start_file_download,
				 lock_additional_files          => \&lock_additional_files,
				 is_file_download_in_progress 	=> \&is_file_download_in_progress,
				 uncompress_file			  	=> \&uncompress_file,
				 discover_ips					=> \&discover_ips,
				 mon_stats						=> \&mon_stats,
				 exec						 	=> \&exec,
				 clone_home				   		=> \&clone_home,
				 remove_home					=> \&remove_home,
				 start_rsync_install			=> \&start_rsync_install,
				 rsync_progress			   		=> \&rsync_progress,
				 restart_server			   		=> \&restart_server,
				 sudo_exec						=> \&sudo_exec,
				 master_server_update			=> \&master_server_update,
				 secure_path					=> \&secure_path,
				 get_chattr						=> \&get_chattr,
				 ftp_mgr						=> \&ftp_mgr,
				 compress_files					=> \&compress_files,
				 stop_fastdl					=> \&stop_fastdl,
				 restart_fastdl					=> \&restart_fastdl,
				 fastdl_status					=> \&fastdl_status,
				 fastdl_get_aliases				=> \&fastdl_get_aliases,
				 fastdl_add_alias				=> \&fastdl_add_alias,
				 fastdl_del_alias				=> \&fastdl_del_alias,
				 fastdl_get_info				=> \&fastdl_get_info,
				 fastdl_create_config			=> \&fastdl_create_config,
				 agent_restart					=> \&agent_restart,
				 scheduler_add_task				=> \&scheduler_add_task,
				 scheduler_del_task				=> \&scheduler_del_task,
				 scheduler_list_tasks			=> \&scheduler_list_tasks,
				 scheduler_edit_task			=> \&scheduler_edit_task,
				 get_file_part					=> \&get_file_part,
				 stop_update					=> \&stop_update,
				 shell_action					=> \&shell_action,
				 remote_query					=> \&remote_query,
				 send_steam_guard_code  		=> \&send_steam_guard_code,
				 steam_workshop					=> \&steam_workshop,
				 get_workshop_mods_info			=> \&get_workshop_mods_info
			 },
			 debug	 => 4,
			 LocalPort => AGENT_PORT,
			 LocalAddr => AGENT_IP,
			 ReuseAddr => '1'
) or die "Couldn't start OGP Agent: $!";

sub backup_home_log
{
	my ($home_id, $log_file, $console_log_file) = @_;
	
	my $home_backup_dir = SCREEN_LOGS_DIR . "/home_id_" . $home_id;
		
	if( ! -e $home_backup_dir )
	{
		if( ! mkdir $home_backup_dir )
		{
			logger "Can not create a backup directory at $home_backup_dir.";
			return 1;
		}
	}
	
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	
	my $backup_file_name =  $mday . $mon . $year . '_' . $hour . 'h' . $min . 'm' . $sec . "s.log";
	
	my $output_path = $home_backup_dir . "/" . $backup_file_name;
	
	# Used for deleting log files older than DELETE_LOGS_AFTER
	my @file_list;
	my @find_dirs; # directories to search
	my $now = time(); # get current time
	my $days;
	if((DELETE_LOGS_AFTER =~ /^[+-]?\d+$/) && (DELETE_LOGS_AFTER > 0)){
		$days = DELETE_LOGS_AFTER; # how many days old
	}else{
		$days = 30; # how many days old
	}
	my $seconds_per_day = 60*60*24; # seconds in a day
	my $AGE = $days*$seconds_per_day; # age in seconds
	push (@find_dirs, $home_backup_dir);
	
	# Create local copy of log file backup in the log_backups folder and current user home directory if SCREEN_LOG_LOCAL = 1 
	if(SCREEN_LOG_LOCAL == 1)
	{
		# Create local backups folder
		my $local_log_folder = Path::Class::Dir->new("logs_backup");
		
		if(!-e $local_log_folder){
			mkdir($local_log_folder);
		}
		
		# Add full path to @find_dirs so that log files older than DELETE_LOGS_AFTER are deleted
		my $fullpath_to_local_logs = Path::Class::Dir->new(getcwd(), "logs_backup");
		push (@find_dirs, $fullpath_to_local_logs);
		
		my $log_local = $local_log_folder . "/" . $backup_file_name;
		
		# Delete the local log file if it already exists
		if(-e $log_local){
			unlink $log_local;
		}
		
		# If the log file contains UPDATE in the filename, do not allow users to see it since it will contain steam credentials
		# Will return -1 for not existing
		my $isUpdate = index($log_file,SCREEN_TYPE_UPDATE);
		
		if($isUpdate == -1){
			copy($log_file,$log_local);
		}
	}
	
	# Delete all files in @find_dirs older than DELETE_LOGS_AFTER days
	find ( sub {
		my $file = $File::Find::name;
		if ( -f $file ) {
			push (@file_list, $file);
		}
	}, @find_dirs);
	
	# Include the custom console path - and also do a size check on it
	if(defined $console_log_file && $console_log_file ne ""){
		my $path_to_console_file = $console_log_file;
		if( -f $path_to_console_file){
			push (@file_list, $path_to_console_file);
			
			# Backup and delete this specific file as well if it's over 20MB		
			my @stats = stat($path_to_console_file);
			if($stats[7] >= 20971520){
				if(SCREEN_LOG_LOCAL == 1){
					# Copy it to local log folder as well
					my $local_log_folder = Path::Class::Dir->new("logs_backup");
					my $log_local = $local_log_folder . "/" . $backup_file_name . "_console_log";
					copy($path_to_console_file, $log_local);
				}
				# Copy it to the main log folder as well
				move($path_to_console_file,$output_path . "_console_log");
			}
		}
	}
 
	for my $file (@file_list) {
		if( -f $file ){
			my @stats = stat($file);
			if ($now-$stats[9] > $AGE) {
				unlink $file;
			}
		}
	}
	
	move($log_file,$output_path);
	
	return 0;
}

sub get_home_pids
{
	my ($home_id) = @_;
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my ($pid, @pids);
	
	my $as_user = find_user_by_screen_id($screen_id);
	
	my $ret = sudo_exec_without_decrypt('screen -ls | grep -E -o "[0-9]+\.'.$screen_id.'"', $as_user);
	my ($retval, $enc_out) = split(/;/, $ret, 2);
	if($retval != 1)
	{
		logger "Unable to get pids, probably a bad sudo password or not in sudoers list.";
		return ();
	}
	
	$enc_out =~ s/\\n//g;
	
	my $out = decode_base64($enc_out);
	
	($pid) = split(/\./, $out, 2);
	if(defined $pid)
	{
		chomp($pid);
		while ($pid =~ /^[0-9]+$/)
		{
			push(@pids,$pid);
			$pid = `pgrep -P $pid`;
			chomp($pid);
		}
	}
	return @pids;
}

sub create_screen_id
{
	my ($screen_type, $home_id) = @_;
	return sprintf("OGP_%s_%09d", $screen_type, $home_id);
}

sub create_screen_cmd
{
	my ($screen_id, $exec_cmd) = @_;
	$exec_cmd = replace_OGP_Env_Vars($screen_id, "", "", $exec_cmd);
	return
	  sprintf('export WINEDEBUG="fixme-all" && export DISPLAY=:1 && screen -d -m -t "%1$s" -c ' . SCREENRC_FILE . ' -S %1$s %2$s',
			  $screen_id, $exec_cmd);

}

sub create_screen_cmd_loop
{
	my ($screen_id, $exec_cmd, $envVars, $skipLoop) = @_;
	my $server_start_bashfile = $screen_id . "_startup_scr.sh";
	
	$exec_cmd = replace_OGP_Env_Vars($screen_id, "", "", $exec_cmd);
	
	# Allow file to be overwritten
	if(-e $server_start_bashfile){
		secure_path_without_decrypt('chattr-i', $server_start_bashfile);
	}
	
	# Create bash file that screen will run which spawns the server
	# If it crashes without user intervention, it will restart
	open (SERV_START_SCRIPT, '>', $server_start_bashfile);
	
	my $respawn_server_command = "#!/bin/bash" . "\n";
	
	if(!$skipLoop){
		$respawn_server_command .= "function startServer(){" . "\n";
	}
	
	if(defined $envVars && $envVars ne ""){
		$respawn_server_command .= $envVars;
	}
	
	if(!$skipLoop){
		$respawn_server_command .= "NUMSECONDS=`expr \$(date +%s)`" . "\n"
		. "until " . $exec_cmd . "; do" . "\n" 
		. "let DIFF=(`date +%s` - \"\$NUMSECONDS\")" . "\n"
		. "if [ \"\$DIFF\" -gt 15 ]; then" . "\n" 
		. "NUMSECONDS=`expr \$(date +%s)`" . "\n"
		. "echo \"Server '" . $exec_cmd . "' crashed with exit code \$?.  Respawning...\" >&2 " . "\n" 
		. "fi" . "\n" 
		. "sleep 3" . "\n" 
		. "done" . "\n" 
		. "let DIFF=(`date +%s` - \"\$NUMSECONDS\")" . "\n"
		
		. "if [ ! -e \"SERVER_STOPPED\" ] && [ \"\$DIFF\" -gt 15 ]; then" . "\n"
		. "startServer" . "\n"
		. "fi" . "\n"
		. "}" . "\n"
		. "startServer" . "\n";
	}else{
		$respawn_server_command .= $exec_cmd . "\n";
	}
	
	print SERV_START_SCRIPT $respawn_server_command;
	close (SERV_START_SCRIPT);
	
	# Secure file
	secure_path_without_decrypt('chattr+i', $server_start_bashfile);
	
	my $screen_exec_script = "bash " . $server_start_bashfile;
	
	return
	  sprintf('export WINEDEBUG="fixme-all" && export DISPLAY=:1 && screen -d -m -t "%1$s" -c ' . SCREENRC_FILE . ' -S %1$s %2$s',
			  $screen_id, $screen_exec_script);

}

sub handle_lock_command_line{
	my ($command) = @_;
	if(defined $command && $command ne ""){
		if ($command =~ m/{OGP_LOCK_FILE}/) {
			$command =~ s/{OGP_LOCK_FILE}\s*//g;
			return secure_path_without_decrypt("chattr+i", $command);
		}
	}
	
	return 0;
}

sub replace_OGP_Env_Vars{
	# This function replaces constants from environment variables set in the XML
	my ($screen_id, $homeid, $homepath, $exec_cmd, $game_key) = @_;
	
	# Handle steam specific replacements
	if(defined $screen_id && $screen_id ne ""){
		my $screen_id_for_txt_update = substr ($screen_id, rindex($screen_id, '_') + 1);
		my $steamInsFile = $screen_id_for_txt_update . "_install.txt";
		my $steamCMDPath = STEAMCMD_CLIENT_DIR;
		my $fullPath = Path::Class::File->new($steamCMDPath, $steamInsFile);
		
		# If the install file exists, the game can be auto updated, else it will be ignored by the game for improper syntax
		# To generate the install file, the "Install/Update via Steam" button must be clicked on at least once!
		if(-e $fullPath){
			$exec_cmd =~ s/{OGP_STEAM_CMD_DIR}/$steamCMDPath/g;
			$exec_cmd =~ s/{STEAMCMD_INSTALL_FILE}/$steamInsFile/g;
		}
	}

	
	# Handle home directory replacement
	if(defined $homepath && $homepath ne ""){
		$exec_cmd =~ s/{OGP_HOME_DIR}/$homepath/g;
	}
	
	# Handle global game shared directory replacement
	if(defined $game_key && $game_key ne ""){
		my $readable_game_key = lc(substr($game_key, 0, rindex($game_key,"_")));		
		my $shared_path = Path::Class::Dir->new(SHARED_GAME_TMP_DIR, $readable_game_key);
		# Create the folder if it doesn't exist
		if (!-d $shared_path && !mkdir $shared_path)
		{
			logger "Could not create " . $shared_path . " directory $!.", 1;
		}
		$exec_cmd =~ s/{OGP_GAME_SHARED_DIR}/$shared_path/g;
	}
	
	return $exec_cmd;
}

sub encode_list
{
	my $encoded_content = '';
	if(@_)
	{
		foreach my $line (@_)
		{
			$encoded_content .= encode_base64($line, "") . '\n';
		}
	}
	return $encoded_content;
}

sub decrypt_param
{
	my ($param) = @_;
	$param = decode_base64($param);
	$param = Crypt::XXTEA::decrypt($param, AGENT_KEY);
	$param = decode_base64($param);
	return $param;
}

sub decrypt_params
{
	my @params;
	foreach my $param (@_)
	{
		$param = &decrypt_param($param);
		push(@params, $param);
	}
	return @params;
}

sub check_steam_cmd_client
{
	if (STEAM_LICENSE ne STEAM_LICENSE_OK)
	{
		logger "Steam license not accepted, stopping Steam client check.";
		return 0;
	}
	if (!-d STEAMCMD_CLIENT_DIR && !mkdir STEAMCMD_CLIENT_DIR)
	{
		logger "Could not create " . STEAMCMD_CLIENT_DIR . " directory $!.", 1;
		exit -1;
	}
	if (!-w STEAMCMD_CLIENT_DIR)
	{
		logger "Steam client dir '"
		  . STEAMCMD_CLIENT_DIR
		  . "' not writable. Unable to get Steam client.";
		return -1;
	}
	if (!-f STEAMCMD_CLIENT_BIN)
	{
		logger "The Steam client, steamcmd, does not exist yet, installing...";
		my $steam_client_file = 'steamcmd_linux.tar.gz';
		my $steam_client_path = Path::Class::File->new(STEAMCMD_CLIENT_DIR, $steam_client_file);
		my $steam_client_url =
		  "http://media.steampowered.com/client/" . $steam_client_file;
		logger "Downloading the Steam client from $steam_client_url to '"
		  . $steam_client_path . "'.";
		
		my $ua = LWP::UserAgent->new;
		$ua->agent('Mozilla/5.0');
		my $response = $ua->get($steam_client_url, ':content_file' => "$steam_client_path");
		
		unless ($response->is_success)
		{
			logger "Failed to download steam installer from "
			  . $steam_client_url
			  . ".", 1;
			return -1;
		}
		if (-f $steam_client_path)
		{
			logger "Uncompressing $steam_client_path";
			if ( uncompress_file_without_decrypt($steam_client_path, STEAMCMD_CLIENT_DIR) != 1 )
			{
				unlink($steam_client_path);
				logger "Unable to uncompress $steam_client_path, the file has been removed.";
				return -1;
			}
			unlink($steam_client_path);
		}
	}
	if (!-x STEAMCMD_CLIENT_BIN)
	{
		if ( ! chmod 0755, STEAMCMD_CLIENT_BIN )
		{
			logger "Unable to apply execution permission to ".STEAMCMD_CLIENT_BIN.".";
		}
	}
	return 1;
}

sub is_screen_running
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($screen_type, $home_id) = decrypt_params(@_);
	return is_screen_running_without_decrypt($screen_type, $home_id);
}

sub is_screen_running_without_decrypt
{
	my ($screen_type, $home_id) = @_;

	my $screen_id = create_screen_id($screen_type, $home_id);
	
	my $as_user = find_user_by_screen_id($screen_id);
		
	my $ret = sudo_exec_without_decrypt('screen -list | grep '.$screen_id, $as_user);
		
	my ($retval, $enc_out) = split(/;/, $ret, 2);
	
	if($retval != 1)
	{
		return 0;
	}
	
	my $is_running = " ";
	
	if( defined($enc_out) )
	{
		$enc_out =~ s/\\n//g;
		$is_running = decode_base64($enc_out);
	}
		
	if ($is_running =~ /^\s*$/)
	{
		return 0;
	}
	else
	{
		return 1;
	}
}

# Delete Server Stopped Status File:
sub deleteStoppedStatFile
{
	my ($home_path) = @_;
	my $server_stop_status_file = Path::Class::File->new($home_path, "SERVER_STOPPED");
	if(-e $server_stop_status_file)
	{
		unlink $server_stop_status_file;
	}
}

# Universal startup function
sub universal_start
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return universal_start_without_decrypt(decrypt_params(@_));
}

# Split to two parts because of internal calls.
sub universal_start_without_decrypt
{
	my (
		$home_id, $home_path, $server_exe, $run_dir,
		$startup_cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log
	   ) = @_;
	   
	if (is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1)
	{
		logger "This server is already running (ID: $home_id).";
		return -14;
	}
	
	secure_path_without_decrypt('chattr-i', $server_exe);
	
	if (!-e $home_path)
	{
		logger "Can't find server's install path [ $home_path ].";
		return -10;
	}
	
	my $owner = SERVER_RUNNER_USER;
	my $group = SERVER_RUNNER_USER;
	my $ogpAgentGroup = `whoami`;

	chomp $ogpAgentGroup;
	
	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$owner = "gamehome" . $home_id;
		$group = `whoami`;
		chomp $group;
		
		# Create new user if doesn't exist
		my $userExists = `id -u $owner`;
		if(not is_integer($userExists)){
			logger "User $owner currently doesn't exist... creating user...";
			 
			sudo_exec_without_decrypt("useradd -m $owner"); 
			sudo_exec_without_decrypt("usermod -s /bin/bash $owner"); 
			sudo_exec_without_decrypt("usermod -a -G \"$owner\" \"$group\""); 
		}
	}
	
	# Set ownership on the game home
	set_path_ownership($owner, $group, $home_path);
	
	# Fix perms on ogp_agent user's homedir so that other users can access their owned files within this dir
	my $fixOGPHomeDirCommand = 'chmod -R ug+rwx $( getent passwd "' . $ogpAgentGroup . '" | cut -d: -f6 )';
	sudo_exec_without_decrypt($fixOGPHomeDirCommand);

	$fixOGPHomeDirCommand = 'find "$( getent passwd "' . $ogpAgentGroup . '" | cut -d: -f6 )" -type d -print0 | xargs -0 chmod o+x';
	sudo_exec_without_decrypt($fixOGPHomeDirCommand);
	
	# Some game require that we are in the directory where the binary is.
	my $game_binary_dir = Path::Class::Dir->new($home_path, $run_dir);
	if ( -e $game_binary_dir && !chdir $game_binary_dir)
	{
		logger "Could not change to server binary directory $game_binary_dir.";
		return -12;
	}
	
	if (!-x $server_exe)
	{
		if (!chmod 0775, $server_exe)
		{
			logger "The $server_exe file is not executable.";
			return -13;
		}
	}
	
	if(defined $preStart && $preStart ne ""){
		# Get it in the format that the startup file can use
		$preStart = multiline_to_startup_comma_format($preStart);
	}else{
		$preStart = "";
	}
	
	if(defined $envVars && $envVars ne ""){
		# Replace variables in the envvars if they exist
		my @prestartenvvars = split /[\r\n]+/, $envVars;
		my $envVarStr = "";
		foreach my $line (@prestartenvvars) {
			$line = replace_OGP_Env_Vars("", $home_id, $home_path, $line, $game_key);
			if($line ne ""){
				logger "Configuring environment variable: $line";
				$envVarStr .= "$line\n";
			}
		}
			
		if(defined $envVarStr && $envVarStr ne ""){
			$envVars = $envVarStr;
		}	
		
		# Get it in the format that the startup file can use
		$envVars = multiline_to_startup_comma_format($envVars);
	}else{
		$envVars = "";
	}
	
	secure_path_without_decrypt('chattr+i', $server_exe);
	
	# Create startup file for the server.
	my $startup_file =
	  Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");
	if (open(STARTUP, '>', $startup_file))
	{
		print STARTUP
		  "$home_id,$home_path,$server_exe,$run_dir,$startup_cmd,$server_port,$server_ip,$cpu,$nice,$preStart,$envVars,$game_key,$console_log";
		logger "Created startup flag for $server_ip-$server_port";
		close(STARTUP);
	}
	else
	{
		logger "Cannot create file in " . $startup_file . " : $!";
	}
	
	if(defined $preStart && $preStart ne ""){
		# Get it in the format that the startup file can use
		$preStart = startup_comma_format_to_multiline($preStart);
	}else{
		$preStart = "";
	}
	
	if(defined $envVars && $envVars ne ""){
		# Get it in the format that the startup file can use
		$envVars = startup_comma_format_to_multiline($envVars);	
	}else{
		$envVars = "";
	}
	
	# Create the startup string.
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my $file_extension = substr $server_exe, -4;
	my $cli_bin;
	my $command;
	my $run_before_start;
	
	# Replace any OGP variables found in the command line
	$startup_cmd = replace_OGP_Env_Vars($screen_id, $home_id, $home_path, $startup_cmd, $game_key);
	
	if($file_extension eq ".exe" or $file_extension eq ".bat")
	{
		$command = "wine $server_exe $startup_cmd";
		
		if ($cpu ne 'NA')
		{
			$command = "taskset -c $cpu wine $server_exe $startup_cmd";
		}
		
		if(defined($Cfg::Preferences{ogp_autorestart_server}) &&  $Cfg::Preferences{ogp_autorestart_server} eq "1"){
			deleteStoppedStatFile($home_path);
			$cli_bin = create_screen_cmd_loop($screen_id, $command, $envVars);
		}else{
			$cli_bin = create_screen_cmd_loop($screen_id, $command, $envVars, 1);
		}
	}
	elsif($file_extension eq ".jar")
	{
		$command = "$startup_cmd";
		
		if ($cpu ne 'NA')
		{
			$command = "taskset -c $cpu $startup_cmd";
		}
		
		if(defined($Cfg::Preferences{ogp_autorestart_server}) &&  $Cfg::Preferences{ogp_autorestart_server} eq "1"){
			deleteStoppedStatFile($home_path);
			$cli_bin = create_screen_cmd_loop($screen_id, $command, $envVars);
		}else{
			$cli_bin = create_screen_cmd_loop($screen_id, $command, $envVars, 1);
		}
	}
	else
	{
		$command = "./$server_exe $startup_cmd";
		
		if ($cpu ne 'NA')
		{
			$command = "taskset -c $cpu ./$server_exe $startup_cmd";
		}
		
		if(defined($Cfg::Preferences{ogp_autorestart_server}) &&  $Cfg::Preferences{ogp_autorestart_server} eq "1"){
			deleteStoppedStatFile($home_path);
			$cli_bin = create_screen_cmd_loop($screen_id, $command, $envVars);
		}else{
			$cli_bin = create_screen_cmd_loop($screen_id, $command, $envVars, 1);
		}
	}
		
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log( $home_id, $log_file, $home_path . "/" . $console_log );
	
	logger
	  "Startup command [ $cli_bin ] will be executed in dir $game_binary_dir.";
	
	# Fix permissions one last time (for backup_home_log created folder / files / etc)
	set_path_ownership($owner, $group, $home_path);
	
	# Run before start script
	$run_before_start = run_before_start_commands($home_id, $home_path, $preStart, $owner);
	
	sudo_exec_without_decrypt($cli_bin, $owner);
	
	sleep(1);
	
	renice_process_without_decrypt($home_id, $nice);
		
	chdir AGENT_RUN_DIR;
	
	return 1;
}

# This is used to change the priority of process
# @return 1 if successfully set prosess priority
# @return -1 in case of an error.
sub renice_process
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return renice_process_without_decrypt(decrypt_params(@_));
}

sub renice_process_without_decrypt
{
	my ($home_id, $nice) = @_;	
	if ($nice != 0)
	{				
		my @pids = get_home_pids($home_id);
		logger
		  "Renicing pids [ @pids ] from home_id $home_id with nice value $nice.";
		foreach my $pid (@pids)
		{
			my $ret = sudo_exec_without_decrypt('/usr/bin/renice '.$nice.' '.$pid);
			($ret) = split(/;/, $ret, 2);
			if($ret != 1)
			{
				logger "Unable to renice process, probably bad sudo password or not in sudoers list.";
				return -1
			}
		}
	}
	return 1;
}

# This is used to force a process to run on a particular CPU
sub force_cpu
{
	return force_cpu_without_decrypt(decrypt_params(@_));
}

sub force_cpu_without_decrypt
{
	my ($home_id, $cpu) = @_;
	if ($cpu ne 'NA')
	{
		my @pids = get_home_pids($home_id);
		logger
		  "Setting server from home_id $home_id with pids @pids to run on CPU $cpu.";
		foreach my $pid (@pids)
		{
			my $rpid = kill 0, $pid;
			if ($rpid == 1)
			{
				my $ret = sudo_exec_without_decrypt('/usr/bin/taskset -pc '.$cpu.' '.$pid);
				($ret) = split(/;/, $ret, 2);
				if($ret != 1)
				{
					logger "Unable to set cpu, probably a bad sudo password or not in sudoers list.";
					return -1
				}
			}
		}
	}
	return 1;
}

# Returns the number of CPUs available.
sub cpu_count
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if (!-e "/proc/cpuinfo")
	{
		return "ERROR - Missing /proc/cpuinfo";
	}

	open(CPUINFO, '<', "/proc/cpuinfo")
	  or return "ERROR - Cannot open /proc/cpuinfo";

	my $cpu_count = 0;

	while (<CPUINFO>)
	{
		chomp;
		next if $_ !~ /^processor/;
		$cpu_count++;
	}
	close(CPUINFO);
	return "$cpu_count";
}

### File exists check ####
# Simple a way to check if a file exists using the remote agent
#
# @return 0 when file exists.
# @return 1 when file does not exist.
sub rfile_exists
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	my $checkFile = decrypt_param(@_);

	if (-e $checkFile)
	{
		return 0;
	}
	else
	{
		return 1;
	}
}

#### Quick check to verify agent is up and running
# Used to quickly see if the agent is online, and if the keys match.
# The message that is sent to the agent must be hello, if not then
# it is intrepret as encryption key missmatch.
#
# @return 1 when encrypted message is not 'hello'
# @return 0 when check is ok.
sub quick_chk
{
	my $dec_check = &decrypt_param(@_);
	if ($dec_check ne 'hello')
	{
		logger "ERROR - Encryption key mismatch! Returning 1 to asker.";
		return 1;
	}
	return 0;
}

### Return -10 If home path is not found.
### Return -9  If log type was invalid.
### Return -8  If log file was not found.
### 0 reserved for connection problems.
### Return 1;content If log found and screen running.
### Return 2;content If log found but screen is not running.
sub get_log
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($screen_type, $home_id, $home_path, $nb_of_lines, $log_file) = decrypt_params(@_);

	if (!chdir $home_path)
	{
		logger "Can't change to server's install path [ $home_path ].";
		return -10;
	}

	if (   ($screen_type eq SCREEN_TYPE_UPDATE)
		&& ($screen_type eq SCREEN_TYPE_HOME))
	{
		logger "Invalid screen type '$screen_type'.";
		return -9;
	}

	if(!$log_file)
	{
		my $screen_id = create_screen_id($screen_type, $home_id);
		$log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	}
	else
	{
		$log_file = Path::Class::File->new($home_path, $log_file);
	}
	
	sudo_exec_without_decrypt("chmod 777 \"$log_file\"");
	
	# Create local copy of current log file if SCREEN_LOG_LOCAL = 1
	if(SCREEN_LOG_LOCAL == 1)
	{
		my $log_local = Path::Class::File->new($home_path, "LOG_$screen_type.txt");
		if ( -e $log_local )
		{
			unlink $log_local;
		}
		
		# Copy log file only if it's not an UPDATE type as it may contain steam credentials
		if($screen_type eq SCREEN_TYPE_HOME){
			copy($log_file, $log_local);
		}
	}
	
	# Regenerate the log file if it doesn't exist
	unless ( -e $log_file )
	{
		if (open(NEWLOG, '>', $log_file))
		{
			logger "Log file missing, regenerating: " . $log_file;
			print NEWLOG "Log file missing, started new log\n";
			close(NEWLOG);
		}
		else
		{
			logger "Cannot regenerate log file in " . $log_file . " : $!";
			return -8;
		}
	}
	
	# Return a few lines of output to the web browser
	my(@modedlines) = `tail -n $nb_of_lines $log_file`;
	
	my $linecount = 0;
	
	foreach my $line (@modedlines) {
		#Remove unwanted characters (https://superuser.com/questions/99128/removing-the-escape-characters-from-gnu-screens-screenlog-n)
		$line =~ s/\x1b[[()=][;?0-9]*[0-9A-Za-z]?//g;
		$line =~ s/\r//g;
		$line =~ s/\007//g;
		#Text replacements to remove the Steam user login from steamcmd logs for security reasons.
		$line =~ s/login .*//g;
		$line =~ s/Logging .*//g;
		$line =~ s/set_steam_guard_code.*//g;
		$line =~ s/force_install_dir.*//g;
		#Text replacements to remove empty lines.
		$line =~ s/^ +//g;
		$line =~ s/^\t+//g;
		$line =~ s/^\e+//g;
		#Remove � from console output when master server update is running.
		$line =~ s/�//g;
		$modedlines[$linecount]=$line;
		$linecount++;
	} 
	
	my $encoded_content = encode_list(@modedlines);
	chdir AGENT_RUN_DIR;
	if(is_screen_running_without_decrypt($screen_type, $home_id) == 1)
	{
		return "1;" . $encoded_content;
	}
	else
	{
		return "2;" . $encoded_content;
	}
}

# stop server function
sub stop_server
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return stop_server_without_decrypt(decrypt_params(@_));
}

##### Stop server without decrypt
### Return 1 when error occurred on decryption.
### Return 0 on success
sub stop_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $home_path) = @_;
		
	my $usedProtocolToStop = 0;
		
	my $startup_file = Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");
	
	if (-e $startup_file)
	{
		logger "Removing startup flag " . $startup_file . "";
		unlink($startup_file)
		  or logger "Cannot remove the startup flag file $startup_file $!";
	}
	
	# Create file indicator that the game server has been stopped if defined
	if(defined($Cfg::Preferences{ogp_autorestart_server}) &&  $Cfg::Preferences{ogp_autorestart_server} eq "1"){
		
		# Get current directory and chdir into the game's home dir
		my $curDir = getcwd();
		chdir $home_path;

		# Create stopped indicator file used by autorestart of OGP if server crashes
		open(STOPFILE, '>', "SERVER_STOPPED");
		close(STOPFILE);
		
		# Return to original directory
		chdir $curDir;
	}
	
	# Some validation checks for the variables.
	if ($server_ip =~ /^\s*$/ || $server_port < 0 || $server_port > 65535)
	{
		logger("Invalid IP:Port given $server_ip:$server_port.");
		return 1;
	}
	
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my $as_user = find_user_by_screen_id($screen_id);

	if ($control_password !~ /^\s*$/ and $control_protocol ne "")
	{
		if ($control_protocol eq "rcon")
		{
			use KKrcon::KKrcon;
			my $rcon = new KKrcon(
								  Password => $control_password,
								  Host	 => $server_ip,
								  Port	 => $server_port,
								  Type	 => $control_type
								 );

			my $rconCommand = "quit";
			$rcon->execute($rconCommand);
			$usedProtocolToStop = 1;
		}
		elsif ($control_protocol eq "rcon2")
		{
			use KKrcon::HL2;
			my $rcon2 = new HL2(
								  hostname => $server_ip,
								  port	 => $server_port,
								  password => $control_password,
								  timeout  => 2
								 );

			my $rconCommand = "quit";
			$rcon2->run($rconCommand);
			$usedProtocolToStop = 1;
		}
		elsif ($control_protocol eq "armabe")
		{
			use ArmaBE::ArmaBE;
			my $armabe = new ArmaBE(
								  hostname => $server_ip,
								  port	 => $server_port, # Uses server port for now (Arma 2), Arma 3 BE uses a different, user definable port
								  password => $control_password,
								  timeout  => 2
								 );

			my $rconCommand = "#shutdown";
			my $armabe_result = $armabe->run($rconCommand);
			if ($armabe_result) {
				logger "ArmaBE Shutdown command sent successfully";		
				$usedProtocolToStop = 1;
			}
		}
		elsif ($control_protocol eq "minecraft")
		{
			use Minecraft::RCON;
			my $strip_color = 1;
			
			my $rconPort = get_minecraft_rcon_port($home_path);
			
			logger "Minecraft rcon port detected as $rconPort with path of $home_path";
			
			if ($rconPort != -1){
				my $minecraft;
				my $response;
				
				eval {
					$minecraft = Minecraft::RCON->new(
						{
							address     => $server_ip,
							port        => $rconPort,
							password    => $control_password,
							color_mode  => $strip_color ? 'strip' : 'convert',
						}
					);
				};
				
				if (defined $minecraft)
				{
					eval { $minecraft->connect };
					logger "Minecraft rcon module connection failed: $@" if $@;
					 
					
					my $rconCommand = "/stop";
					eval { $response = $minecraft->command($rconCommand) };
					logger $@ ? "Minecraft rcon error: $@" : "Minecraft rcon module response: $response";
	 
					eval { $minecraft->disconnect; };
					
					if (defined $response) {
						logger "Minecraft Shutdown command sent successfully";
						$usedProtocolToStop = 1;
					}
				}
			}
		}
		
		my @server_pids;
		
		# Gives the server time to shutdown with rcon in case it takes a while for the server to shutdown (arma for example) before we forcefully kill it
		if ($usedProtocolToStop == 1 && is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1){
			@server_pids = get_home_pids($home_id);
			my $timeWaited = 0;
			my $pidSize = @server_pids;
			my $maxWaitTime = 5;
			
			# Maximum time to wait can now be configured as a preference
			if(defined($Cfg::Preferences{protocol_shutdown_waittime}) && $Cfg::Preferences{protocol_shutdown_waittime} =~ /^\d+?$/){
				$maxWaitTime = $Cfg::Preferences{protocol_shutdown_waittime};
			}
			
			while ($pidSize > 0 && $timeWaited < $maxWaitTime && is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1) {
				select(undef, undef, undef, 0.25); # Sleeps for 250ms
				
				# Add to time waited
				$timeWaited += 0.25;
				
				# Recheck server home PIDs
				@server_pids = get_home_pids($home_id);
				$pidSize = @server_pids;
			}
		}
		
		if (is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 0)
		{
			logger "Stopped server $server_ip:$server_port with rcon quit.";
			return 0;
		}
		else
		{
			logger "Failed to send rcon quit. Stopping server with kill command.";
		}
		
		@server_pids = get_home_pids($home_id);
		
		my $cnt;
		my $out;
		foreach my $pid (@server_pids)
		{
			chomp($pid);
			$cnt = sudo_exec_without_decrypt("kill 15 $pid", $as_user);
			($cnt, $out) = split(/;/, $cnt, 2);
			if ($cnt == -1)
			{
				$cnt = sudo_exec_without_decrypt("kill 9 $pid", $as_user);
				($cnt, $out) = split(/;/, $cnt, 2);
				if ($cnt == -1)
				{
					logger "Process $pid can not be stopped.";
				}
				else
				{
					logger "Stopped process with pid $pid successfully using kill 9.";
				}
			}
			else
			{
				logger "Stopped process with pid $pid successfully using kill 15.";
			}
		}
		sudo_exec_without_decrypt('screen -wipe > /dev/null 2>&1', $as_user);
		return 0;
	}
	else
	{
		logger "Remote control protocol not available or PASSWORD NOT SET. Using kill signal instead.";
		my @server_pids = get_home_pids($home_id);
		
		my $cnt;
		my $out;
		foreach my $pid (@server_pids)
		{
			chomp($pid);
			$cnt = sudo_exec_without_decrypt("kill 15 $pid", $as_user);
			($cnt, $out) = split(/;/, $cnt, 2);
			if ($cnt == -1)
			{
				$cnt = sudo_exec_without_decrypt("kill 9 $pid", $as_user);
				($cnt, $out) = split(/;/, $cnt, 2);
				if ($cnt == -1)
				{
					logger "Process $pid can not be stopped.";
				}
				else
				{
					logger "Stopped process with pid $pid successfully using kill 9.";
				}
			}
			else
			{
				logger "Stopped process with pid $pid successfully using kill 15.";
			}
		}
		sudo_exec_without_decrypt('screen -wipe > /dev/null 2>&1', $as_user);
		return 0;
	}
}

##### Send RCON command 
### Return 0 when error occurred on decryption.
### Return 1 on success
sub send_rcon_command
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $rconCommand) = decrypt_params(@_);

	# legacy console
	if ($control_protocol eq "lcon")
	{
		my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
		my $as_user = find_user_by_screen_id($screen_id);
		my $ScreenCommand = 'screen -S '.$screen_id.' -p 0 -X stuff "'.$rconCommand.'$(printf \\\\r)"';
		logger "Sending legacy console command to ".$screen_id.": \n$rconCommand \n .";
		my $ret = sudo_exec_without_decrypt($ScreenCommand, $as_user);	
		my ($retval, $enc_out) = split(/;/, $ret, 2);
		if($retval == 1)
		{
			my(@modedlines) = "$rconCommand";
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		return 0;
	}
	
	# Some validation checks for the variables.
	if ($server_ip =~ /^\s*$/ || $server_port < 0 || $server_port > 65535)
	{
		logger("Invalid IP:Port given $server_ip:$server_port.");
		return 0;
	}
	
	if ($control_password !~ /^\s*$/)
	{
		if ($control_protocol eq "rcon")
		{
			use KKrcon::KKrcon;
			my $rcon = new KKrcon(
								  Password => $control_password,
								  Host	 => $server_ip,
								  Port	 => $server_port,
								  Type	 => $control_type
								 );

			logger "Sending RCON command to $server_ip:$server_port: \n$rconCommand \n  .";
						
			my(@modedlines) = $rcon->execute($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		elsif ($control_protocol eq "rcon2")
		{
			use KKrcon::HL2;
			my $rcon2 = new HL2(
								  hostname => $server_ip,
								  port	 => $server_port,
								  password => $control_password,
								  timeout  => 2
								 );
			
			logger "Sending RCON command to $server_ip:$server_port: \n $rconCommand \n  .";
					
			my(@modedlines) = $rcon2->run($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		elsif ($control_protocol eq "armabe")
		{
			use ArmaBE::ArmaBE;
			my $armabe = new ArmaBE(
								  hostname => $server_ip,
								  port	 => $server_port, # Uses server port for now (Arma 2), Arma 3 BE uses a different, user definable port
								  password => $control_password,
								  timeout  => 2
								 );
			
			logger "Sending RCON command via ArmaBE module to $server_ip:$server_port: \n $rconCommand \n  .";
					
			my(@modedlines) = $armabe->run($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
	}
	else
	{
		logger "Control protocol PASSWORD NOT SET.";
		return -10;
	}
}

##### Returns a directory listing
### @return List of directories if everything OK.
### @return 0 If the directory is not found.
### @return -1 If cannot open the directory.
sub dirlist
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($datadir) = &decrypt_param(@_);
	logger "Asked for dirlist of $datadir directory.";
	if (!-d $datadir)
	{
		logger "ERROR - Directory [ $datadir ] not found!";
		return -1;
	}
	if (!opendir(DIR, $datadir))
	{
		logger "ERROR - Can't open $datadir: $!";
		return -2;
	}
	my @dirlist = readdir(DIR);
	closedir(DIR);
	return join(";", @dirlist);
}

##### Returns a directory listing with extra info the filemanager
### @return List of directories if everything OK.
### @return 1 If the directory is empty.
### @return -1 If the directory is not found.
### @return -2 If cannot open the directory.
sub dirlistfm
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $datadir = &decrypt_param(@_);
	
	logger "Asked for dirlist of $datadir directory.";
	
	if (!-d $datadir)
	{
		logger "ERROR - Directory [ $datadir ] not found!";
		return -1;
	}
	
	if (!opendir(DIR, $datadir))
	{
		logger "ERROR - Can't open $datadir: $!";
		return -2;
	}
	
	my $dir = $datadir;
	$dir =~ s/('+)/'"$1"'/g;
	my $lsattr = `lsattr '$dir' 2>/dev/null`;
	
	my @attr_all = split /\n+/, $lsattr;
	
	my %attr = ();
	
	my ($a, $p, @f);
	
	foreach (@attr_all)
	{
		($a, $p) = split(/\s/, $_, 2);
		@f = split /\//, $p;
		$attr{$f[-1]}	= $a;
	}
	
	my %dirfiles = ();
	
	my (
		$dev,  $ino,   $mode,  $nlink, $uid,	 $gid, $rdev,
		$size, $atime, $mtime, $ctime, $blksize, $blocks
	   );
	
	my $count = 0;
	
	chdir($datadir);
	
	while (my $item = readdir(DIR))
	{
		#skip the . and .. special dirs
		next if $item eq '.';
		next if $item eq '..';
		#print "Dir list is" . $item."\n";
		#Stat the file to get ownership and size
		(
		 $dev,  $ino,   $mode,  $nlink, $uid,	 $gid, $rdev,
		 $size, $atime, $mtime, $ctime, $blksize, $blocks
		) = stat($item);
		
		if(defined $uid)
		{
			$uid = getpwuid($uid);
		}
		else
		{
			$uid = '';
		}
		
		if(defined $gid)
		{
			$gid = getgrgid($gid);
		}
		else
		{
			$gid = '';
		}
		
		#This if else logic determines what it is, File, Directory, other	
		if (-T $item)
		{
			# print "File\n";
			$dirfiles{'files'}{$count}{'filename'}	= encode_base64($item);
			$dirfiles{'files'}{$count}{'size'}		= $size;
			$dirfiles{'files'}{$count}{'user'}		= $uid;
			$dirfiles{'files'}{$count}{'group'}		= $gid;
			$dirfiles{'files'}{$count}{'attr'}		= $attr{$item};
		}
		elsif (-d $item)
		{
			# print "Dir\n";
			$dirfiles{'directorys'}{$count}{'filename'}	= encode_base64($item);
			$dirfiles{'directorys'}{$count}{'size'}		= $size;
			$dirfiles{'directorys'}{$count}{'user'}		= $uid;
			$dirfiles{'directorys'}{$count}{'group'}	= $gid;
		}
		elsif (-B $item)
		{
			#print "File\n";
			$dirfiles{'binarys'}{$count}{'filename'}	= encode_base64($item);
			$dirfiles{'binarys'}{$count}{'size'}		= $size;
			$dirfiles{'binarys'}{$count}{'user'}		= $uid;
			$dirfiles{'binarys'}{$count}{'group'}		= $gid;
			$dirfiles{'binarys'}{$count}{'attr'}		= $attr{$item};
		}
		else
		{
			#print "Unknown\n"
			#will be listed as common files;
			$dirfiles{'files'}{$count}{'filename'}	= encode_base64($item);
			$dirfiles{'files'}{$count}{'size'}		= $size;
			$dirfiles{'files'}{$count}{'user'}		= $uid;
			$dirfiles{'files'}{$count}{'group'}		= $gid;
			$dirfiles{'files'}{$count}{'attr'}		= $attr{$item};
		}
		$count++;
	}
	closedir(DIR);
	
	if ($count eq 0)
	{
		logger "Empty directory $datadir.";
		return 1;
	}
		
	chdir AGENT_RUN_DIR;
	#Now we return it to the webpage, as array
	return {%dirfiles};
}

###### Returns the contents of a text file
sub readfile
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	my $userfile = &decrypt_param(@_);

	unless ( -e $userfile )
	{
		if (open(BLANK, '>', $userfile))
		{
			close(BLANK);
		}
	}
	
	if (!open(USERFILE, '<', $userfile))
	{
		logger "ERROR - Can't open file $userfile for reading.";
		return -1;
	}

	my ($wholefile, $buf);

	while (read(USERFILE, $buf, 60 * 57))
	{
		$wholefile .= encode_base64($buf);
	}
	close(USERFILE);
	
	if(!defined $wholefile)
	{
		return "1; ";
	}
	
	return "1;" . $wholefile;
}

###### Backs up file, then writes data to new file
### @return 1 On success
### @return 0 In case of a failure
sub writefile
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	# $writefile = file we're editing, $filedata = the contents were writing to it
	my ($writefile, $filedata) = &decrypt_params(@_);
	if (!-e $writefile)
	{
		open FILE, ">", $writefile;
	}
	else
	{
		# backup the existing file
		logger
		  "Backing up file $writefile to $writefile.bak before writing new data.";
		if (!copy("$writefile", "$writefile.bak"))
		{
			logger
			  "ERROR - Failed to backup $writefile to $writefile.bak. Error: $!";
			return 0;
		}
	}
	if (!-w $writefile)
	{
		logger "ERROR - File [ $writefile ] is not writeable!";
		return 0;
	}
	if (!open(WRITER, '>', $writefile))
	{
		logger "ERROR - Failed to open $writefile for writing.";
		return 0;
	}
	$filedata = decode_base64($filedata);
	$filedata =~ s/\r//g;
	print WRITER "$filedata";
	close(WRITER);
	logger "Wrote $writefile successfully!";
	return 1;
}

###### Reboots the server remotely through panel
### @return 1 On success
### @return 0 In case of a failure
sub rebootnow
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	sudo_exec_without_decrypt('sleep 10s; shutdown -r now');
	logger "Scheduled system reboot to occur in 10 seconds successfully!";
	return 1;
}

# Determine the os of the agent machine.
sub what_os
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $which_uname = `which uname`;
	chomp $which_uname;
	if ($which_uname ne "")
	{
		my $os;
		my $os_name;
		my $os_arch;
		my $wine_ver = "";
		$os_name = `$which_uname`;
		chomp $os_name;
		$os_arch = `$which_uname -m`;
		chomp $os_arch;
		my $which_wine = `which wine`;
		chomp $which_wine;
		if ($which_wine ne "")
		{
			$wine_ver = `$which_wine --version`;
			chomp $wine_ver;
			$wine_ver = "|".$wine_ver;
		}
		$os = $os_name." ".$os_arch.$wine_ver;
		return "$os";
	}
	else
	{
		logger "Cannot determine OS..that is odd";
		return "Unknown";
	}
}

### @return PID of the download process if started succesfully.
### @return -1 If could not create temporary download directory.
### @return -2 If could not create destination directory.
### @return -3 If resources unavailable.
sub start_file_download
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($url, $destination, $filename, $action, $post_script) = &decrypt_params(@_);
	logger
	  "Starting to download URL $url. Destination: $destination - Filename: $filename";

	if (!-e $destination)
	{
		logger "Creating destination directory.";
		if (!mkpath $destination )
		{
			logger "Could not create destination '$destination' directory : $!";
			return -2;
		}
	}
	
	my $download_file_path = Path::Class::File->new($destination, "$filename");

	my $pid = fork();
	if (not defined $pid)
	{
		logger "Could not allocate resources for download.";
		return -3;
	}
	
	# Only the forked child goes here.
	elsif ($pid == 0)
	{
		my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0,
													SSL_verify_mode => 0x00 } );
		$ua->agent('Mozilla/5.0');
		my $response = $ua->get($url, ':content_file' => "$download_file_path");
		
		if ($response->is_success)
		{
			logger "Successfully fetched $url and stored it to $download_file_path. Retval: ".$response->status_line;
			
			if (!-e $download_file_path)
			{
				logger "File $download_file_path does not exist.";
				exit(0);
			}

			if ($action eq "uncompress")
			{
				logger "Starting file uncompress as ordered.";
				uncompress_file_without_decrypt($download_file_path,
												$destination);
			}
			
			# Run post scripts if any
			if ($post_script ne "")
			{
				logger "Running postscript commands.";
				my @postcmdlines = split /[\r\n]+/, $post_script;
				my $postcmdfile = $destination."/".'postinstall.sh';
				open  FILE, '>', $postcmdfile;
				print FILE "cd $destination\n";
				foreach my $line (@postcmdlines) {
					logger "Postscript command received \"" . $line ."\".";
					if(handle_lock_command_line($line) == 0){
						print FILE "$line\n";
					}else{
						logger "Lock command completed successfully";					
					}
				}
				print FILE "rm -f $destination/postinstall.sh\n";
				close FILE;
				chmod 0755, $postcmdfile;
				my $screen_id = create_screen_id("post_script", $$);
				my $cli_bin = create_screen_cmd($screen_id, "bash $postcmdfile");
				system($cli_bin);
			}
		}
		else
		{
			logger
			  "Unable to fetch $url, or save to $download_file_path. Retval: ".$response->status_line;
			exit(0);
		}

		# Child process must exit.
		exit(0);
	}
	else
	{
		logger "Download process for $download_file_path has pid number $pid.";
		return "$pid";
	}
}

sub lock_additional_files{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($homedir, $files, $action) = &decrypt_params(@_);
	return lock_additional_files_logic($homedir, $files, $action);
}

sub lock_additional_files_logic{
	my ($homedir, $filesToLock, $action, $returnType) = @_;
	
	logger "Locking additional files specified in the XML.";
	
	my $commandStr = "";
	$filesToLock = startup_comma_format_to_multiline($filesToLock);
	$filesToLock = replace_OGP_Env_Vars("", "", $homedir, $filesToLock);
	my @filesToProcess = split /[\r\n]+/, $filesToLock;
	foreach my $line (@filesToProcess) {
		my $fullPath = $homedir . "/" . $line;
		if($action eq "lock"){
			if(defined $returnType && $returnType eq "str"){
				$commandStr .= "echo '".$SUDOPASSWD."' | sudo -S -p \" \" sh -c \"" . secure_path_without_decrypt("chattr+i", $fullPath, $returnType) . "\" > /dev/null 2>&1" . "\n";
				$commandStr .= "echo '".$SUDOPASSWD."' | sudo -S -p \" \" sh -c \"" . secure_path_without_decrypt("chattr+i", $line, $returnType) . "\" > /dev/null 2>&1" . "\n";
			}else{
				secure_path_without_decrypt("chattr+i", $fullPath);
				secure_path_without_decrypt("chattr+i", $line);
			}
		}else{
			if(defined $returnType && $returnType eq "str"){
				$commandStr .= "echo '".$SUDOPASSWD."' | sudo -S -p \" \" sh -c \"" . secure_path_without_decrypt("chattr-i", $fullPath, $returnType) . "\" > /dev/null 2>&1" . "\n";
				$commandStr .= "echo '".$SUDOPASSWD."' | sudo -S -p \" \" sh -c \"" . secure_path_without_decrypt("chattr-i", $line, $returnType) . "\" > /dev/null 2>&1" . "\n";
			}else{
				secure_path_without_decrypt("chattr-i", $fullPath);
				secure_path_without_decrypt("chattr-i", $line);
			}
		}
	}
	
	if($commandStr ne ""){
		return $commandStr;
	}
	
	return "";
}

sub run_before_start_commands
{
	#return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($server_id, $homedir, $beforestartcmd, $pathowner) = @_;
	
	if ($homedir ne "" && $server_id ne ""){
		# Run any prestart scripts
		if (defined $beforestartcmd && $beforestartcmd ne "")
		{		
			logger "Running pre-start XML commands before starting server ID $server_id with a home directory of $homedir.";
			my @prestartcmdlines = split /[\r\n]+/, $beforestartcmd;
			my $prestartcmdfile = $homedir."/".'prestart_ogp.sh';
			open  FILE, '>', $prestartcmdfile;
			print FILE "#!/bin/bash" . "\n";
			print FILE "cd $homedir\n";
			foreach my $line (@prestartcmdlines) {
				print FILE "$line\n";
			}
			print FILE "rm -f $prestartcmdfile\n";
			close FILE;
			chmod 0755, $prestartcmdfile;
			sudo_exec_without_decrypt("bash $prestartcmdfile", $pathowner);
		}		
	}else{
		return -2;
	}
	
	return 1;
}

sub multiline_to_startup_comma_format{
	my ($multiLineVar) = @_;
	$multiLineVar =~ s/,//g; # commas are invalid anyways in bash
	$multiLineVar =~ s/[\r]+//g;
	$multiLineVar =~ s/[\n]+/{OGPNEWLINE}/g;
	return $multiLineVar;
}

sub multiline_to_bash_commands{
	my ($multiLineVar) = @_;
	$multiLineVar =~ s/[\n]+/ && /g;
	return $multiLineVar;
}

sub startup_comma_format_to_multiline{
	my ($multiLineVar) = @_;
	$multiLineVar =~ s/{OGPNEWLINE}/\n/g;
	return $multiLineVar;
}

sub create_secure_script
{	
	my ($home_path, $exec_folder_path, $exec_path) = @_;
	secure_path_without_decrypt('chattr-i', $home_path);
	my $secure = "$home_path/secure.sh";
	$home_path =~ s/('+)/'\"$1\"'/g;
	$exec_folder_path =~ s/('+)/'\"$1\"'/g;
	$exec_path =~ s/('+)/'\"$1\"'/g;
	my $sec = $secure;
	$sec =~ s/('+)/'\"$1\"'/g;
	open  FILE, '>', $secure;
	print FILE	"chmod 771 '$exec_folder_path'\n".
				"chmod 750 '$exec_path'\n".
				"chmod +x '$exec_path'\n".
				"chattr +i '$exec_path'\n".
				"rm -f '$sec'";
	close FILE;
	chmod 0770, $secure;
	sudo_exec_without_decrypt("chown 0:0 '$sec'");
	return 0;
}

sub check_b4_chdir
{
	my ($path, $owner) = @_;
			
	if (!-e $path)
	{
		logger "$path does not exist yet. Trying to create it...";

		eval { mkpath($path); 1 } or logger "Error creating $path with Perl mkpath command. Errno: $! - Trying again with sudo...";

		if (!-e $path)
		{
			sudo_exec_without_decrypt('mkdir -p ' . $path);
		}
		
		if (!-e $path)
		{
			return -1;
		}
	}
	
	my $group = SERVER_RUNNER_USER;
	
	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$group = `whoami`;
		chomp $group;
	}
	
	set_path_ownership($owner, $group, $path);
	
	if (!chdir $path)
	{
		logger "Unable to change dir to '$path'.";
		return -1;
	}
	
	return 0;
}

sub set_path_ownership
{
	my ($owner, $group, $path) = @_;
	
	my $owner_uid = `id -u $owner`;
	chomp $owner_uid;
	my $group_uid = `id -g $group`;
	chomp $group_uid;
		
	# Remove immutable flag recursivelly
	secure_path_without_decrypt('chattr-i', $path);
	
	# Set owner and perms on it recursivelly as well
	my $chownCommand = "chown -Rf $owner_uid:$group_uid '$path'";
	my $chmodCommand = "chmod -Rf ug+rwx '$path'";
	my $chmodCommandDir = "chmod -Rf o+rx `find '$path' -type d`";
	my $groupCommand = "chmod -Rf g-s '$path'"; # Clean up the mess I made from previous version
	sudo_exec_without_decrypt($chownCommand);
	sudo_exec_without_decrypt($chmodCommand);
	sudo_exec_without_decrypt($chmodCommandDir);
	sudo_exec_without_decrypt($groupCommand);
	
	$groupCommand = "find '$path' -type d | xargs chmod g+s";
	sudo_exec_without_decrypt($groupCommand);
	
	$groupCommand = "find '$path' -type d | xargs setfacl -d -m u::rwX,g::rwX,o::rx";
	sudo_exec_without_decrypt($groupCommand);
	
	# Remove perms for other users
	$chmodCommand = "chmod -Rf o-rwx `find '$path' -type f`";
	sudo_exec_without_decrypt($chmodCommand);
		
	return 0;
}

sub create_bash_scripts
{
	my ( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds ) = @_;
	
	$home_path         =~ s/('+)/'\"$1\"'/g;
	$bash_scripts_path =~ s/('+)/'\"$1\"'/g;
	
	my @precmdlines = split /[\r\n]+/, $precmd;
	my $precmdfile = 'preinstall.sh';
	open  FILE, '>', $precmdfile;
	print FILE "cd '$home_path'\n";
	foreach my $line (@precmdlines) {
		print FILE "$line\n";
	}
	close FILE;
	chmod 0755, $precmdfile;
	
	my @postcmdlines = split /[\r\n]+/, $postcmd;
	my $postcmdfile = 'postinstall.sh';
	open  FILE, '>', $postcmdfile;
	print FILE "cd '$home_path'\n";
	foreach my $line (@postcmdlines) {
		print FILE "$line\n";
	}
	print FILE "cd '$home_path'\n".
			   "echo '".$SUDOPASSWD."' | sudo -S -p \" \" bash secure.sh\n".
			   "rm -f secure.sh\n".
			   "cd '$bash_scripts_path'\n".
			   "rm -f preinstall.sh\n".
			   "rm -f postinstall.sh\n".
			   "rm -f runinstall.sh\n";
	close FILE;
	chmod 0755, $postcmdfile;
	
	my $installfile = 'runinstall.sh';
	open  FILE, '>', $installfile;
	print FILE "#!/bin/bash\n".
			   "cd '$bash_scripts_path'\n".
			   "./$precmdfile\n";
	foreach my $installcmd (@installcmds)
	{
		print FILE "$installcmd\n";
	}
	print FILE "wait ".'${!}'."\n".
			   "cd '$bash_scripts_path'\n".
			   "./$postcmdfile\n";
	close FILE;
	chmod 0755, $installfile;
	
	return $installfile;
}

#### Run the rsync update ####
### @return 1 If update started
### @return 0 In error case.
sub start_rsync_install
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $home_path, $url, $exec_folder_path, $exec_path, $precmd, $postcmd, $filesToLockUnlock) = decrypt_params(@_);
	
	my $owner = get_path_owner($home_path);
	
	if ( check_b4_chdir($home_path, $owner) != 0)
	{
		return 0;
	}
		
	create_secure_script($home_path, $exec_folder_path, $exec_path);
	
	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;
	
	if ( check_b4_chdir($bash_scripts_path, $owner) != 0)
	{
		return 0;
	}
	
	# Rsync install require the rsync binary to exist in the system
	# to enable this functionality.
	my $rsync_binary = Path::Class::File->new("/usr/bin", "rsync");
	
	if (!-f $rsync_binary)
	{
		logger "Failed to start rsync update from "
		  . $url
		  . " to $home_path. Error: Rsync client not installed.";
		return 0;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	
	if(defined $filesToLockUnlock && $filesToLockUnlock ne ""){
		$postcmd .= "\n" . lock_additional_files_logic($home_path, $filesToLockUnlock, "lock", "str");
	}
	
	backup_home_log( $home_id, $log_file );
	my $path	= $home_path;
	$path		=~ s/('+)/'\"$1\"'/g;
	my @installcmds = ("/usr/bin/rsync --log-file='" . AGENT_RSYNC_GENERIC_LOG . "' --archive --compress --copy-links --update --verbose rsync://$url '$path'");
	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running rsync update: /usr/bin/rsync --log-file='" . AGENT_RSYNC_GENERIC_LOG . "' --archive --compress --copy-links --update --verbose rsync://$url '$home_path'";
	system($screen_cmd);
	
	chdir AGENT_RUN_DIR;
	return 1;
}

### @return PID of the download process if started succesfully.
### @return -1 If could not create temporary download directory.
### @return -2 If could not create destination directory.
### @return -3 If resources unavailable.
sub master_server_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id,$home_path,$ms_home_id,$ms_home_path,$exec_folder_path,$exec_path,$precmd,$postcmd) = decrypt_params(@_);
	my $owner = get_path_owner($home_path);
	
	if ( check_b4_chdir($home_path, $owner) != 0)
	{
		return 0;
	}
			
	create_secure_script($home_path, $exec_folder_path, $exec_path);
			
	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;
	
	if ( check_b4_chdir($bash_scripts_path, $owner) != 0)
	{
		return 0;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	
	backup_home_log( $home_id, $log_file );
	
	my $my_home_path = $home_path;
	$my_home_path =~ s/('+)/'\"$1\"'/g;
	$exec_path =~ s/\Q$home_path\E//g;
	$exec_path =~ s/^\///g;
	$exec_path =~ s/('+)/'\"$1\"'/g;
	$ms_home_path =~ s/('+)/'\"$1\"'/g;
	
	my @installcmds = ("cd '$ms_home_path'");
	
	## Copy files that match the extensions listed at extPatterns.txt
	open(EXT_PATTERNS, '<', Path::Class::File->new(AGENT_RUN_DIR, "extPatterns.txt"))
		  || logger "Error reading patterns file $!";
	my @ext_paterns = <EXT_PATTERNS>;
	foreach my $patern (@ext_paterns)
	{
		chop $patern;
		push (@installcmds, "find  -iname \\\*.$patern -exec cp -Rfp --parents {} '$my_home_path'/ \\\;");
	}
	close EXT_PATTERNS;
	
	## Copy the server executable so it can be secured with chattr +i
	push (@installcmds, "cp -vf --parents '$exec_path' '$my_home_path'");
	
	## Do symlinks for each of the other files
	push (@installcmds, "cp -vuRfs  '$ms_home_path'/* '$my_home_path'");
	
	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running master server update from home ID $home_id to home ID $ms_home_id";
	system($screen_cmd);
	
	chdir AGENT_RUN_DIR;
	return 1;
}

sub steam_cmd
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return steam_cmd_without_decrypt(decrypt_params(@_));
}

#### Run the steam client ####
### @return 1 If update started
### @return 0 In error case.
sub steam_cmd_without_decrypt
{
	my ($home_id, $home_path, $mod, $modname, $betaname, $betapwd, $user, $pass, $guard, $exec_folder_path, $exec_path, $precmd, $postcmd, $cfg_os, $filesToLockUnlock, $arch_bits) = @_;
	my $owner = get_path_owner($home_path);
	
	if ( check_b4_chdir($home_path, $owner) != 0)
	{
		return 0;
	}
		
	create_secure_script($home_path, $exec_folder_path, $exec_path);
	
	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;
	
	if ( check_b4_chdir($bash_scripts_path, $owner) != 0)
	{
		return 0;
	}
	
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	my $screen_id_for_txt_update = substr ($screen_id, rindex($screen_id, '_') + 1);
	my $steam_binary = Path::Class::File->new(STEAMCMD_CLIENT_DIR, "steamcmd.sh");
	my $installSteamFile =  $screen_id_for_txt_update . "_install.txt";

	my $installtxt = Path::Class::File->new(STEAMCMD_CLIENT_DIR, $installSteamFile);
	open  FILE, '>', $installtxt;
	print FILE "\@ShutdownOnFailedCommand 1\n";
	print FILE "\@NoPromptForPassword 1\n";
	if($cfg_os eq 'windows')
	{
		print FILE "\@sSteamCmdForcePlatformType windows\n";
	}
	
	# Handle requested SteamCMD architecture
	if(defined $arch_bits && $arch_bits ne ""){
		print FILE "\@sSteamCmdForcePlatformBitness " . $arch_bits . "\n";
	}
	
	if(defined STEAM_DL_LIMIT && STEAM_DL_LIMIT ne "" && is_integer(STEAM_DL_LIMIT) && STEAM_DL_LIMIT > 0){
		print FILE "set_download_throttle " . STEAM_DL_LIMIT . "\n";
	}
	
	print FILE "force_install_dir \"$home_path\"\n";
	
	if($guard ne '')
	{
		print FILE "set_steam_guard_code $guard\n";
	}
	if($user ne '' && $user ne 'anonymous')
	{
		print FILE "login $user $pass\n";
	}
	else
	{
		print FILE "login anonymous\n";
	}
	
	if($modname ne "")
	{
		print FILE "app_set_config $mod mod $modname\n";
		print FILE "app_update $mod mod $modname validate\n";	
	}

	if($betaname ne "" && $betapwd ne "")
	{
		print FILE "app_update $mod -beta $betaname -betapassword $betapwd\n";
	}
	elsif($betaname ne "" && $betapwd eq "")
	{
		print FILE "app_update $mod -beta $betaname\n";
	}
	else
	{
		print FILE "app_update $mod\n";
	}
	
	print FILE "exit\n";
	close FILE;
	
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log( $home_id, $log_file );
	
	my $postcmd_mod = $postcmd;
	
	if(defined $filesToLockUnlock && $filesToLockUnlock ne ""){
		$postcmd_mod .= "\n" . lock_additional_files_logic($home_path, $filesToLockUnlock, "lock", "str");
	}
	
	my @installcmds = ("$steam_binary +runscript $installtxt +exit");
	
	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd_mod, @installcmds );
	
	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	
	logger "Running steam update: $steam_binary +runscript $installtxt +exit";
	system($screen_cmd);

	return 1;
}

sub fetch_steam_version
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($appId, $pureOutput) = &decrypt_params(@_);

	my $steam_binary = Path::Class::File->new(STEAMCMD_CLIENT_DIR, "steamcmd.sh");
	my $steam_options = "+login anonymous +app_info_update 1 +app_info_print \"$appId\" +quit";
	my $grep = $pureOutput != "0" ? "" : '| grep -EA 1000 "^\s+\"branches\"$" | grep -EA 5 "^\s+\"public\"$" | grep -m 1 -EB 10 "^\s+}$" | grep -E "^\s+\"buildid\"\s+" | tr \'[:blank:]"\' \' \' | tr -s \' \' | cut -d\' \' -f3';

	logger "Getting latest version info for AppId $appId";
	my $response = `$steam_binary $steam_options $grep`;

	return $response;
}

sub installed_steam_version
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($game_home, $mod, $pureOutput) = &decrypt_params(@_);
	my $appFile = $game_home."/steamapps/appmanifest_$mod.acf";
	my $grep = $pureOutput != "0" ? "" : '| grep buildid | tr \'[:blank:]"\' \' \' | tr -s \' \' | cut -d\' \' -f3';

	if ( ! -f $appFile)
	{
		return "-10";
	}

	return `cat $appFile $grep`;
}

sub automatic_steam_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $game_home, $server_ip, $server_port, $exec_path, $exec_folder_path,
		$control_protocol, $control_password, $control_type,
		$appId, $modname, $betaname, $betapwd, $user, $pass, $guard, $precmd, $postcmd, $cfg_os, $filesToLockUnlock,
		$startup_cmd, $cpu, $nice, $preStart, $envVars, $game_key, $arch_bits, $console_log) = &decrypt_params(@_);

	# Is the server currently running? if it is, we'll try to start it after updating.
	my $isServerRunning = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;

	# Check if an update is already happening.
	if (is_screen_running_without_decrypt(SCREEN_TYPE_UPDATE, $home_id) == 1)
	{
		logger("Update already running for server $home_id, unable to start automatic update.");
		return -10;
	}

	# Stop the server if it's running.
	if ($isServerRunning == 1)
	{
		logger("Stopping server $home_id for automatic update.");

		if (stop_server_without_decrypt($home_id, $server_ip, $server_port, $control_protocol, $control_password, $control_type, $game_home) != 0)
		{
			logger("Failed to stop server $home_id for automatic update. Exiting update procedure.");
			return -9
		}

	}

	# steam_cmd: Returns 0 if the update failed, in which case, don't try starting the server - because we may have an incomplete or corrupt installation.
	if (steam_cmd_without_decrypt($home_id, $game_home, $appId, $modname, $betaname, $betapwd, $user, $pass, $guard, $exec_folder_path, $exec_path, $precmd, $postcmd, $cfg_os, $filesToLockUnlock, $arch_bits) == 0)
	{
		logger("Failed to start steam_cmd for server $home_id.");
		return -8;

	} else {

		if ($isServerRunning == 1)
		{
			while (1)
			{
				# If the update screen for $home_id isn't running, attempt to start the server.
				if (is_screen_running_without_decrypt(SCREEN_TYPE_UPDATE, $home_id) == 0)
				{

					if (universal_start_without_decrypt($home_id, $game_home, $exec_path, $exec_folder_path, $startup_cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log) != 1)
					{
						logger("Failed to start server $home_id after automatic update.");
						return -7;
					} else {
						logger("Starting server $home_id after automatic update.");
						return 1;
					}

					last;
				}

				sleep 5;
			}

		} else {
			# Update was started, but server wasn't initially running.
			return 2;
		}

	}

}

sub rsync_progress
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($running_home) = &decrypt_param(@_);
	logger "User requested progress on rsync job on home $running_home.";
	if (-r $running_home)
	{
		$running_home =~ s/('+)/'"$1"'/g;
		my $progress = `du -sk '$running_home'`;
		chomp($progress);
		my ($bytes, $junk) = split(/\s+/, $progress);
		logger("Found $bytes and $junk");
		return $bytes;
	}
	return "0";
}

sub is_file_download_in_progress
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($pid) = &decrypt_param(@_);
	logger "User requested if download is in progress with pid $pid.";
	my @pids = `ps -ef`;
	@pids = grep(/$pid/, @pids);
	logger "Number of pids for file download: @pids";
	if (@pids > '0')
	{
		return 1;
	}
	return 0;
}

### \return 1 If file is uncompressed succesfully.
### \return 0 If file does not exist.
### \return -1 If file could not be uncompressed.
sub uncompress_file
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return uncompress_file_without_decrypt(decrypt_params(@_));
}

sub uncompress_file_without_decrypt
{
	# Globals
	$Archive::Extract::PREFER_BIN = 1;

	# File must include full path.
	my ($file, $destination) = @_;

	logger "Uncompression called for file $file to dir $destination.";

	if (!-e $file)
	{
		logger "File $file could not be found for uncompression.";
		return 0;
	}

	if (!-e $destination)
	{
		mkpath($destination, {error => \my $err});
		if (@$err)
		{
			logger "Failed to create destination dir $destination.";
			return 0;
		}
	}

	my $filesize = (stat($file))[7];
	
	if($filesize >= 3221225472 && $file =~ /\.zip$/i){
		# Archive::Extract seems to have problems with large zip files, so for files greater than 3GB in size, let the system handle it
		logger "Using system call to unzip.";
		system("unzip -o $file -d $destination");
		if($? != 0){
			logger "Done.";
			return -1; 
		}
	}else{

		my $ae = Archive::Extract->new(archive => $file);

		if (!$ae)
		{
			logger "Could not create archive instance for file $file.";
			return -1;
		}

		my $ok = $ae->extract(to => $destination);

		if (!$ok)
		{
			logger "File $file could not be uncompressed.";
			return -1;
		}

		logger "File uncompressed/extracted successfully.";
	}
	
	return 1;
}

### \return 1 If files are compressed succesfully.
### \return -1 If files could not be compressed.
sub compress_files
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return compress_files_without_decrypt(decrypt_params(@_));
}

sub compress_files_without_decrypt
{
	my ($files,$destination,$archive_name,$archive_type) = @_;

	if (!-e $destination)
	{
		logger "compress_files: Destination path ( $destination ) could not be found.";
		return -1;
	}
	
	chdir $destination;
	my @items = split /\Q\n/, $files;
	my @inventory;
	if($archive_type eq "zip")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $zip = Archive::Zip->new();
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$zip->addFile( $item );
				}
				elsif (-d $item)
				{
					$zip->addTree( $item, $item );
				} 
			}
		}
		# Save the file
		unless ( $zip->writeToFileNamed($archive_name.'.zip') == AZ_OK ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tbz")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				} 
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type", COMPRESS_BZIP) ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tgz")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				} 
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type", COMPRESS_GZIP) ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tar")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				} 
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type") ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "bz2")
	{
		logger $archive_type." compression called.";
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					bzip2 $item => "$item.bz2";
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					foreach my $relative_item (@inventory) {
						bzip2 $relative_item => "$relative_item.bz2";
					}
				}
			}
		}
		logger $archive_type." archives created successfully at $destination";
		return 1;
	}
}

sub discover_ips
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($check) = decrypt_params(@_);

	if ($check ne "chk")
	{
		logger "Invalid parameter '$check' given for discover_ips function.";
		return "";
	}

	my $iplist = "";
	my $ipfound;
	my $junk;

	my @ipraw = `/sbin/ifconfig`;
	while (<@ipraw>)
	{
		chomp;
		next if $_ !~ /^inet:/ ;
		logger "Found addr on line: $_";
		($junk, $ipfound) = split(":", $_);
		next if $ipfound eq '';
		next if $ipfound eq '127.0.0.1';

		logger "Found an IP $ipfound";
		$iplist .= "$ipfound,";
		logger "IPlist is now $iplist";
	}
	while (<@ipraw>)
	{
		chomp;
		next if $_ !~ /^addr:/ ;
		logger "Found addr on line: $_";
		($junk, $ipfound) = split(":", $_);
		next if $ipfound eq '';
		next if $ipfound eq '127.0.0.1';

		logger "Found an IP $ipfound";
		$iplist .= "$ipfound,";
		logger "IPlist is now $iplist";
	}
	chop $iplist;
	return "$iplist";
}

### Return -1 In case of invalid param
### Return 1;content in case of success
sub mon_stats
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($mon_stats) = decrypt_params(@_);
	if ($mon_stats ne "mon_stats")
	{
		logger "Invalid parameter '$mon_stats' given for $mon_stats function.";
		return -1;
	}

	my @disk			= `df -hP -x tmpfs`;
	my $encoded_content = encode_list(@disk);
	my @uptime			= `uptime`;
	$encoded_content   .= encode_list(@uptime);
	return "1;$encoded_content";
}

sub exec
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($command) 		= decrypt_params(@_);
	my @cmdret			= `$command 2>/dev/null`;
	my $encoded_content	= encode_list(@cmdret);
	return "1;$encoded_content";
}

# used in conjunction with the clone_home feature in the web panel
# this actually does the file copies
sub clone_home
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($source_home, $dest_home, $owner) = decrypt_params(@_);
	my ($time_start, $time_stop, $time_diff);
	logger "Copying from $source_home to $dest_home...";

	# check size of source_home, make sure we have space to copy
	if (!-e $source_home)
	{
		logger "ERROR - $source_home does not exist";
		return 0;
	}
	logger "Game home $source_home exists...copy will proceed";

	# start the copy, and a timer
	$time_start = time();
	if (!dircopy("$source_home", "$dest_home"))
	{
		$time_stop = time();
		$time_diff = $time_stop - $time_start;
		logger
		  "Error occured after $time_diff seconds during copy of $source_home to $dest_home - $!";
		return 0;
	}
	else
	{
		$time_stop = time();
		$time_diff = $time_stop - $time_start;
		logger
		  "Home clone completed successfully to $dest_home in $time_diff seconds";
		return 1;
	}
}

# used to delete the game home from the file system when it's removed from the panel
sub remove_home
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_path_del) = decrypt_params(@_);

	if (!-e $home_path_del)
	{
		logger "ERROR - $home_path_del does not exist...nothing to do";
		return 0;
	}
	
	my $owner = get_path_owner($home_path_del);
	secure_path_without_decrypt('chattr-i', $home_path_del);
	my $deleted_home_dir = sudo_exec_without_decrypt('rm -rf \''.$home_path_del.'\'');
	
	if (defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		if ($owner ne SERVER_RUNNER_USER && begins_with($owner,'gamehome')){
			my $kill_all_user = sudo_exec_without_decrypt('killall -u "' . $owner . '"');
			my $deleted_user = sudo_exec_without_decrypt('userdel -r "' . $owner . '"');
			my ($retval_del_user, $enc_out_del_user) = split(/;/, $deleted_user, 2);
			if ($retval_del_user == 1){
				logger "Removing and deleting user $owner";
			}
			my $deleted_user_group = sudo_exec_without_decrypt('groupdel "' . $owner . '"');
		}
	}
	
	my ($retval, $enc_out) = split(/;/, $deleted_home_dir, 2);
	if ($retval == 1){
		logger "Deletetion of $home_path_del successful!";
	}else{
		logger "Deletetion of $home_path_del failed!";
	}
	
	return 1;
}

sub restart_server
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return restart_server_without_decrypt(decrypt_params(@_));
}

### Restart the server
## return -2 CANT STOP
## return -1  CANT START (no startup file found that mach the home_id, port and ip)
## return 1 Restart OK
sub restart_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $home_path, $server_exe, $run_dir,
		$cmd, $cpu, $nice, $preStart, $envVars, $game_key, $console_log) = @_;

	if (stop_server_without_decrypt($home_id, $server_ip, 
									$server_port, $control_protocol,
									$control_password, $control_type, $home_path) == 0)
	{
		if (universal_start_without_decrypt($home_id, $home_path, $server_exe, $run_dir,
											$cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log) == 1)
		{
			return 1;
		}
		else
		{
			return -1;
		}
	}
	else
	{
		return -2;
	}
}

sub find_user_by_screen_id
{
	my ($screen_id) = @_;
	
	my $screen_user = SERVER_RUNNER_USER;
	
	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$screen_user = `whoami`;
		chomp $screen_user;
	}
	
	my $ret = sudo_exec_without_decrypt('find /var/run/screen -name "*'.$screen_id.'"');
		
	my ($retval, $enc_out) = split(/;/, $ret, 2);
	
	if($retval != 1)
	{
		return $screen_user;
	}
		
	if( defined($enc_out) && $enc_out =~ /^(.+)\\n/ )
	{
		my @dec_out = ();
		foreach my $line (split /\\n/, $enc_out) {
			my $dec_line = decode_base64($line);
			push @dec_out, $dec_line;
		}
		
		my @path_parts = split /\//, $dec_out[0];
		
		if ($#path_parts == 5)
		{
			if($path_parts[5] =~ /^(\d+)\.$screen_id$/)
			{
				if ($path_parts[4] =~ /^S-/)
				{
					my $parseval = $path_parts[4];
					$parseval =~ s/^S-//g;
					my $uid = `id -u $parseval`;
					if( $uid =~ /^(\d+)$/ )
					{
						$screen_user = $parseval;
					}
				}
			}
		}
	}
	
	return $screen_user;
}

sub get_path_owner
{
	my ($path) = @_;
	
	my $path_owner = SERVER_RUNNER_USER;
	
	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$path_owner = `whoami`;
		chomp $path_owner;
	}
	
	if(-d $path)
	{
		my $ret = sudo_exec_without_decrypt('stat -c "%U" "'.$path.'"');
			
		my ($retval, $enc_out) = split(/;/, $ret, 2);
		
		if($retval != 1)
		{
			return $path_owner;
		}
			
		if( defined($enc_out) && $enc_out =~ /^(.+)\\n/ )
		{
			my @dec_out = ();
			foreach my $line (split /\\n/, $enc_out) {
				my $dec_line = decode_base64($line);
				push @dec_out, $dec_line;
			}

			my $parseval = $dec_out[0];
			my $uid = `id -u $parseval`;
			
			if( $uid =~ /^(\d+)$/ )
			{
				$path_owner = $parseval;
			}
		}
	}
	
	return $path_owner;
}

sub sudo_exec
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $sudo_exec = &decrypt_param(@_);
	return sudo_exec_without_decrypt($sudo_exec);
}

sub sudo_exec_without_decrypt
{
	my ($sudo_exec, $as_user) = @_;
	$sudo_exec =~ s/('+)/'"$1"'/g;
	if( !defined($as_user) )
	{
		$as_user = "root";
	}
	
	my $command = "echo '$SUDOPASSWD'|sudo -kS -p \"<prompt>\" su -c '$sudo_exec;echo \$?' $as_user 2>&1";
	my @cmdret = qx($command);
	$cmdret[0] =~ s/^<prompt>//g if defined $cmdret[0];
	chomp(@cmdret);
	
	my $ret = pop(@cmdret);
	chomp($ret);
	
	if ("X$ret" eq "X0")
	{
		return "1;".encode_list(@cmdret);
	}
	
	return -1;
}

sub sudo_exec_without_decrypt_no_return
{
	my ($sudo_exec, $as_user) = @_;
	$sudo_exec =~ s/('+)/'"$1"'/g;
	if( !defined($as_user) )
	{
		$as_user = "root";
	}
	
	my $command = "echo '$SUDOPASSWD'|sudo -kS -p \"<prompt>\" su -c '$sudo_exec' $as_user 2>&1";
	my @cmdret = qx($command);
	$cmdret[0] =~ s/^<prompt>//g if defined $cmdret[0];
	chomp(@cmdret);
	
	my $ret = pop(@cmdret);
	chomp($ret);
	
	if ("X$ret" eq "X0")
	{
		return "1;".encode_list(@cmdret);
	}
	
	return -1;
}

sub secure_path
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return secure_path_without_decrypt(decrypt_params(@_));
}

sub secure_path_without_decrypt
{   
	my ($action, $file_path, $returnType) = @_;
	my $checkIfFileExists = 1;
	
	if(defined $returnType && $returnType eq "str"){
		$checkIfFileExists = 0;
	}
	
	if($checkIfFileExists){
		if(! -e $file_path){
			return -1;
		}
	}
	
	$file_path =~ s/('+)/'\"$1\"'/g;
	if($action eq "chattr+i")
	{
		if(defined $returnType && $returnType eq "str"){
			return 'chattr -Rf +i \''.$file_path.'\'';
		}else{
			return sudo_exec_without_decrypt('chattr -Rf +i \''.$file_path.'\'');
		}
	}
	elsif($action eq "chattr-i")
	{
		if(defined $returnType && $returnType eq "str"){
			return 'chattr -Rf -i \''.$file_path.'\'';
		}else{
			return sudo_exec_without_decrypt('chattr -Rf -i \''.$file_path.'\'');
		}
	}
	
	return -1;
}

sub get_chattr
{   
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($file_path) = decrypt_params(@_);
	my $file = $file_path;
	$file_path =~ s/('+)/'\"$1\"'/g;
	return sudo_exec_without_decrypt('(lsattr \''.$file_path.'\' | sed -e "s#'.$file.'##g")|grep -o i');
}

sub ftp_mgr
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($action, $login, $password, $home_path) = decrypt_params(@_);
	
	my $uid = `id -u`;
	chomp $uid;
	my $gid = `id -g`;
	chomp $gid;
	
	$login =~ s/('+)/'\"$1\"'/g;
	$password =~ s/('+)/'\"$1\"'/g;
	$home_path =~ s/('+)/'\"$1\"'/g;
	
	if(!defined($Cfg::Preferences{ogp_manages_ftp}) || (defined($Cfg::Preferences{ogp_manages_ftp}) &&  $Cfg::Preferences{ogp_manages_ftp} eq "1")){
		if( defined($Cfg::Preferences{ftp_method}) && $Cfg::Preferences{ftp_method} eq "IspConfig")
		{
			use constant ISPCONFIG_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'IspConfig');
			use constant FTP_USERS_DIR => Path::Class::Dir->new(ISPCONFIG_DIR, 'ftp_users');
				
			if (!-d FTP_USERS_DIR && !mkdir FTP_USERS_DIR)
			{
				print "Could not create " . FTP_USERS_DIR . " directory $!.";
				return -1;
			}
			
			chdir ISPCONFIG_DIR;
			
			if($action eq "list")
			{
				my $users_list;
				opendir(USERS, FTP_USERS_DIR);
				while (my $username = readdir(USERS))
				{
					# Skip . and ..
					next if $username =~ /^\./;
					$users_list .= `php-cgi -f sites_ftp_user_get.php username=\'$username\'`;
				}
				closedir(USERS);
				if( defined($users_list) )
				{
					return "1;".encode_list($users_list);
				}
			}
			elsif($action eq "userdel")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_delete.php username=\'$login\'`);
			}
			elsif($action eq "useradd")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_add.php username=\'$login\' password=\'$password\' dir=\'$home_path\' uid=$uid gid=$gid`);
			}
			elsif($action eq "passwd")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_update.php type=passwd username=\'$login\' password=\'$password\'`);
			}
			elsif($action eq "show")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_get.php type=detail username=\'$login\'`);
			}
			elsif($action eq "usermod")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_update.php username=\'$login\' password=\'$password\'`);
			}
		}
		elsif(defined($Cfg::Preferences{ftp_method}) && $Cfg::Preferences{ftp_method} eq "EHCP" && (-e "/etc/init.d/ehcp" || -e "/lib/systemd/system/ehcp.service" || -e "/etc/systemd/system/ehcp.service" ))
		{
			use constant EHCP_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'EHCP');

			chdir EHCP_DIR;
			my $phpScript;
			my $phpOut;
			my $gidTwo = SERVER_RUNNER_USER;
			
			chmod 0777, 'ehcp_ftp_log.txt';
			
			# In order to access the FTP files, the vsftpd user needs to be added to the ogp group
			sudo_exec_without_decrypt("usermod -a -G '$gid' ftp"); 
			sudo_exec_without_decrypt("usermod -a -G '$gid' vsftpd"); 
			sudo_exec_without_decrypt("usermod -a -G '$gidTwo' ftp"); 
			sudo_exec_without_decrypt("usermod -a -G '$gidTwo' vsftpd"); 
			
			if($action eq "list")
			{
				return "1;".encode_list(`php-cgi -f listAllUsers.php`);
			}
			elsif($action eq "userdel")
			{
				$phpScript = `php-cgi -f delAccount.php username=\'$login\'`;
				$phpOut = `php-cgi -f syncftp.php`;
				return $phpScript;
			}
			elsif($action eq "useradd")
			{
				$phpScript = `php-cgi -f addAccount.php username=\'$login\' password=\'$password\' dir=\'$home_path\' uid=$uid gid=$gid`;
				$phpOut = `php-cgi -f syncftp.php`;
				return $phpScript;	
			}
			elsif($action eq "passwd")
			{
				$phpScript = `php-cgi -f updatePass.php username=\'$login\' password=\'$password\'`;
				$phpOut = `php-cgi -f syncftp.php`;
				return $phpScript ;	
			}
			elsif($action eq "show")
			{
				return "1;".encode_list(`php-cgi -f showAccount.php username=\'$login\'`);
			}
			elsif($action eq "usermod")
			{
				$phpScript = `php-cgi -f updateInfo.php username=\'$login\' password=\'$password\'`;
				$phpOut = `php-cgi -f syncftp.php`;
				return $phpScript;
			}
		}
		elsif(defined($Cfg::Preferences{ftp_method}) && $Cfg::Preferences{ftp_method} eq "proftpd" && -e $Cfg::Preferences{proftpd_conf_path})
		{
			chdir $Cfg::Preferences{proftpd_conf_path};
			if($action eq "list")
			{
				my $users;
				open(PASSWD, 'ftpd.passwd');
				while (<PASSWD>) {
					chomp;
					my($login, $passwd, $uid, $gid, $gcos, $home, $shell) = split(/:/);
					$users .= "$login\t$home\n";
				}
				close(PASSWD);
				return "1;".encode_list($users);
			}
			elsif($action eq "userdel")
			{
				return sudo_exec_without_decrypt("ftpasswd --passwd --delete-user --name='$login'");
			}
			elsif($action eq "useradd")
			{
				return sudo_exec_without_decrypt("echo '$password' | ftpasswd --passwd --name='$login' --home='$home_path' --shell=/bin/false --uid=$uid --gid=$gid --stdin");
			}
			elsif($action eq "passwd")
			{
				return sudo_exec_without_decrypt("echo '$password' | ftpasswd --passwd --change-password --name='$login' --stdin");
			}
			elsif($action eq "show")
			{
				return 1;
			}
			elsif($action eq "usermod")
			{
				return 1;
			}
			chdir AGENT_RUN_DIR;
		}
		else
		{
			if($action eq "list")
			{
				return sudo_exec_without_decrypt("pure-pw list");
			}
			elsif($action eq "userdel")
			{
				return sudo_exec_without_decrypt("pure-pw userdel '$login' && pure-pw mkdb");
			}
			elsif($action eq "useradd")
			{
				return sudo_exec_without_decrypt("(echo '$password'; echo '$password') | pure-pw useradd '$login' -u $uid -g $gid -d '$home_path' && pure-pw mkdb");
			}
			elsif($action eq "passwd")
			{
				return sudo_exec_without_decrypt("(echo '$password'; echo '$password') | pure-pw passwd '$login' && pure-pw mkdb");
			}
			elsif($action eq "show")
			{
				return sudo_exec_without_decrypt("pure-pw show '$login'");
			}
			elsif($action eq "usermod")
			{
				my $update_account = "pure-pw usermod '$login' -u $uid -g $gid";
				
				my @account_settings = split /[\n]+/, $password;
				
				foreach my $setting (@account_settings) {
					my ($key, $value) = split /[\t]+/, $setting;
					
					if( $key eq 'Directory' )
					{
						$value =~ s/('+)/'\"$1\"'/g;
						$update_account .= " -d '$value'";
					}
						
					if( $key eq 'Full_name' )
					{
						if(  $value ne "" )
						{
							$value =~ s/('+)/'\"$1\"'/g;
							$update_account .= " -c '$value'";
						}
						else
						{
							$update_account .= ' -c ""';
						}
					}
					
					if( $key eq 'Download_bandwidth' && $value ne ""  )
					{
						my $Download_bandwidth;
						if($value eq 0)
						{
							$Download_bandwidth = "\"\"";
						}
						else
						{
							$Download_bandwidth = $value;
						}
						$update_account .= " -t " . $Download_bandwidth;
					}
					
					if( $key eq 'Upload___bandwidth' && $value ne "" )
					{
						my $Upload___bandwidth;
						if($value eq 0)
						{
							$Upload___bandwidth = "\"\"";
						}
						else
						{
							$Upload___bandwidth = $value;
						}
						$update_account .= " -T " . $Upload___bandwidth;
					}
					
					if( $key eq 'Max_files' )
					{
						if( $value eq "0" )
						{
							$update_account .= ' -n ""';
						}
						elsif( $value ne "" )
						{
							$update_account .= " -n " . $value;
						}
						else
						{
							$update_account .= ' -n ""';
						}
					}
										
					if( $key eq 'Max_size' )
					{
						if( $value ne "" && $value ne "0" )
						{
							$update_account .= " -N " . $value;
						}
						else
						{
							$update_account .= ' -N ""';
						}
					}
										
					if( $key eq 'Ratio' && $value ne ""  )
					{
						my($upload_ratio,$download_ratio) = split/:/,$value;
						
						if($upload_ratio eq "0")
						{
							$upload_ratio = "\"\"";
						}
						$update_account .= " -q " . $upload_ratio;
						
						if($download_ratio eq "0")
						{
							$download_ratio = "\"\"";
						}
						$update_account .= " -Q " . $download_ratio;
					}
					
					if( $key eq 'Allowed_client_IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -r " . $value;
						}
						else
						{
							$update_account .= ' -r ""';
						}
					}
										
					if( $key eq 'Denied__client_IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -R " . $value;
						}
						else
						{
							$update_account .= ' -R ""';
						}
					}
					
					if( $key eq 'Allowed_local__IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -i " . $value;
						}
						else
						{
							$update_account .= ' -i ""';
						}
					}
										
					if( $key eq 'Denied__local__IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -I " . $value;
						}
						else
						{
							$update_account .= ' -I ""';
						}
					}
					
						
					if( $key eq 'Max_sim_sessions' && $value ne "" )
					{
						$update_account .= " -y " . $value;
					}
					
					if ( $key eq 'Time_restrictions'  )
					{
						if( $value eq "0000-0000")
						{
							$update_account .= ' -z ""';
						}
						elsif( $value ne "" )
						{
							$update_account .= " -z " . $value;
						}
						else
						{
							$update_account .= ' -z ""';
						}
					}
				}
				$update_account .=" && pure-pw mkdb";
				# print $update_account;
				return sudo_exec_without_decrypt($update_account);
			}
		}
	}
	return 0;
}

sub start_fastdl
{
	if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
	{
		system('perl FastDownload/ForkedDaemon.pm &');
		sleep(1);
		return 1;
	}
	else
	{
		return -2;
	}
}

sub stop_fastdl
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return stop_fastdl_without_decrypt();
}

sub stop_fastdl_without_decrypt
{
	my $pid;
	open(PIDFILE, '<', FD_PID_FILE)
	  || logger "Error reading pid file $!",1;
	while (<PIDFILE>)
	{
		$pid = $_;
		chomp $pid;
	}
	close(PIDFILE);
	my $cnt = kill 9, $pid;
	if ($cnt == 1)
	{
		logger "Fast Download Daemon Stopped.",1;
		return 1;
	}
	else
	{
		logger "Fast Download Daemon with pid $pid can not be stopped.",1;
		return -1;
	}
}

sub restart_fastdl
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return restart_fastdl_without_decrypt();
}

sub restart_fastdl_without_decrypt
{
	if((fastdl_status_without_decrypt() == -1) || (stop_fastdl_without_decrypt() == 1))
	{
		if(start_fastdl() == 1)
		{
			# Success
			return 1;
		}
		# Cant start
		return -2;
	}
	# Cant stop
	return -3;
}

sub fastdl_status
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return fastdl_status_without_decrypt();
}

sub fastdl_status_without_decrypt
{
	my $pid;
	if(!open(PIDFILE, '<', FD_PID_FILE))
	{
		logger "Error reading pid file $!";
		return -1;
	}
	while (<PIDFILE>)
	{
		$pid = $_;
		chomp $pid;
	}
	close(PIDFILE);
	my $cnt = kill 0, $pid;
	if ($cnt == 1)
	{
		return 1;
	}
	else
	{
		return -1;
	}
}

sub fastdl_get_aliases
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my %aliases;
	my $i;
	my @file_lines;
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
					$i = 0;
					@file_lines = ();
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
	return {%aliases};
}

sub fastdl_del_alias
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	foreach my $alias (decrypt_params(@_))
	{
		unlink Path::Class::File->new(FD_ALIASES_DIR, $alias);
	}
	return restart_fastdl_without_decrypt();
}

sub fastdl_add_alias
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($alias,$home,$match_file_extension,$match_client_ip) = decrypt_params(@_);
	if(!-e FD_ALIASES_DIR)
	{
		if(!mkdir FD_ALIASES_DIR)
		{
			logger "ERROR - Failed to create " . FD_ALIASES_DIR . " directory.";
			return -1;
		}
	}
	my $alias_path = Path::Class::File->new(FD_ALIASES_DIR, $alias);
	if (!open(ALIAS, '>', $alias_path))
	{
		logger "ERROR - Failed to open ".$alias_path." for writing.";
		return -1;
	}
	else
	{
		print ALIAS "$home\n";
		print ALIAS "$match_file_extension\n";
		print ALIAS "$match_client_ip";
		close(ALIAS);
		return restart_fastdl_without_decrypt();
	}
}

sub fastdl_get_info
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
	{
		delete $INC{"FastDownload/Settings.pm"};
		require "FastDownload/Settings.pm"; # Settings for Fast Download Daemon.
		if(not defined $FastDownload::Settings{autostart_on_agent_startup})
		{
			$FastDownload::Settings{autostart_on_agent_startup} = 0;
		}
		return {'port'						=>	$FastDownload::Settings{port},
				'ip'						=>	$FastDownload::Settings{ip},
				'listing'					=>	$FastDownload::Settings{listing},
				'autostart_on_agent_startup'=>	$FastDownload::Settings{autostart_on_agent_startup}};
	}
	return -1
}

sub fastdl_create_config
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if(!-e FD_DIR)
	{
		if(!mkdir FD_DIR)
		{
			logger "ERROR - Failed to create " . FD_DIR . " directory.";
			return -1;
		}
	}
	my ($fd_address, $fd_port, $listing, $autostart_on_agent_startup) = decrypt_params(@_);
	my $settings_string = "%FastDownload::Settings = (\n".
						  "\tport  => $fd_port,\n".
						  "\tip => '$fd_address',\n".
						  "\tlisting => $listing,\n".
						  "\tautostart_on_agent_startup => $autostart_on_agent_startup,\n".
						  ");";
	my $settings = Path::Class::File->new(FD_DIR, 'Settings.pm');
	if (!open(SETTINGS, '>', $settings))
	{
		logger "ERROR - Failed to open $settings for writing.";
		return -1;
	}
	else
	{
		print SETTINGS $settings_string;
		close(SETTINGS);
	}
	logger "$settings file written successfully.";
	return 1;
}

sub agent_restart
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $dec_check = decrypt_param(@_);
	if ($dec_check eq 'restart')
	{
		chdir AGENT_RUN_DIR;
		if(-e "ogp_agent_run.pid")
		{
			my $init_pid	= `cat ogp_agent_run.pid`;
			chomp($init_pid);
			
			if(kill 0, $init_pid)
			{
				my $or_exist	= "";
				my $rm_pid_file	= "";
				if(-e "ogp_agent.pid")
				{
					$rm_pid_file	= " ogp_agent.pid";
					my $agent_pid	= `cat ogp_agent.pid`;
					chomp($agent_pid);
					if( kill 0, $agent_pid )
					{
						$or_exist = " -o -e /proc/$agent_pid";
					}
				}
				
				open (AGENT_RESTART_SCRIPT, '>', 'tmp_restart.sh');
				my $restart = "echo -n \"Stopping OGP Agent...\"\n".
							  "kill $init_pid\n".
							  "while [ -e /proc/$init_pid $or_exist ];do echo -n .;sleep 1;done\n".
							  "rm -f ogp_agent_run.pid $rm_pid_file\necho \" [OK]\"\n".
							  "echo -n \"Starting OGP Agent...\"\n".
							  "screen -d -m -t \"ogp_agent\" -c \"" . SCREENRC_FILE . "\" -S ogp_agent bash ogp_agent_run -pidfile ogp_agent_run.pid\n".
							  "while [ ! -e ogp_agent_run.pid -o ! -e ogp_agent.pid ];do echo -n .;sleep 1;done\n".
							  "echo \" [OK]\"\n".
							  "rm -f tmp_restart.sh\n".
							  "exit 0\n";
				print AGENT_RESTART_SCRIPT $restart;
				close (AGENT_RESTART_SCRIPT);
				if( -e 'tmp_restart.sh' )
				{
					system('screen -d -m -t "agent_restart" -c "' . SCREENRC_FILE . '" -S agent_restart bash tmp_restart.sh');
				}
			}
		}
	}
	return -1;
}

# Subroutines to be called
sub scheduler_dispatcher {
	my ($task, $args) = @_;
	my $response = `$args`;
	chomp($response);
	my $log = "Executed command: $args";
	if($response ne "")
	{
		$log .= ", response:\n$response";
	}
	scheduler_log_events($log);
}

sub scheduler_server_action
{
	my ($task, $args) = @_;
	my ($action, @server_args) = split('\|\%\|', $args);
	if($action eq "%ACTION=start")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[6], $server_args[5]);
		my $ret = universal_start_without_decrypt(@server_args);
		if($ret == 1)
		{
			scheduler_log_events("Started server home ID $home_id on address $ip:$port");
		}
		else
		{
			scheduler_log_events("Failed starting server home ID $home_id on address $ip:$port (Check agent log)");
		}
	}
	elsif($action eq "%ACTION=stop")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[1], $server_args[2]);
		my $ret = stop_server_without_decrypt(@server_args);
		if($ret == 0)
		{
			scheduler_log_events("Stopped server home ID $home_id on address $ip:$port");
		}
		elsif($ret == 1)
		{
			scheduler_log_events("Failed stopping server home ID $home_id on address $ip:$port (Invalid IP:Port given)");
		}
	}
	elsif($action eq "%ACTION=restart")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[1], $server_args[2]);
		my $ret = restart_server_without_decrypt(@server_args);
		if($ret == 1)
		{
			scheduler_log_events("Restarted server home ID $home_id on address $ip:$port");
		}
		elsif($ret == -1)
		{
			scheduler_log_events("Failed restarting server home ID $home_id on address $ip:$port (Server could not be started, check agent log)");
		}
		elsif($ret == -2)
		{
			scheduler_log_events("Failed restarting server home ID $home_id on address $ip:$port (Server could not be stopped, check agent log)");
		}
	}
	return 1;
}

sub scheduler_log_events
{
	my $logcmd	 = $_[0];
	$logcmd = localtime() . " $logcmd\n";
	logger "Can't open " . SCHED_LOG_FILE . " - $!" unless open(LOGFILE, '>>', SCHED_LOG_FILE);
	logger "Failed to lock " . SCHED_LOG_FILE . "." unless flock(LOGFILE, LOCK_EX);
	logger "Failed to seek to end of " . SCHED_LOG_FILE . "." unless seek(LOGFILE, 0, 2);
	logger "Failed to write to " . SCHED_LOG_FILE . "." unless print LOGFILE "$logcmd";
	logger "Failed to unlock " . SCHED_LOG_FILE . "." unless flock(LOGFILE, LOCK_UN);
	logger "Failed to close " . SCHED_LOG_FILE . "." unless close(LOGFILE);
}

sub scheduler_add_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $new_task = decrypt_param(@_);
	if (open(TASKS, '>>', SCHED_TASKS))
	{
		print TASKS "$new_task\n";
		logger "Created new task: $new_task";
		close(TASKS);
		scheduler_stop();	
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot create task: $new_task ( $! )";
	return -1;
}

sub scheduler_del_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $name = decrypt_param(@_);
	my @cronJobIDs = split(',', $name);
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	if(open(TASKS, '>', SCHED_TASKS))
	{
		foreach my $task ( @entries ) {
			next if ( grep { $_ eq $task->{args}[0]} @cronJobIDs );
			next unless $task->{args}[0] =~ /task_[0-9]*/;
			if(defined $task->{args}[1])
			{
				print TASKS join(" ", $task->{time}, $task->{args}[1]) . "\n";
			}
			else
			{
				print TASKS $task->{time} . "\n";
			}
		}
		close( TASKS );
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot open file " . SCHED_TASKS . " for deleting task(s) id: $name ( $! )",1;
	return -1;
}

sub scheduler_edit_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($name, $new_task) = decrypt_params(@_);
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	if(open(TASKS, '>', SCHED_TASKS))
	{
		foreach my $task ( @entries ) {
			next unless $task->{args}[0] =~ /task_[0-9]*/;
			if($name eq $task->{args}[0])
			{
				print TASKS "$new_task\n";
			}
			else
			{
				if(defined $task->{args}[1])
				{
					print TASKS join(" ", $task->{time}, $task->{args}[1]) . "\n";
				}
				else
				{
					print TASKS $task->{time} . "\n";
				}
			}
		}
		close( TASKS );
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot open file " . SCHED_TASKS . " for editing task id: $name ( $! )",1;
	return -1;
}

sub scheduler_read_tasks
{
	if( open(TASKS, '<', SCHED_TASKS) )
	{
		$cron->clean_timetable();
	}
	else
	{
		logger "Error reading tasks file $!";
		scheduler_stop();
		return -1;
	}
	
	my $i = 0;
	while (<TASKS>)
	{	
		next if $_ =~ /^(#.*|[\s|\t]*?\n)/;
		my ($minute, $hour, $dayOfTheMonth, $month, $dayOfTheWeek, @args) = split(' ', $_);
		my $time = "$minute $hour $dayOfTheMonth $month $dayOfTheWeek";
		if("@args" =~ /^\%ACTION.*/)
		{
			$cron->add_entry($time, \&scheduler_server_action, 'task_' . $i++, "@args");
		}
		else
		{
			$cron->add_entry($time, 'task_' . $i++, "@args");
		}
	}
	close(TASKS);
	return 1;
}

sub scheduler_stop
{
	my $pid;
	if(open(PIDFILE, '<', SCHED_PID))
	{
		$pid = <PIDFILE>;
		chomp $pid;
		close(PIDFILE);
		if($pid ne "")
		{
			if( kill 0, $pid )
			{
				my $cnt = kill 9, $pid;
				if ($cnt == 1)
				{
					unlink SCHED_PID;
					return 1;
				}
			}
		}
	}
	return -1;
}

sub scheduler_list_tasks
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	my %entries_array;
	foreach my $task ( @entries ) {
		if( defined $task->{args}[1] )
		{
			$entries_array{$task->{args}[0]} = encode_base64(join(" ", $task->{time}, $task->{args}[1]));
		}
		else
		{
			$entries_array{$task->{args}[0]} = encode_base64($task->{time});
		}
	}
	if( %entries_array )
	{
		return {%entries_array};
	}
	return -1;
}

sub get_file_part
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($file, $offset) = decrypt_params(@_);
	if (!open(FILE, '<', $file))
	{
		logger "ERROR - Can't open file $file for reading.";
		return -1;
	}
	
	binmode(FILE);
	
	if($offset != 0)  
	{
		return -1 unless seek FILE, $offset, 0;
	}
	
	my $data = "";
	my ($n, $buf);
	my $limit = $offset + 60 * 57 * 1000; #Max 3420Kb (1000 iterations) (top statistics ~ VIRT 116m, RES 47m)
	while (($n = read FILE, $buf, 60 * 57) != 0 && $offset <= $limit ) {
		$data .= $buf;
		$offset += $n;
	}
	close(FILE);
	
    if( $data ne "" )
	{
		my $b64zlib = encode_base64(compress($data,9));
		return "$offset;$b64zlib";
	}
	else
	{
		return -1;
	}
}

sub stop_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $home_id = decrypt_param(@_);
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	system('screen -S '.$screen_id.' -p 0 -X stuff $\'\003\'');
	if ($? == 0)
	{
		return 0;
	}
	return 1
}

sub shell_action
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($action, $arguments) = decrypt_params(@_);
	
	if($action eq 'remove_file')
	{
		chomp($arguments);
		unlink($arguments);
		return "1;";
	}
	elsif($action eq 'remove_recursive')
	{
		my @items = split(';', $arguments);
		foreach my $item ( @items ) {
			chomp($item);
			if(-d $item)
			{
				pathrmdir($item);
			}
			else
			{
				unlink($item);
			}
		}
		return "1;";
	}
	elsif($action eq 'create_dir')
	{
		chomp($arguments);
		mkpath($arguments);
		return "1;";
	}
	elsif($action eq 'move')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			$dest = Path::Class::Dir->new($dest, basename($src));
			dirmove($src, $dest);
		}
		else
		{
			fmove($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'rename')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			dirmove($src, $dest);
		}
		else
		{
			fmove($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'copy')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			$dest = Path::Class::Dir->new($dest, basename($src));
			dircopy($src, $dest);
		}
		else
		{
			fcopy($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'touch')
	{
		chomp($arguments);
		open(FH, '>', $arguments);
		print FH "";
		close(FH);
		return "1;";
	}
	elsif($action eq 'size')
	{
		chomp($arguments);
		my $size = 0;
		if(-d $arguments)
		{
			find(sub { $size += -s }, $arguments ? $arguments : '.');
		}
		else
		{
			$size += (stat($arguments))[7];
		}
		return "1;" . encode_list($size);
	}
	elsif($action eq 'get_cpu_usage')
	{
		my %prev_idle;
		my %prev_total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$prev_idle{$1} = $stat[4];
			$prev_total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		sleep 1;
		my %idle;
		my %total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$idle{$1} = $stat[4];
			$total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		my %cpu_percent_usage;
		foreach my $key ( keys %idle )
		{
			my $diff_idle = $idle{$key} - $prev_idle{$key};
			my $diff_total = $total{$key} - $prev_total{$key};
			my $percent = (100 * ($diff_total - $diff_idle)) / $diff_total;
			$percent = sprintf "%.2f", $percent unless $percent == 0;
			$cpu_percent_usage{$key} = encode_base64($percent);
		}
		return {%cpu_percent_usage};
	}
	elsif($action eq 'get_ram_usage')
	{
		my($total, $buffers, $cached, $free) = qw(0 0 0 0);
		open(STAT, '/proc/meminfo');
		while (<STAT>) {
			$total   += $1 if /MemTotal\:\s+(\d+) kB/;
			$buffers += $1 if /Buffers\:\s+(\d+) kB/;
			$cached  += $1 if /Cached\:\s+(\d+) kB/;
			$free    += $1 if /MemFree\:\s+(\d+) kB/;
		}
		close STAT;
		my $used = $total - $free - $cached - $buffers;
		my $percent = 100 * $used / $total;
		my %mem_usage;
		$mem_usage{'used'}    = encode_base64($used * 1024);
		$mem_usage{'total'}   = encode_base64($total * 1024);
		$mem_usage{'percent'} = encode_base64($percent);
		return {%mem_usage};
	}
	elsif($action eq 'get_disk_usage')
	{
		my($total, $used, $free) = split(' ', `df -lP 2>/dev/null|grep "^/dev/.*"|awk '{total+=\$2}{used+=\$3}{free+=\$4} END {print total, used, free}'`);
		my $percent = 100 * $used / $total;
		my %disk_usage;
		$disk_usage{'free'}    = encode_base64($free * 1024);
		$disk_usage{'used'}    = encode_base64($used * 1024);
		$disk_usage{'total'}   = encode_base64($total * 1024);
		$disk_usage{'percent'} = encode_base64($percent);
		return {%disk_usage};
	}
	elsif($action eq 'get_uptime')
	{
		open(STAT, '/proc/uptime');
		my $uptime = 0;
		while (<STAT>) {
			$uptime += $1 if /^([0-9]+)/;
		}
		close STAT;
		my %upsince;
		$upsince{'0'} = encode_base64($uptime);
		$upsince{'1'} = encode_base64(time - $uptime);
		return {%upsince};
	}
	elsif($action eq 'get_tasklist')
	{
		my %taskList;
		$taskList{'task'} = encode_base64(qx[top -b -c -i -w512 -n2 -o+%CPU|awk '/^top/{i++}i==2'|grep 'PID' -A 30]);
		return {%taskList};
	}
	elsif($action eq 'get_timestamp')
	{
		return "1;" . encode_list(time);
	}
	return 0;
}

sub remote_query
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($protocol, $game_type, $ip, $c_port, $q_port, $s_port) = decrypt_params(@_);
	my $command = "which php-cgi 2>&1;echo \$?";
	my @cmdret = qx($command);
	chomp(@cmdret);
	my $ret = pop(@cmdret);
	chomp($ret);
	if ("X$ret" ne "X0")
	{
		return -1;
	}
	my $PHP_CGI = "@cmdret";
	my $php_query_dir = Path::Class::Dir->new(AGENT_RUN_DIR, 'php-query');
	if($protocol eq 'lgsl')
	{
		chdir($php_query_dir->subdir('lgsl'));
		my $cmd = $PHP_CGI .
				" -f lgsl_feed.php" .
				" lgsl_type=" . $game_type . 
				" ip=" . $ip .
				" c_port=" . $c_port .
				" q_port=" . $q_port .
				" s_port=" . $s_port .
				" request=sp";
		my $response = `$cmd`;
		chomp($response);
		chdir(AGENT_RUN_DIR);
		if($response eq "FAILURE")
		{
			return -1;
		}
		return encode_base64($response, "");
	}
	elsif($protocol eq 'gameq')
	{
		chdir($php_query_dir->subdir('gameq'));
		my $cmd = $PHP_CGI .
				" -f gameq_feed.php" .
				" game_type=" . $game_type . 
				" ip=" . $ip .
				" c_port=" . $c_port .
				" q_port=" . $q_port .
				" s_port=" . $s_port;
		my $response = `$cmd`;
		chomp($response);
		chdir(AGENT_RUN_DIR);
		if($response eq "FAILURE")
		{
			return -1;
		}
		return encode_base64($response, "");
	}
	return -1;
}

sub send_steam_guard_code
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $sgc) = decrypt_params(@_);
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	system('screen -S '.$screen_id.' -p 0 -X stuff "'.$sgc.'$(printf \\\\r)"');
	if ($? == 0)
	{
		return 0;
	}
	return 1
}

sub steam_workshop
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return steam_workshop_without_decrypt(decrypt_params(@_));
}

#### Run the steam client ####
### @return 1 If installation started
### @return -1 In error case.
sub steam_workshop_without_decrypt
{
	my ($home_id, $mods_full_path,
		$workshop_id, $mods_list,
		$regex, $mods_backreference_index,
		$variable, $place_after, $mod_string, 
		$string_separator, $config_file_path, 
		$post_install, $mod_names_list,
		$anonymous_login, $user, $pass,
		$download_method, $url_list, $filename_list) = @_;
	
	# Creates mods path if it doesn't exist
	my $owner = SERVER_RUNNER_USER;
	
	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$owner = `whoami`;
		chomp $owner;
	}

	if ( check_b4_chdir($mods_full_path, $owner) != 0)
	{
		return -1;
	}
	
	my $secure = "$mods_full_path/secure.sh";
	my $home_path = $mods_full_path;
	$home_path =~ s/('+)/'\"$1\"'/g;
	my $sec = $secure;
	$sec =~ s/('+)/'\"$1\"'/g;
	open  FILE, '>', $secure;
	print FILE	"chmod 771 '$home_path'\n".
				"rm -f '$sec'";
	close FILE;
	
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	my @workshop_mods = split /,/, $mods_list;
	my @installcmds;
	
	if($download_method eq 'steamcmd')
	{
		my $steam_binary = STEAMCMD_CLIENT_BIN;
		my $installSteamFile = $screen_id . "_workshop.txt";	
		my $installtxt = Path::Class::File->new(STEAMCMD_CLIENT_DIR, $installSteamFile);

		open  FILE, '>', $installtxt;
		print FILE "\@ShutdownOnFailedCommand 1\n";
		print FILE "\@NoPromptForPassword 1\n";
		if($anonymous_login eq "0")
		{
			print FILE "login $user $pass\n";
		}
		else
		{
			print FILE "login anonymous\n";
		}
		print FILE "force_install_dir \"$mods_full_path\"\n";
		foreach my $workshop_mod (@workshop_mods)
		{
			print FILE "workshop_download_item $workshop_id $workshop_mod\n";
		}
		print FILE "exit\n";
		close FILE;
		@installcmds = ("$steam_binary +runscript $installtxt +exit");
	}
	
	if($download_method eq 'steamapi')
	{
		my @urls =  split /,/, $url_list;
		my @filenames =  split /,/, $filename_list;
		my $index = 0;
		foreach my $workshop_mod_id (@workshop_mods)
		{
			my $steamcmd_download_path = '/steamapps/workshop/content/'.$workshop_id.'/'.$workshop_mod_id.'/';
			
			my $workshop_mod_path = $mods_full_path.$steamcmd_download_path;
			if(!-d $workshop_mod_path && !mkpath $workshop_mod_path)
			{
				logger "Folder $workshop_mod_path could not be created.";
				$index++;
				next;
			}
			my $url = $urls[$index];
			my $filename = $filenames[$index];
			my $download_file_path = Path::Class::File->new($workshop_mod_path, "$filename");
			$installcmds[$index] = "wget -O \"$download_file_path\" \"$url\"";
			$index++;
		}
	}
	
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log($home_id, $log_file);
		
	my $precmd = "";
	my $postcmd = "";
	
	$postcmd .= generate_post_install_scripts($mods_full_path, $workshop_id, $mods_list,
											  $regex, $mods_backreference_index,
											  $variable, $place_after, $mod_string, 
											  $string_separator, $config_file_path, 
											  $post_install, $mod_names_list);
	
	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;
	
	if ( check_b4_chdir($bash_scripts_path, $owner) != 0)
	{
		return -1;
	}
	
	my $installfile = create_bash_scripts($mods_full_path, $bash_scripts_path, $precmd, $postcmd, @installcmds);
	
	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	
	logger "Installing Steam Workshop content on server Home ID " . $home_id;
	system($screen_cmd);
	
	return 1;
}

sub	generate_post_install_scripts
{
	my ($mods_full_path, $workshop_id, $mods_list,
		$regex, $mods_backreference_index,
		$variable, $place_after, $mod_string, 
		$string_separator, $config_file_path, 
		$post_install, $mod_names_list) = @_;
	
	my $post_install_scripts = "";
	my $mods_info_path = Path::Class::Dir->new(AGENT_RUN_DIR, 'WorkshopModsInfo');
	$post_install_scripts .= "mods_full_path=\"$mods_full_path\"\n".
							 "workshop_id=\"$workshop_id\"\n".
							 "regex=\"$regex\"\n".
							 "mods_backreference_index=\"$mods_backreference_index\"\n".
							 "variable=\"$variable\"\n".
							 "place_after=\"$place_after\"\n".
							 "string_separator=\"$string_separator\"\n".
							 "config_file_path=\"$config_file_path\"\n".
							 "mods_info_path=\"$mods_info_path/\"\n";
	my @workshop_mods = split /,/, $mods_list;
	my @mod_names = split /,/, $mod_names_list;
	
	my $index = 0;
	foreach my $workshop_mod_id (@workshop_mods)
	{
		my $steamcmd_download_path = '/steamapps/workshop/content/'.$workshop_id.'/'.$workshop_mod_id.'/';
		my $workshop_mod_path = $mods_full_path.$steamcmd_download_path;
		my $this_mod_string = $mod_string;
		$this_mod_string =~ s/\%workshop_mod_id\%/$workshop_mod_id/g;
		
		$post_install_scripts .= "mod_string[$index]=\"$this_mod_string\"\n".
								 "mod_name[$index]=\"".$mod_names[$index]."\"\n".
								 "workshop_mod_id[$index]=\"$workshop_mod_id\"\n".
								 "workshop_mod_path[$index]=\"$workshop_mod_path\"\n";
		$index++;
	}
	
	$post_install_scripts .= 'if [ ! -e $config_file_path ];then'."\n".
							 '	if [ ! -d "$(dirname $config_file_path)" ];then mkdir -p "$(dirname $config_file_path)";fi'."\n".
							 '	echo -e "${place_after}\n${variable}" > $config_file_path'."\n".
							 'fi'."\n".
							 'i=0'."\n".
							 'for mod_id in "${workshop_mod_id[@]}"'."\n".
							 'do'."\n".
							 '	first_file="$(ls "${workshop_mod_path[$i]}"| sort -n | head -1)"'."\n";
	
	my @post_install_lines = split /[\r\n]+/, $post_install;
	foreach my $line (@post_install_lines) {
		if($line ne ""){
			$line =~ s/\%mods_full_path\%/\$mods_full_path/g;
			$line =~ s/\%workshop_mod_id\%/\$mod_id/g;
			$line =~ s/\%first_file\%/\$first_file/g;
			$post_install_scripts .= "\t".$line."\n";
		}
	}
	
	$post_install_scripts .= '	file_content=$(cat $config_file_path)'."\n".
							 '	if [[ $file_content =~ $regex ]]; then'."\n".
							 '		full_match="${BASH_REMATCH[0]}"'."\n".
							 '		mods_match="${BASH_REMATCH[$mods_backreference_index]}"'."\n".
							 '		found=1'."\n".
							 '	else'."\n".
							 '		found=0'."\n".
							 '	fi'."\n".
							 '	first_file_string="\%first_file%"'."\n".
							 
							 '	if [ -z "${mod_string[$i]##*$first_file_string*}" ];then'."\n".
							 '		mod_string[$i]="${mod_string[$i]/$first_file_string/$first_file}"'."\n".
							 '	fi'."\n".
							 '	if [ $found == 1 ] && [ "X$full_match" != "X" ];then'."\n".
							 '		if [ "X$mods_match" == "X" ];then'."\n".
							 '			new_mods=$(echo -e "${full_match}${mod_string[$i]}")'."\n".
							 '			echo -e "${file_content/$full_match/$new_mods}">"$config_file_path"'."\n".
							 '		else'."\n".
							 '			if [ ! -z "${mods_match##*${mod_string[$i]}*}" ];then'."\n".
							 '				new_mods=$(echo -e "${full_match}${string_separator}${mod_string[$i]}")'."\n".
							 '				echo -e "${file_content/$full_match/$new_mods}">"$config_file_path"'."\n".
							 '			fi'."\n".
							 '		fi'."\n".
							 '	else'."\n".
							 '		if [ "X$place_after" == "X" ];then'."\n".
							 '			echo -e "${file_content}${variable}${mod_string[$i]}">"$config_file_path"'."\n".
							 '		else'."\n".
							 '			if [ -z "${file_content##*${place_after}*}" ];then'."\n".
							 '				new_var="${variable}${mod_string[$i]}"'."\n".
							 '				place_after_esc=$(echo -e "$place_after"|sed -e \'s/[]\\/$*.^[]/\\\\&/g\')'."\n".
							 '				echo -e "$file_content"|sed \'/\'$place_after_esc\'/a \'$new_var>"$config_file_path"'."\n".
							 '			else'."\n".
							 '				echo -e "${file_content}${place_after}\n${variable}${mod_string[$i]}">"$config_file_path"'."\n".
							 '			fi'."\n".
							 '		fi'."\n".
							 '	fi'."\n".
							 '	if [ ! -d "${mods_info_path}" ];then mkdir -p "${mods_info_path}";fi'."\n".
							 '	echo "${mod_name[$i]}" > "${mods_info_path}${mod_string[$i]}.ogpmod"'."\n".
							 '	i=$(expr $i + 1)'."\n".
							 'done'."\n";
	return "$post_install_scripts";
}

sub get_workshop_mods_info()
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	
	my $mods_info_dir_path = Path::Class::Dir->new(AGENT_RUN_DIR, 'WorkshopModsInfo');
	
	if(-d $mods_info_dir_path)
	{
		opendir(MODS_INFO_DIR, $mods_info_dir_path) or return -1;
		my @mods_info;
		while(my $mod_info_file = readdir(MODS_INFO_DIR))
		{
			if($mod_info_file =~ /\.ogpmod$/)
			{
				my $mod_info_file_path = Path::Class::File->new($mods_info_dir_path, $mod_info_file);
				if(open(my $fh, '<:encoding(UTF-8)', $mod_info_file_path))
				{
					my $row = <$fh>;
					chomp $row;
					if($row ne "")
					{
						my ($string_name, $ext) = split(/\.ogp/, $mod_info_file);
						push @mods_info, "$string_name:$row";
					}
					close($fh);
				}
			}
		}
		closedir(MODS_INFO_DIR);
		return "1;".encode_list(@mods_info);
	}
	
	return -1;
}

sub get_setting_using_api
{
	my ($setting_name) = @_;
	
	if(defined WEB_API_URL && WEB_API_URL ne "" && defined WEB_ADMIN_API_KEY && WEB_ADMIN_API_KEY ne ""){
		my $url = WEB_API_URL . "?setting/get&setting_name=" . $setting_name . "&token=" . WEB_ADMIN_API_KEY;
		my $ua = LWP::UserAgent->new;
		$ua->agent('Mozilla/5.0');
		$ua->timeout(5);
		$ua->ssl_opts( verify_hostname => 0 ,SSL_verify_mode => 0x00);
		my $response = $ua->get($url);
		return $response->decoded_content();
	}
	
	return -1;
}

sub is_integer {
   defined $_[0] && $_[0] =~ /^[+-]?\d+$/;
}

sub get_minecraft_rcon_port{
	my ($home_dir) = @_;
	my $port = -1;
	my $findStr = "rcon.port=";
	my $file = Path::Class::File->new($home_dir, "server.properties");

	open(FH, '<', $file) or return -1;

	while(<FH>){
		if (begins_with($_,$findStr)){
			$port = int(substr($_, length($findStr)));
			last;
		}
	}

	close(FH);
	
	return $port;
}

sub begins_with
{
    return substr($_[0], 0, length($_[1])) eq $_[1];
}

sub generate_random_password{
	my ($length) = @_;
	my @alphanumeric = ('a'..'z', 'A'..'Z', 0..9,'!','_','-');
	my @numeric = (0..9);
	my $randpassword = '';
	
	if(not defined $length || not is_integer($length)){
		$length = 16;
	}

	until ( length($randpassword) > $length ) {
			$randpassword = $randpassword . join '', map $alphanumeric[rand @alphanumeric], 0..(rand @numeric);
	}

	return $randpassword;
}

sub trim{ 
	my $s = shift; 
	$s =~ s/^\s+|\s+$//g; 
	return $s 
};
