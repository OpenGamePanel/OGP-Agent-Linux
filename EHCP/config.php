<?php
/*
This FTP addon works with EHCP (www.ehcp.net)
It allows OGP - the open game panel - to manage custom FTP user accounts

by own3mall
*/

@include_once "/var/www/new/ehcp/config.php";

/**********************************
*             DB Creds            *
* ********************************/
// Database credentials change if needed
$server = 'localhost';
$login = 'ehcp';

// Script should detect password automatically from EHCP config file above... but if not, please change the value down here.
if(!isset($dbpass) || empty($dbpass)){
	$dbpass = 'changeme';
}

$dbName = 'ehcp';
$debug=false;

/**********************************
*          END DB Creds           *
* ********************************/

// Log File
$logFile = 'ehcp_ftp_log.txt';

function addToLog($errors) {
    global $logFile, $debug;
    
    if (!file_exists($logFile)) {
        $createLog = fopen($logFile, 'a+');
        
        if (!$createLog) {
            trigger_error("Unable to create EHCP FTP Integration log file! Please create a file named \"ehcp_ftp_log.txt\" in the ogp_agent install directory under the EHCP folder with permissions of 777", E_USER_NOTICE);
        }
        fclose($createLog);
    }
    
    if (!is_writable($logFile)) {
        $chPerm = chmod($logFile, 777);
        
        if (!$chPerm) {
            trigger_error("The $logFile file is not writable. CHMOD failed. Please manually set the chmod to 777!", E_USER_NOTICE);
        }
    }
    $logContents = file_get_contents($logFile);
    
    foreach ($errors as $err) {
        $logContents.= $err . "\n";
        if($debug){
			trigger_error($err, E_USER_NOTICE);
			echo $err . "\n";
		}
    }
    $updateLog = file_put_contents($logFile, $logContents);
    
    if (!$updateLog) {
        trigger_error("Unable to write errors to the log file of $logFile", E_USER_NOTICE);
    }
}

// Create the database connection
if(function_exists("mysql_connect")){
	$connection = mysql_connect($server, $login, $dbpass);
	if ($connection) {
		mysql_select_db($dbName, $connection);
	}
}else{
	$connection = mysqli_connect($server, $login, $dbpass, $dbName);
}

if(!$connection){
    $errToLog[] = 'Unable to connect to the EHCP MySQL database using provided credentials! Please update your config.php settings!';
    addToLog($errToLog);
    die('Unable to connect to the EHCP MySQL database using provided credentials! Please update your config.php settings!');
}
?>
