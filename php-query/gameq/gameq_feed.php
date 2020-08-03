<?php
require_once __DIR__ . '/Autoloader.php';

//------------------------------------------------------------------------------------------------------------+

$type    = isset($_GET['game_type'])? $_GET['game_type']                  : "";
$ip      = isset($_GET['ip'])       ? $_GET['ip']                         : "";
$c_port  = isset($_GET['c_port'])   ? intval($_GET['c_port'])             : 0;
$q_port  = isset($_GET['q_port'])   ? intval($_GET['q_port'])             : 0;
$s_port  = isset($_GET['s_port'])   ? intval($_GET['s_port'])             : 0;

//------------------------------------------------------------------------------------------------------------+
// VALIDATE REQUEST
if (!$type || !$ip || !$c_port || !$q_port)
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

/* $lgsl_protocol_list = lgsl_protocol_list();

if (!isset($lgsl_protocol_list[$type]))
{
	echo "FAILURE"; return;
} */

//------------------------------------------------------------------------------------------------------------+
// FILTER HOSTNAME AND IP FORMATS THAT PHP ACCEPTS BUT ARE NOT WANTED
if     (preg_match("/(\[[0-9a-z\:]+\])/iU", $ip, $match)) { $ip = $match[1]; }
elseif (preg_match("/([0-9a-z\.\-]+)/i", $ip, $match))    { $ip = $match[1]; }

//------------------------------------------------------------------------------------------------------------+
// QUERY SERVER
$gq = new \GameQ\GameQ();
$server = array(
					'id' => 'server',
					'type' => $type,
					'host' => $ip . ":" . $q_port,
				);
$gq->addServer($server);
$gq->setOption('timeout', 1);
$gq->setOption('debug', FALSE);
$gq->addFilter('normalise');
$results = $gq->process();

//------------------------------------------------------------------------------------------------------------+
// SERIALIZED OUTPUT
echo "_SGAMEQF_".serialize($results['server'])."_SGAMEQF_";
return;
