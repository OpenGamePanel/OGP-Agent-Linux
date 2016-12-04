<?php
	function execSQL($SQL, $connection){		
		if($connection){
			if(function_exists("mysql_query")){
				return mysql_query($SQL, $connection);
			}else{
				return mysqli_query($connection, $SQL);
			}
		}
		
		return false;
	}
	
	function countSQLResult($Result){
		if(function_exists("mysql_num_rows")){
			return mysql_num_rows($Result);
		}else{
			return mysqli_num_rows($Result);
		}
	}
	
	function getSQLError($connection){
		if(function_exists("mysql_error")){
			return "Error code " . mysql_errno($connection) . ": " . mysql_error($connection);
		}else{
			return "Error code " . mysqli_errno($connection) . ": " . mysqli_error($connection);
		}
	}
	
	function getSQLRow($Result){
		if(function_exists("mysql_fetch_assoc")){
			return mysql_fetch_assoc($Result);
		}else{
			return mysqli_fetch_assoc($Result);
		}
	}
	
	function getSQLRowArray($Result){
		if(function_exists("mysql_fetch_row")){
			return mysql_fetch_row($Result);
		}else{
			return mysqli_fetch_row($Result);
		}
	}
	
	function escapeSQLStr($str, $connection){
		if(function_exists("mysql_real_escape_string")){
			return mysql_real_escape_string($str);
		}else{
			return mysqli_real_escape_string($connection, $str);
		}
	}
?>
