<?php
include("lgsl_protocol.php");

function lgsl_string_html($string, $xml_feed = FALSE, $word_wrap = 0)
{
	if ($word_wrap) { $string = lgsl_word_wrap($string, $word_wrap); }

	if ($xml_feed != FALSE)
	{
		$string = htmlspecialchars($string, ENT_QUOTES);
	}
	elseif (function_exists("mb_convert_encoding"))
	{
		$string = htmlspecialchars($string, ENT_QUOTES);
		$string = @mb_convert_encoding($string, "HTML-ENTITIES", "UTF-8");
	}
	else
	{
		$string = htmlentities($string, ENT_QUOTES, "UTF-8");
	}

	if ($word_wrap) { $string = lgsl_word_wrap($string); }

	return $string;
}

//------------------------------------------------------------------------------------------------------------+

function lgsl_word_wrap($string, $length_limit = 0)
{
	if (!$length_limit)
	{
		//    http://www.quirksmode.org/oddsandends/wbr.html
		//    return str_replace("\x05\x06", " ",       $string); // VISIBLE
		//    return str_replace("\x05\x06", "&shy;",   $string); // FF2 VISIBLE AND DIV NEEDED
		return str_replace("\x05\x06", "&#8203;", $string); // IE6 VISIBLE
	}

	$word_list = explode(" ", $string);

	foreach ($word_list as $key => $word)
	{
		$word_length = function_exists("mb_strlen") ? mb_strlen($word, "UTF-8") : strlen($word);

		if ($word_length < $length_limit) { continue; }

		$word_new = "";

		for ($i=0; $i<$word_length; $i+=$length_limit)
		{
			$word_new .= function_exists("mb_substr") ? mb_substr($word, $i, $length_limit, "UTF-8") : substr($word, $i, $length_limit);
			$word_new .= "\x05\x06";
		}

		$word_list[$key] = $word_new;
	}

	return implode(" ", $word_list);
}

//------------------------------------------------------------------------------------------------------------+

$type    = isset($_GET['lgsl_type'])? lgsl_string_html($_GET['lgsl_type']): "";
$ip      = isset($_GET['ip'])       ? lgsl_string_html($_GET['ip'])       : "";
$c_port  = isset($_GET['c_port'])   ? intval($_GET['c_port'])             : 0;
$q_port  = isset($_GET['q_port'])   ? intval($_GET['q_port'])             : 0;
$s_port  = isset($_GET['s_port'])   ? intval($_GET['s_port'])             : 0;
$request = isset($_GET['request'])  ? lgsl_string_html($_GET['request'])  : "";

//------------------------------------------------------------------------------------------------------------+
// VALIDATE REQUEST
if (!$type || !$ip || !$c_port || !$q_port  || !$request)
{
	echo "FAILURE"; return;
}

if ($q_port > 99999 || $q_port < 1024)
{
	echo "FAILURE"; return;
}

if (preg_match("/[^0-9a-z\.\-\[\]\:]/i", $ip))
{
	echo "FAILURE"; return;
}

if (preg_match("/[^a-z]/", $request))
{
	echo "FAILURE"; return;
}

if ($type == "test")
{
	echo "FAILURE"; return;
}

$lgsl_protocol_list = lgsl_protocol_list();

if (!isset($lgsl_protocol_list[$type]))
{
	echo "FAILURE"; return;
}

//------------------------------------------------------------------------------------------------------------+
// FILTER HOSTNAME AND IP FORMATS THAT PHP ACCEPTS BUT ARE NOT WANTED
if     (preg_match("/(\[[0-9a-z\:]+\])/iU", $ip, $match)) { $ip = $match[1]; }
elseif (preg_match("/([0-9a-z\.\-]+)/i", $ip, $match))    { $ip = $match[1]; }

//------------------------------------------------------------------------------------------------------------+
// QUERY SERVER
$server = lgsl_query_live($type, $ip, $c_port, $q_port, $s_port, $request);

//------------------------------------------------------------------------------------------------------------+
// SERIALIZED OUTPUT
echo "_SLGSLF_".serialize($server)."_SLGSLF_"; 
return;
