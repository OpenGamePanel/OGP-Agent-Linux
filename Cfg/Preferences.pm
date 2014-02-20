%Cfg::Preferences = (
    screen_log_local => 1,
    delete_logs_after => 30,
    );

# screen_log_local
	# 1 = Create a local log copy in the user's server home directory
	# 0 = Do not create a local log copy

# delete_logs_after
	# Specify when to delete old backup log files to free space after a specified number of days.  
	# Integer value only that must be greater than 0 [default 30 days old]
