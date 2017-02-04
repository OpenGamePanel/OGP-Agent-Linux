<?php
$countNotNull = 0;
$user_details = "";
$success = 0;
$errorCount = 0;

if (isset($errors)) {
    unset($errors);
}

if (!isset($connection)) {
    include "config.php";
}

include_once 'db_functions.php';

if (isset($_GET['username'])) {
    $ftp_account = $_GET['username'];
}

if (!isset($connection)) {
    die("Problem setting up connection!");
} else
if (isset($ftp_account)) {
    $SQL = "SELECT ftpusername, homedir FROM ftpaccounts WHERE ftpusername = '$ftp_account'";
    $Result = execSQL($SQL, $connection);
    
    if ($Result !== FALSE) {
        $count = countSQLResult($Result);
        
        if ($count == 1) {
			if ($row = getSQLRow($Result)) {
				// Only show custom entries... do not allow to modify EHCP accounts.
				if (!empty($row['homedir'])) {
					$countNotNull++;
					$username = $row['ftpusername'];
					$dir = $row['homedir'];
					$user_details.= "Username" . " : " . $username . "\n";
					$user_details.= "Directory" . " : " . $dir . "\n";
				}
			}
            
            if ($countNotNull == 0) {
                $errorCount++;
                $errors[] = "There are no custom FTP accounts yet in the EHCP database!";
            }
        } else {
            $errorCount++;
            $errors[] = "No FTP accounts exist with the given username of $ftp_account";
        }
    } else {
        $errorCount++;
        $errors[] = getSQLError($connection);
		$success = 0;
    }

    // Log errors
    
    if ($errorCount > 0) {
        addToLog($errors);
    }
}

// Return the user list
echo $user_details;
?>
