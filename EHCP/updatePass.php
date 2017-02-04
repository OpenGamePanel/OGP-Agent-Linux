<?php
if (file_exists("config.php")) {
    include 'config.php';
} else {
    die("config.php must exist within the installation root folder!");
}

include_once 'db_functions.php';

// Updates ftpuser's password
$success = 0;
$errorCount = 0;

if (isset($errors)) {
    unset($errors);
}

if (isset($_GET['username'])) {
    $ftp_username = $_GET['username'];
}

if (isset($_GET['password'])) {
    $ftp_pass = trim($_GET['password']);
}

if (!isset($ftp_username) || !isset($ftp_pass)) {
    $errorCount++;
    $errors[] = "No FTP accounts could be modified! Updated username and password were not sent by the OGP upload functions.";
} else {
    
    if ($errorCount == 0) {

        // Security checks
        $ftp_password_db = escapeSQLStr($ftp_pass, $connection);
        $ftp_username_db = escapeSQLStr($ftp_username, $connection);
        $SQL = "SELECT * FROM ftpaccounts WHERE ftpusername = '$ftp_username_db'";
        $Result = execSQL($SQL, $connection);
        
        if ($Result !== FALSE) {
            $count = countSQLResult($Result);
            
            if ($count != 1) {
                $errorCount++;
                $errors[] = "The account information was not updated because the FTP username $ftp_old_username never existed in the first place and cannot be modified";
            } else {
                
                if ($row = getSQLRow($Result)) {
                    $recordID = $row['id'];
                }

                // Update user's password data into DB:
                $SQL = "UPDATE ftpaccounts SET password=password('$ftp_password_db') WHERE ftpusername='$ftp_username_db'";
                $Result = execSQL($SQL, $connection);
                
                if ($Result !== FALSE) {
                    $success = 1;
                } else {
                    $errorCount++;
                    $errors[] = getSQLError($connection);
                }
            }
        } else {
            $errorCount++;
            $errors[] = getSQLError($connection);
        }
    }
}

// Log errors
if ($errorCount > 0) {
    addToLog($errors);
}

// Return value:
echo $success;
?>
