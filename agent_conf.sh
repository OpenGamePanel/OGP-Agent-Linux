#!/bin/bash
#
# OGP - Open Game Panel
# Copyright (C) Copyright (C) 2008 - 2013 The OGP Development Team
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

if [ ! -z "$1" ]; then
	opType="$1"
fi

if [ ! -z "$2" ]; then
	sudo_password="$2"
fi

readonly DEFAULT_PORT=12679
readonly DEFAULT_IP=0.0.0.0
readonly AGENT_VERSION='v1.0'

failed()
{
	echo "ERROR: ${1}"
	exit 1
}

agent_home="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" 

cfgfile=${agent_home}/Cfg/Config.pm
prefsfile=${agent_home}/Cfg/Preferences.pm
bashprefsfile=${agent_home}/Cfg/bash_prefs.cfg

overwrite_config=1

if [ -z "$opType" ]; then
	if [ -e ${cfgfile} ]; then
		while [ 1 ]
		do
			echo "Overwrite old config file ($cfgfile)?"
			echo -n "(yes/no) [Default yes]: " 
			read octmp
			if [ "$octmp" == "yes" -o -z "$octmp" ]
			then
				break
			elif [ "$octmp" == "no" ]
			then
				overwrite_config=0
				break
			else
				echo "You need to type 'yes', 'no' or leave empty for default value [yes].";
			fi
		done
	fi
else
	overwrite_config=0
fi

if [ "X${overwrite_config}" == "X1" ]
then
	if [ -z "$sudo_password" ]; then
		if [ -f "$cfgfile" ]; then
			sudo_password=`awk '/sudo_password/{print $3}' $cfgfile|sed -e "s#\('\)\(.*\)\(',\)#\2#"`
		fi
	fi
	echo "#######################################################################"
	echo ""
	echo "OGP agent uses basic encryption to prevent unauthorized users from connecting"
	echo "Enter a string of alpha-numeric characters for example 'abcd12345'"
	echo "**** NOTE - Use the same key in your Open Game Panel webpage config file - they must match *****"
	echo ""

	while [ -z "${key}" ]
	do 
		echo -n "Set encryption key: "
		read key
	done

	echo
	echo "Set the listen port for the agent. The default should be fine for everyone."
	echo "However, if you want to change it that can be done here, otherwise just press Enter."
	echo -n "Set listen port [Default ${DEFAULT_PORT}]: "
	read port

	if [ -z "${port}" ]
	then 
		port=$DEFAULT_PORT
	fi

	echo 
	echo "Set the listen IP for the agent."
	echo "Use ${DEFAULT_IP} to bind on all interfaces."
	echo -n "Set listen IP [Default ${DEFAULT_IP}]: "
	read ip

	if [ -z "${ip}" ]  
	then 
		ip=$DEFAULT_IP
	fi 

	while [ 1 ]
	do
		echo
		echo "For some games the OGP panel is using Steam client."
		echo "This client has its own license that you need to agree before continuing."
		echo "This agreement is available at http://store.steampowered.com/subscriber_agreement/"
		echo;
		echo "Do you accept the terms of Steam(tm) Subscriber Agreement?"
		echo -n "(Accept|Reject): "
		read steam_license
		
		if [ "$steam_license" == "Accept" -o "$steam_license" == "Reject" ]
		then	 
			break;
		fi
		
		echo "You need to type either 'Accept' or 'Reject'.";
	done

	echo "Writing Config file - $cfgfile"

	echo "%Cfg::Config = (
	logfile => '${agent_home}/ogp_agent.log',
	listen_port  => '${port}',
	listen_ip => '${ip}',
	version => '${AGENT_VERSION}',
	key => '${key}',
	steam_license => '${steam_license}',
	sudo_password => '${sudo_password}',
	);" > $cfgfile
	
	if [ $? != 0 ]
	then
		failed "Failed to write config file."
	fi 

	echo;
	while [ 1 ]
	do
		echo "The agent should be updated when the service is restarted or started?"
		echo -n "(yes|no) [Default yes]: "
		read auto_update
		if [ "${auto_update}" == "yes" -o "${auto_update}" == "no" -o -z "${auto_update}" ]
		then 
			if [ "${auto_update}" == "yes" ]
			then
				autoUpdate=1
			elif [ -z "${auto_update}" ]
			then
				autoUpdate=1
			else
				autoUpdate=0
			fi
			break;
		fi
		echo "You need to type 'yes', 'no' or leave empty for default value [yes].";
	done

	echo;
	while [ 1 ]
	do
		echo "The agent should backup the server log files in the game server directory?"
		echo -n "(yes|no) [Default yes]: "
		read log_local_copy
		if [ "${log_local_copy}" == "yes" -o "${log_local_copy}" == "no" -o -z "${log_local_copy}" ]
		then 
			if [ "${log_local_copy}" == "yes" ]
			then
				logLocalCopy=1
			elif [ -z "${log_local_copy}" ]
			then
				logLocalCopy=1
			else
				logLocalCopy=0
			fi
			break;
		fi
		echo "You need to type 'yes', 'no' or leave empty for default value [yes].";
	done

	echo;
	echo "After how many days should be deleted the old backups of server's logs?"
	echo -n "[Default 30]: "
	read delete_logs_after
	case ${delete_logs_after} in
		''|*[!0-9]*) deleteLogsAfter=30 ;;
		*) deleteLogsAfter=${delete_logs_after} ;;
	esac

	echo;
	while [ 1 ]
	do
		echo "The agent should automatically restart game servers if they crash?"
		echo -n "(yes|no) [Default yes]: "
		read auto_restart
		if [ "${auto_restart}" == "yes" -o "${auto_restart}" == "no" -o -z "${auto_restart}" ]
		then 
			if [ "${auto_restart}" == "yes" ]
			then
				autoRestart=1
			elif [ -z "${auto_restart}" ]
			then
				autoRestart=1
			else
				autoRestart=0
			fi
			break;
		fi
		echo "You need to type 'yes', 'no' or leave empty for default value [yes].";
	done

	echo;
	echo "What mirror you want to use for updating the agent?: "
	echo;
	echo "1  - SourceForge, Inc. (Chicago, Illinois, US)"
	echo "2  - AARNet (Melbourne, Australia, AU)"
	echo "3  - CityLan (Moscow, Russian Federation, RU)"
	echo "4  - Free France (Paris, France, FR)"
	echo "5  - garr.it (Ancona, Italy, IT)"
	echo "6  - HEAnet (Ireland, IE)"
	echo "7  - HiVelocity (Tampa, FL, US)"
	echo "8  - Internode (Adelaide, Australia, AU)"
	echo "9  - Japan Advanced Institute of Science and Technology (Nomi, Japan, JP)"
	echo "10 - kaz.kz (Almaty, Kazakhstan, KZ)"
	echo "11 - University of Kent (Canterbury, United Kingdom, GB)"
	echo "12 - NetCologne (K&ouml;ln, Germany, DE)"
	echo "13 - Optimate-Server (Germany, DE)"
	echo "14 - Softlayer (Dallas, TX, US)"
	echo "15 - SURFnet (Zurich, Switzerland, CH)"
	echo "16 - SWITCH (Zurich, Switzerland, CH)"
	echo "17 - Centro de Computacao Cientifica e Software Livre (Curitiba, Brazil, BR)"
	read setmirror
	case ${setmirror} in
		1) mirror="master"
		;;
		2) mirror="aarnet"
		;;
		3) mirror="citylan"
		;;
		4) mirror="freefr"
		;;
		5) mirror="garr"
		;;
		6) mirror="heanet"
		;;
		7) mirror="hivelocity"
		;;
		8) mirror="internode"
		;;
		9) mirror="jaist"
		;;
		10) mirror="kaz"
		;;
		11) mirror="kent"
		;;
		12) mirror="netcologne"
		;;
		13) mirror="optimate"
		;;
		14) mirror="softlayer-dal"
		;;
		15) mirror="surfnet"
		;;
		16) mirror="switch"
		;;
		17) mirror="ufpr"
		;;
		*) mirror="master"
		;;
	esac

	if [ "$(uname -o)" != "Cygwin" ]; then
		echo;
		while [ 1 ]
		do
			echo "Should Open Game Panel create and manage FTP accounts?"
			echo -n "(yes|no) [Default yes]: "
			read manage_ftp
			if [ "${manage_ftp}" == "yes" -o "${manage_ftp}" == "no" -o -z "${manage_ftp}" ]
			then
				if [ "${manage_ftp}" == "yes" ]
				then
					ogpManagesFTP=1
				elif [ -z "${manage_ftp}" ]
				then
					ogpManagesFTP=1
				else
					ogpManagesFTP=0
				fi
				break;
			fi
			echo "You need to type 'yes', 'no' or leave empty for default value [yes].";
		done

		echo;
		# Only ask these install questions if users want OGP to manage FTP accounts    
		if [ "$ogpManagesFTP" == "1" ]
		then
			while [ 1 ]
			do
				echo "If you are running ISPConfig 3 in this machine the agent"
				echo "can use it to create FTP accounts instead of using Pure-FTPd."
				echo "Would you like to configure this agent to use the API of ISPConfig 3?"
				echo -n "(yes|no) [Default no]: "
				read IspConfig
				if [ "${IspConfig}" == "yes" -o "${IspConfig}" == "no" -o -z "${IspConfig}" ]
				then
					if [ "${IspConfig}" == "yes" ]
					then
						ftpMethod="IspConfig"
					else
						IspConfig="no"
					fi
					break;
				fi
				echo "You need to type 'yes', 'no' or leave empty for default value [no].";
			done
			
			if [ "${IspConfig}" == "yes" ]
			then
				while [ 1 ]
				do
					echo "Do you use HTTPS to access to your ISPConfig 3 Panel?"
					echo -n "(yes|no) [Default no]: "
					read https
					if [ "${https}" == "yes" -o "${https}" == "no" -o -z "${https}" ]
					then
						if [ "${https}" == "yes" ]
						then
							secure="s"
						else
							secure=""
						fi
						break;
					fi
					echo "You need to type 'yes', 'no' or leave empty for default value [no].";
				done
				
				echo -n "What port do you use to connect to your ISPConfig 3 Panel? [Default 8080]: "
				read setport
				case ${setport} in
					''|*[!0-9]*) port=8080 ;;
					*) port=${setport} ;;
				esac
				
				echo -n "Enter an user name to sing in remotelly (Remote user): "
				read remote_login_username

				echo -n "Enter password (Remote user): "
				read remote_login_password
				
				echo -e "<?php\n\$username = '${remote_login_username}';" > ${agent_home}/IspConfig/soap_config.php
				echo "\$password = '${remote_login_password}';" >> ${agent_home}/IspConfig/soap_config.php
				echo "\$soap_location = 'http${secure}://127.0.0.1:${port}/remote/index.php';" >> ${agent_home}/IspConfig/soap_config.php
				echo -e "\$soap_uri = 'http${secure}://127.0.0.1:${port}/remote/';\n?>" >> ${agent_home}/IspConfig/soap_config.php
				
			else
			
				while [ 1 ]
				do
					echo;
					echo "If you have installed the Easy Hosting Control Panel (EHCP - www.ehcp.net),"
					echo "the agent can use it to create FTP accounts instead of using Pure-FTPd."
					echo "Would you like to configure this agent to use the API of EHCP?"
					echo -n "(yes|no) [Default no]: "
					read ehcp
					if [ "${ehcp}" == "yes" -o "${ehcp}" == "no" -o -z "${ehcp}" ]
					then 
						if [ "${ehcp}" == "yes" ]
						then
							ftpMethod="EHCP"
						fi
						break;
					fi
					echo "You need to type 'yes', 'no' or leave empty for default value [no].";
				done
				
				if [ "${ehcp}" == "yes" ]
				then
					echo "Please enter the MySQL database password for the ehcp user"
					echo -n "(created during the install of EHCP): "
					read ehcpDB
						
					ehcpConf=${agent_home}/EHCP/config.php
					sed -i "s/changeme/${ehcpDB}/" $ehcpConf
				else
					ftpMethod="PureFTPd"
				fi
			fi
		else
			ftpMethod=""
		fi
	else
		ftpMethod="PureFTPd"
	fi

	echo "Writing Preferences file - $prefsfile"

	echo "%Cfg::Preferences = (
		screen_log_local => '${logLocalCopy}',
		delete_logs_after => '${deleteLogsAfter}',
		ogp_manages_ftp => '${ogpManagesFTP}',
		ftp_method => '${ftpMethod}',
		ogp_autorestart_server => '${autoRestart}',
		);" > $prefsfile 

		if [ $? != 0 ]
		then
			failed "Failed to write preferences file."
		fi

	echo "Writing bash script preferences file - $bashprefsfile"
	
	echo -e "agent_auto_update=${autoUpdate}\nsf_update_mirror=${mirror}" > $bashprefsfile
	
	if [ $? != 0 ]
	then
		failed "Failed to write MISC configuration file used by bash scripts."
	fi
fi
