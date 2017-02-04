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

# Parameters can be passed into the install.sh script to automate OGP updates
# $1 = Operation Type (Used as opType)
# $2 = OGP User (Used as ogpAgentUser)
# $3 = OGP User Sudo Pass (Used as ogpUserPass)
# $4 = Install Path (Used as ogpInsPath)


####################
#    FUNCTIONs     #
####################

detectSystemD(){
	# Ops require sudo
	initProcessStr=$(ps -p 1 | awk '{print $4}' | tail -n 1)
	if [ "$initProcessStr" == "systemd" ]; then
		systemdPresent=1
		if [ -e "/lib/systemd/system" ]; then
			SystemDDir="/lib/systemd/system"
		elif [ -e "/etc/systemd/system" ]; then
			SystemDDir="/etc/systemd/system"
		else
			checkDir=$(ps -eaf|grep '[s]ystemd' | head -n 1 | awk '{print $8}' | grep -o ".*systemd/")
			if [ -e "${checkDir}system" ]; then
				SystemDDir="$checkDir"
			else
					# Can't find systemd dir
				systemdPresent=
				SystemDDir=
			fi
		fi
	fi
}

copySystemDInit(){
	AGENTDIR=${agent_home}
	sudoPass=${sudo_password}
	if [ -e "${AGENTDIR}/systemd/ogp_agent.service" ]; then
		if [ ! -z "$systemdPresent" ] && [ ! -z "$SystemDDir" ]; then
			echo -e "systemd detected as the init system with a directory of $SystemDDir.  Updating OGP agent to use systemd service init script."
			if [ -e "/etc/init.d/ogp_agent" ] && [ ! -e "${AGENTDIR}/ogp_agent_init" ]; then
				echo -e "Taking care of existing OGP files."
				echo "$sudoPass" | sudo -S -p "" service ogp_agent stop
				# Kill any remaining ogp agent process
				ogpPID=$(ps -ef | grep -v grep | grep ogp_agent.pl | head -n 1 | awk '{print $3}')
				if [ ! -z "$ogpPID" ]; then
					echo "$sudoPass" | sudo -S -p "" kill -9 "$ogpPID"
				fi
				echo "$sudoPass" | sudo -S -p "" cp "/etc/init.d/ogp_agent" "${AGENTDIR}/ogp_agent_init"
				echo "$sudoPass" | sudo -S -p "" chmod +x "${AGENTDIR}/ogp_agent_init"
				echo "$sudoPass" | sudo -S -p "" update-rc.d ogp_agent disable
				echo "$sudoPass" | sudo -S -p "" chkconfig ogp_agent off
				echo "$sudoPass" | sudo -S -p "" rm -rf "/etc/init.d/ogp_agent"
			fi
			if [ ! -e "$SystemDDir/ogp_agent.service" ]; then
				echo -e "Copying ogp_agent systemd service file to $SystemDDir"
				echo "$sudoPass" | sudo -S -p "" cp "${AGENTDIR}/systemd/ogp_agent.service" "$SystemDDir"
				echo "$sudoPass" | sudo -S -p "" sed -i "s#{OGP_AGENT_PATH}#$AGENTDIR#g" "${SystemDDir}/ogp_agent.service"
			fi
		fi
	fi
}

#####################
#    CODE  ##########
#####################

# Parameter notifications
if [ ! -z "$1" ]; then
	echo -n "Received operation type of $1 as a parameter."
	opType="$1"
fi

if [ ! -z "$2" ]; then
	echo -n "Received OGP user of $2 as a parameter."
	ogpAgentUser="$2"
fi 

if [ ! -z "$3" ]; then
	echo -n "Received OGP sudo password of $3 as a parameter."
	ogpUserPass="$3"
fi 

if [ ! -z "$4" ]; then
	echo -n "Received OGP agent path of $4 as a parameter."
	ogpInsPath="$4"
fi

failed()
{
	echo "ERROR: ${1}"
	exit 1
}

if [ "X`which screen &> /dev/null;echo $?`" != "X0" ]; then
    failed "You need to install software called 'screen', before you can install OGP agent.";
fi

if [ "X`which sed &> /dev/null;echo $?`" != "X0" ]; then
    failed "You need to install software called 'sed', before you can install OGP agent.";
fi
echo
clear
echo "#######################################################################"
echo "# OGP Agent installation and configuration"
echo "# This program will:"
echo "# Create ${DEFAULT_AGENT_HOME} or user defined directory"
echo "# Copy ogp_agent files to ${DEFAULT_AGENT_HOME} or user defined dir"
echo "# Copy the ogp_agent init script to /etc/init.d or user defined dir"
echo "# Create an initial configuration file"
echo "# Thank you for using OGP. http://www.opengamepanel.org/"
echo "#######################################################################"
echo 


if [ "X`which rsync &> /dev/null;echo $?`" != "X0" ]; then
    echo "*** WARNING **** missing rsync client. It is not required, but needed to use the rsync game installer";
fi

if [ "X`whoami`" != "Xroot" ]
then 
    echo
    echo "Detected non-root install..."
    username=`whoami`
	echo -n "Enter sudo password: ";
    read sudo_password;
else
    echo "Next you need to type the username of the user that owns the agent homes.";
    echo "This user must own (have access to) all the game home directories that you"
    echo "want to run with this agent and must to be in sudoers list so it can perform"
	echo "administrative tasks.";echo
    while [ 1 ]
    do
		if [ ! -z "$ogpAgentUser" ] ; then
			username="$ogpAgentUser"
		else
			echo -n "Enter user name: ";
			read username;
        fi
		
		if [ -z "$ogpUserPass" ] ; then
			echo -n "Enter user password: ";
			read sudo_password;
		else
			sudo_password="$ogpUserPass"
		fi

        if [ -z "${username}" ]
        then
            echo "Username can not be empty.";echo
            continue;
        fi

        if [ "Xroot" == "X${username}" ]
        then
            echo "'${username}' can not be used as user for agent.";echo
            continue;
        fi

        ID_OF_USER=`id -u ${username} 2> /dev/null`
        if [ $? != 0 ]
        then
            echo "User with entered username (${username}) does not exist.";echo
            continue;
        fi

        break;
    done
fi

detectSystemD

readonly AGENT_USER_HOME="`cat /etc/passwd | grep "^${username}:" | cut -d':' -f6`/OGP/"

echo
echo "Next the directory for the agent needs to be chosen. The default directory";
echo "Should be fine in most of the cases."
echo

if [ -z "$ogpInsPath" ]; then
	echo "Where do you want to install the agent?"
	echo -n "[Default is ${AGENT_USER_HOME}]: "
	read agent_home
else
	agent_home="$ogpInsPath"
fi

if [ -z "${agent_home}" ]  
then 
    agent_home=$AGENT_USER_HOME
fi

# Try to prevent users from doing damage to their systems.
case ${agent_home} in
    /bin*|/boot*|/dev*|/etc*|/lib*|/proc*|/root*|/sbin*|/sys*|/)
        failed "The agent home can not be ${agent_home}";
        ;;
esac

echo "Agent install dir is ${agent_home}"
echo
agent_home=${agent_home%/}

if [ ! -e ${agent_home} ]
then 
    mkdir -p ${agent_home} || failed "Failed to create the directory (${agent_home}) for agent."
elif [ ! -w ${agent_home} ]
then
    failed "You do not have write permissions to the directory you assigned as agent home (${agent_home})."
fi

if [ "X`whoami`" == "Xroot" ];
then
    readonly DEFAULT_INIT_DIR="/etc/init.d/"
else
    readonly DEFAULT_INIT_DIR="${agent_home}/"
fi

if [ -z "$systemdPresent" ]; then

	if [ "X`uname`" != "XLinux" ]
	then 
		echo
		echo "Detected non-Linux platform..."
		echo "Where do you want to put the init scripts?"
		echo -n "[Default ${DEFAULT_INIT_DIR}]: "
		read init_dir
	fi

	if [ -z "$opType" ]; then
		echo "Where do you want to put the init scripts?"
		echo -n "[Default ${DEFAULT_INIT_DIR}]:"
		read init_dir
	fi

else
	init_dir=${agent_home}
fi

if [ -z "${init_dir}" ]  
then 
    init_dir=${DEFAULT_INIT_DIR}
fi
init_dir=${init_dir%/}
echo "Copying files..."

cp -avf systemd Crypt EHCP FastDownload File Frontier IspConfig KKrcon php-query Schedule Time ogp_agent.pl ogp_screenrc ogp_agent_run agent_conf.sh extPatterns.txt ${agent_home}/ || failed "Failed to copy agent files to ${agent_home}."

# Create the directory for configs.
mkdir -p ${agent_home}/Cfg || failed "Failed to create ${agent_home}/Cfg dir."
echo

if [ -e /etc/gentoo-release ] 
then
    echo "Copying ogp_agent.init.gentoo to $init_dir - Gentoo Specific Init"
    init_file_template='includes/ogp_agent.init.gentoo' 
elif [ -e /etc/sysconfig ] && [ ! -e /etc/debian_version ]
then
    echo "Copying ogp_agent.init.rh to $init_dir - Redhat Style Init (also SuSE, and Mandrake)"
    init_file_template='includes/ogp_agent.init.rh' 
elif [ -e /etc/debian_version ]
then
    echo "Copying ogp_agent.init.dbn to $init_dir - Debian Style Init"
    init_file_template='includes/ogp_agent.init.dbn'
else
    echo "Copying the generic init script because I don't know what kind of Linux distro this is"
    init_file_template='includes/ogp_agent.init'
fi

init_file=${init_dir}/ogp_agent

cp -f $init_file_template $init_file || failed "Failed to create init file ($init_file)."
# Next we replace the OGP_AGENT_DIR with the actual dir in init file.
sed -i "s|OGP_AGENT_DIR|${agent_home}|" ${init_file} || failed "Failed to modify init file ($init_file)."
sed -i "s|OGP_USER|${username}|" ${init_file} || failed "Failed to modify init file ($init_file)."
chmod a+x $init_file

if [ "$init_dir" == "$agent_home" ] && [ ! -z "$systemdPresent" ]; then
	init_file=${init_dir}/ogp_agent_init
	mv ${init_dir}/ogp_agent ${init_dir}/ogp_agent_init
	copySystemDInit
fi

echo;

echo "Changing files owner to user ${username}...";
# Group of the files in agent_home can differ from the user so 
# lets leave them as they are. So no chown user:group here.
chown --preserve-root -R ${username} ${agent_home} || failed "Failed to chmod the agent_home ${agent_home} for user ${username}."

echo "Setting Permissions on files in ${agent_home}..."
if [ -e "${init_dir}/ogp_agent" ]; then
	chmod 750 ${init_dir}/ogp_agent || failed "Failed to chmod ${init_dir}/ogp_agent to 750."
fi
if [ -e "${init_dir}/ogp_agent_init" ]; then
	chmod 750 ${init_dir}/ogp_agent_init || failed "Failed to chmod ${init_dir}/ogp_agent_init to 750."
fi
chmod 750 ${agent_home}/ogp_agent.pl || failed "Failed to chmod ${agent_home}/ogp_agent.pl to 750."
chmod 750 ${agent_home}/ogp_agent_run || failed "Failed to chmod ${agent_home}/ogp_agent_run to 750."

echo "Install Successful!"
echo "Now configuring..."
echo ""

# Run the configuration script
chmod +x ${agent_home}/agent_conf.sh

if [ -z "$opType" ]; then
	bash ${agent_home}/agent_conf.sh -s $sudo_password -u $username
fi

echo "Attempting to start the Open Game Panel (OGP) agent..."  

systemctl daemon-reload
chkconfig ogp_agent on
rc-update add ogp_agent default
update-rc.d ogp_agent defaults
systemctl enable ogp_agent.service
service ogp_agent restart

echo;
echo "OGP installation complete!"  
echo 

exit 0
