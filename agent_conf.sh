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

####################
#    FUNCTIONs     #
####################

function indexOf(){ 
	# $1 = search string
	# $2 = string or char to find
	# Returns -1 if not found
	x="${1%%$2*}"
	[[ $x = $1 ]] && echo -1 || echo ${#x}
}

#####################
#    CODE  ##########
#####################

if [ $EUID -ne 0 -a "$(uname -o)" != "Cygwin" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

usage()
{
cat << EOF

Usage: $0 option

OPTIONS:
   -s password       Set the password for the agent's user (Linux)
   -p password       Set the password for cyg_server user (Windows)
   -u ogpuser        Set the username of the ogp user
EOF
}

while getopts "hs:p:u" OPTION
do
     case $OPTION in
         s)
             sudo_password=$OPTARG
             ;;
         p)
             cs_psw=$OPTARG
             ;;
		 u)
             agent_user=$OPTARG
             ;;
            
         ?)
             exit
             ;;
     esac
done

if [ -z $1 ]
then
   usage
   exit
fi

if [ "$(uname -o)" == "Cygwin" ]; then
   if [ -z $cs_psw ]
   then
      echo "Must use -p argument instead of -s."
      exit
   fi
else
   if [ -z $sudo_password ]
   then
      echo "Must use -s argument instead of -p."
      exit
   fi
fi

readonly DEFAULT_PORT=12679
readonly DEFAULT_IP=0.0.0.0
readonly DEFAULT_FTP_PORT=21
readonly DEFAULT_FTP_PASV_RANGE=40000:50000
readonly AGENT_VERSION='v1.4'

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
if [ -e ${cfgfile} ]; then
	while [ 1 ]
	do
		echo "Overwrite old configuration?"
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
			echo "You need to type 'yes', 'no' or leave empty for default value [yes]."
		fi
	done
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
		
		echo "You need to type either 'Accept' or 'Reject'."
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
	web_admin_api_key => '{your_admin_ogp_web_api_key_here}',
	web_api_url => '{your_url_to_ogp_api.php}',
	steam_dl_limit => '0',
	);" > $cfgfile
	
	if [ $? != 0 ]
	then
		failed "Failed to write config file."
	else
		chmod 600 ${cfgfile} || failed "Failed to chmod ${cfgfile} to 600."
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
		echo "You need to type 'yes', 'no' or leave empty for default value [yes]."
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
		echo "You need to type 'yes', 'no' or leave empty for default value [yes]."
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
		echo "You need to type 'yes', 'no' or leave empty for default value [yes]."
	done
	
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
		echo "You need to type 'yes', 'no' or leave empty for default value [yes]."
	done

	echo;
	# Only ask these install questions if users want OGP to manage FTP accounts    
	if [ "$ogpManagesFTP" == "1" ]
	then
		if [ "$(uname -o)" != "Cygwin" ]; then
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
				echo "You need to type 'yes', 'no' or leave empty for default value [no]."
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
					echo "You need to type 'yes', 'no' or leave empty for default value [no]."
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
					echo "If you have installed the Easy Hosting Control Panel (EHCP - www.ehcpforce.tk),"
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
					echo "You need to type 'yes', 'no' or leave empty for default value [no]."
				done
				
				if [ "${ehcp}" == "yes" ]
				then
					echo "Please enter the MySQL database password for the ehcp user"
					echo -n "(created during the install of EHCP): "
					read ehcpDB
						
					ehcpConf=${agent_home}/EHCP/config.php
					sed -i "s/changeme/${ehcpDB}/" $ehcpConf
				else
					while [ 1 ]
					do
						echo;
						echo "The agent can use ProFTPd to create FTP accounts."
						echo "Would you like to configure this agent to use the ProFTPd?"
						echo -n "(yes|no) [Default no]: "
						read proftpd
						if [ "${proftpd}" == "yes" -o "${proftpd}" == "no" -o -z "${proftpd}" ]
						then 
							if [ "${proftpd}" == "yes" ]
							then
								ftpMethod="proftpd"
							fi
							break;
						fi
						echo "You need to type 'yes', 'no' or leave empty for default value [no]."
					done
					
					if [ "${proftpd}" == "yes" ]
					then
						echo "Please enter the path for proFTPd configuration file"
						echo -n "[Default /etc/proftpd/proftpd.conf]: "
						read proFTPdConfFile
						if [ -z $proFTPdConfFile ]
						then
							proFTPdConfFile="/etc/proftpd/proftpd.conf"
							if [ ! -e "$proFTPdConfFile" ]; then
								proFTPdConfFile="/etc/proftpd.conf"
							fi
						fi
						proFTPdConfPath=$(dirname ${proFTPdConfFile})
						while [ 1 ]
						do
							if [ ! -e $proFTPdConfFile ]
							then
								echo "The file ${proFTPdConfFile} does not exists,"
								echo "what you want to do, reenter it or ignore and continue?"
								echo "If your answer is 'ignore' is meant that you will install proFTPd later."
								echo -n "(reenter|ignore): "
								read answer
								if [ "${answer}" == "reenter" -o "${answer}" == "ignore" ]
								then 
									if [ "${answer}" == "reenter" ]
									then
										echo "Reenter proFTPd's configuration file path:"
										read proFTPdConfFile
										continue
									elif [ "${answer}" == "ignore" ]
									then
										echo "You will need to append this to ${proFTPdConfFile} once you've installed proftpd:"
										bold=`tput bold`
										normal=`tput sgr0`
										echo -e "\n\n${bold}RequireValidShell  off\nAuthUserFile  ${proFTPdConfPath}/ftpd.passwd\nAuthGroupFile ${proFTPdConfPath}/ftpd.group${normal}\n\n"
										break
									fi
								fi
								echo "You need to type 'reenter' or 'ignore'."
							else							
								if egrep -iq "LoadModule\s*mod_auth_file.c" ${proFTPdConfFile}
								then
									sed -i "s/\s*#\s*LoadModule\s*mod_auth_file.c/LoadModule  mod_auth_file.c/g" ${proFTPdConfFile}
								else
									echo -e "LoadModule  mod_auth_file.c" >> ${proFTPdConfFile}
								fi
								
								if egrep -iq "^\s*AuthOrder.*" ${proFTPdConfFile}
								then
									if egrep -iq "^\s*AuthOrder.*mod_auth_file.c" ${proFTPdConfFile}
									then 
										false
									else
										sed -ri "s/(^\s*AuthOrder.*)/\1 mod_auth_file.c/g" ${proFTPdConfFile}
									fi
								else
									echo -e "AuthOrder  mod_auth_file.c" >> ${proFTPdConfFile}
								fi	

								if egrep -iq "RequireValidShell.*" ${proFTPdConfFile}
								then
									sed -i "s#RequireValidShell.*#RequireValidShell  off#g" ${proFTPdConfFile}
								else
									echo -e "RequireValidShell  off" >> ${proFTPdConfFile}
								fi
								
								if egrep -iq "AuthUserFile.*" ${proFTPdConfFile}
								then
									sed -i "s#AuthUserFile.*#AuthUserFile  ${proFTPdConfPath}/ftpd.passwd#g" ${proFTPdConfFile}
								else
									echo -e "AuthUserFile  "${proFTPdConfPath}"/ftpd.passwd" >> ${proFTPdConfFile}
								fi
								
								if egrep -iq "AuthGroupFile.*" ${proFTPdConfFile}
								then
									sed -i "s#AuthGroupFile.*#AuthGroupFile ${proFTPdConfPath}/ftpd.group#g" ${proFTPdConfFile}
								else
									echo -e "AuthGroupFile "${proFTPdConfPath}"/ftpd.group" >> ${proFTPdConfFile}
								fi
								
								# Allow global overwrite (http://opengamepanel.org/forum/viewthread.php?thread_id=5202)
								if egrep -iq "AllowOverwrite.*" ${proFTPdConfFile}
								then
									sed -i "s#AllowOverwrite.*#AllowOverwrite yes#g" ${proFTPdConfFile}
								else
									echo -e "<Global>\nAllowOverwrite yes\n</Global>" >> ${proFTPdConfFile}
								fi
								
								if [ ! -e "${proFTPdConfPath}/ftpd.group" ] 
								then
									touch ${proFTPdConfPath}/ftpd.group
								fi
								
								if [ ! -e "${proFTPdConfPath}/ftpd.passwd" ] 
								then
									touch ${proFTPdConfPath}/ftpd.passwd
								fi
								ftpd_user=$(grep -oP '^User\s+\K.+' ${proFTPdConfFile})
								ftpd_group=$(grep -oP '^Group\s+\K.+' ${proFTPdConfFile})
								if [ -z "$agent_user" ]; then
									agent_user=$(grep -oP 'agent_user=\K.+' /etc/init.d/ogp_agent)
								fi
								if [ ! -z "$ftpd_user" ] && [ ! -z "$ftpd_group" ] && [ ! -z "$agent_user" ]
								then
									if [ "$(groups $agent_user|grep $ftpd_group)" == "" ]
									then
										usermod -aG $ftpd_group $agent_user
									fi
									if [ -e "${proFTPdConfPath}/ftpd.passwd" -a -e "${proFTPdConfPath}/ftpd.group" ]
									then
										chmod 640 ${proFTPdConfPath}/ftpd.*
										chown -f $ftpd_user:$ftpd_group ${proFTPdConfPath}/ftpd.*
									fi
								fi
								break
							fi
						done
						
						if [ -e "/etc/init.d/proftpd" ]
						then
							/etc/init.d/proftpd restart
						else
							echo "If proftpd is running, to apply the changes, you must restart the service."
						fi
					else
						ftpMethod="PureFTPd"
					fi
				fi
			fi
		else
			if uname -a|grep -q "x86_64"
			then 
				FZ="yes"
			else
				while [ 1 ]
				do
					echo;
					echo "If you have installed the FileZilla Server,"
					echo "the agent can use it to create FTP accounts instead of using Pure-FTPd."
					echo "Would you like to configure this agent to use it?"
					echo -n "(yes|no) [Default no]: "
					read FZ
					if [ "${FZ}" == "yes" -o "${FZ}" == "no" -o -z "${FZ}" ]
					then
						break;
					fi
					echo "You need to type 'yes', 'no' or leave empty for default value [no].";
				done
			fi
			
			if [ "${FZ}" == "yes" ]; then
				ftpMethod="FZ"
				PF=$(cmd /Q /C echo %PROGRAMFILES\(X86\)% | sed 's/\r$//')
				if [ "X${PF}" == "X" ];then PF=$(cmd /Q /C echo %PROGRAMFILES% | sed 's/\r$//'); fi
				echo;
				echo "Please enter the path for FileZilla server executable file"
				echo -n "[Default ${PF}\\FileZilla Server\\FileZilla server.exe]: "
				read -r FZ_EXE
				if [ -z "${FZ_EXE}" ]
				then 
					FZ_EXE="${PF}\\FileZilla Server\\FileZilla server.exe"
				fi
				echo;
				echo "Please enter the path for FileZilla server xml file"
				echo -n "[Default ${PF}\\FileZilla Server\\FileZilla Server.xml]: "
				read -r FZ_XML
				if [ -z "${FZ_XML}" ]
				then 
					FZ_XML="${PF}\\FileZilla Server\\FileZilla server.xml"
				fi
				FZ_EXE=$(cygpath -u "$FZ_EXE")
				FZ_XML=$(cygpath -u "$FZ_XML")
				FZconf=${agent_home}/Cfg/FileZilla.pm
				echo -e "%Cfg::FileZilla = (\n\tfz_exe => '${FZ_EXE}',\n\tfz_xml => '${FZ_XML}'\n);" > ${FZconf}
				if [ $? != 0 ]
				then
					failed "Failed to write FileZilla configuration file."
				fi
				if [ ! -z "$cs_psw" ]; then
					UD=$(cmd /Q /C echo %USERDOMAIN% | sed 's/\r$//')
					net stop "FileZilla Server"
					sc config "FileZilla Server" obj= "${UD}\cyg_server" password= "$cs_psw" type= own
					net start "FileZilla Server"
				fi
			else
				if uname -a|grep -qv "x86_64"
				then
					ftpMethod="PureFTPd"
					echo;
					echo "Set the listen IP for the PureFTPd."
					echo "Default is (${DEFAULT_IP}) to bind on all interfaces."
					echo -n "Set listen IP [Default ${DEFAULT_IP}]: "
					read ftp_ip

					if [ -z "${ftp_ip}" ]  
					then 
						ftp_ip=$DEFAULT_IP
					fi
					
					echo
					echo "Set the listen port for PureFTPd. The default should be fine for everyone."
					echo "However, if you want to change it that can be done here, otherwise just press Enter."
					echo -n "Set listen port [Default ${DEFAULT_FTP_PORT}]: "
					read port

					if [ -z "${ftp_port}" ]
					then 
						ftp_port=$DEFAULT_FTP_PORT
					fi

					echo
					echo "Passive-mode downloads."
					echo "This is especially useful if the server is behind a firewall."
					echo -n "Use only ports in the range?(yes|no)[Default no]: "
					read passive_ftp

					if [ -z "${passive_ftp}" -o "${passive_ftp}" != "yes" ]
					then 
						ftp_pasv_range=""
					else
						echo "Enter passive ports range separated by colon (<first port>:<last port>)."
						echo -n "[Default ${DEFAULT_FTP_PASV_RANGE}]: "
						read ftp_pasv_range
						if [ -z "${ftp_pasv_range}" ]
						then 
							ftp_pasv_range=$DEFAULT_FTP_PASV_RANGE
						fi
					fi
				fi
			fi
		fi
	fi
	
	if [ "${ftpMethod}" == "PureFTPd" ]
	then
		run_pureftpd=1
	else
		run_pureftpd=0
	fi

	echo "Writing Preferences file - $prefsfile"

	prefs="%Cfg::Preferences = (\n"
	prefs="${prefs}\tscreen_log_local => '${logLocalCopy}',\n"
	prefs="${prefs}\tdelete_logs_after => '${deleteLogsAfter}',\n"
	prefs="${prefs}\togp_manages_ftp => '${ogpManagesFTP}',\n"
	prefs="${prefs}\tftp_method => '${ftpMethod}',\n"
	prefs="${prefs}\togp_autorestart_server => '${autoRestart}',\n"
	prefs="${prefs}\tprotocol_shutdown_waittime => '10',\n"
	prefs="${prefs}\tlinux_user_per_game_server => '1',\n"
	if [ "X${proftpd}" == "Xyes" ]
	then
		prefs="${prefs}\tproftpd_conf_path => '${proFTPdConfPath}',\n"
	fi
	prefs="${prefs});"
	echo -e $prefs > $prefsfile 

	if [ $? != 0 ]
	then
		failed "Failed to write preferences file."
	fi

	echo "Writing bash script preferences file - $bashprefsfile"
	
	echo -e "agent_auto_update=${autoUpdate}\nrun_pureftpd=${run_pureftpd}\nftp_port=${ftp_port}\nftp_ip=${ftp_ip}\nftp_pasv_range=${ftp_pasv_range}" > $bashprefsfile
	
	if [ $? != 0 ]
	then
		failed "Failed to write MISC configuration file used by bash scripts."
	fi
fi
