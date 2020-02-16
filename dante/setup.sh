#!/bin/bash

LOGIN="user"
PASSW="passw0rd"
PORT="1234"

DANTE_VERSION="1.4.2"
DANTE_DOWNLOAD_URL="https://www.inet.no/dante/files/dante-$DANTE_VERSION.tar.gz"
DANTE_CFG_PATH="/etc/sockd.conf"
DANTE_INITD_PATH="/etc/init.d/sockd"
DANTE_PATH=""
PROBE_HOST="r0.ru"

PACKAGE_MANAGER=

RED='\033[00;91m'
GREEN='\033[00;92m'
BLUE='\033[00;94m'
RESTORE='\033[0m'

function main() {
	if [[ "$EUID" -ne 0 ]]; then
		output "Please run as root" $RED
		exit 1
	fi

	if have_prog apt-get ; then
		PACKAGE_MANAGER='apt-get'

		output "Updating repo cache" $BLUE
		check_result $($PACKAGE_MANAGER update > /dev/null 2>&1) 0
	elif have_prog yum ; then 
		PACKAGE_MANAGER='yum'
	else
		output 'No package manager found!' $RED
		exit 2
	fi

	output "Adding user" $BLUE
	check_result $(useradd $LOGIN > /dev/null 2>&1) 1
	output "Setting user password" $BLUE
	check_result $(echo $LOGIN:$PASSW | chpasswd > /dev/null 2>&1) 1


	if ! have_prog sockd; then
		if ! have_prog gcc; then
			output "Installing 'gcc'" $BLUE
			check_result $($PACKAGE_MANAGER install -y gcc > /dev/null 2>&1) 1
		fi

		if ! have_prog make; then
			output "Installing 'make'" $BLUE
			check_result $($PACKAGE_MANAGER install -y make > /dev/null 2>&1) 1
		fi

		if ! have_prog wget; then
			output "Installing 'wget'" $BLUE
			check_result $($PACKAGE_MANAGER install -y wget > /dev/null 2>&1) 1
		fi
	
		output "Fetching Dante source" $BLUE
		check_result $(wget $DANTE_DOWNLOAD_URL > /dev/null 2>&1) 1

		output "Unpacking Dante" $BLUE
		check_result $(tar xf dante-$DANTE_VERSION.tar.gz > /dev/null 2>&1) 1

		output "Building Dante" $BLUE
		cd dante-$DANTE_VERSION
		
		output "--configure" $BLUE
		check_result $(./configure > /dev/null 2>&1) 1
		output "--make" $BLUE
		check_result $(make > /dev/null 2>&1) 1
		output "--make install" $BLUE
		check_result $(make install > /dev/null 2>&1) 1
	fi

	output "Getting Dante path" $BLUE
	if have_prog sockd; then
		DANTE_PATH=$(hash -t sockd)
		check_result 0 1
	else
		check_result 1 1
	fi

	output "Getting IP info" $BLUE
	HOST_IP=$(ip r get 1 | awk '{print $NF;exit}')
	result=$(ip a | grep $HOST_IP | wc -l)
	if [[ $result == "0" ]]; then
		check_result 1 1
	else
		check_result 0 1
	fi

	output "Tuning dante config" $BLUE
	check_result $(cat > $DANTE_CFG_PATH <<- EOM
	internal: 0.0.0.0 port = $PORT
	external: $HOST_IP

	clientmethod: none
	socksmethod: username
	user.notprivileged: $LOGIN

	client pass {
		from: 0.0.0.0/0 to: 0.0.0.0/0
		log: error
	}

	socks pass {  
		from: 0.0.0.0/0 to: 0.0.0.0/0
		command: bind connect udpassociate
		log: error
	}
EOM
	) 1

	output "Dropping init.d script" $BLUE
	drop_initd

	output "Tuning permissions" $BLUE
	check_result $(chmod 755 $DANTE_INITD_PATH) 0

	if have_prog systemctl; then
		systemctl daemon-reload > /dev/null 2>&1
	fi

	output "Starting service" $BLUE
	check_result $(service sockd start > /dev/null 2>&1) 1
	
	output "Checking service status" $BLUE
	result=$(ps aux | grep [s]ockd | wc -l)
	if [[ $result == "0" ]]; then
		check_result 1 0
	else
		check_result 0 0
	fi

	if have_prog firewall-cmd; then
		output "Adding to FW exceptions"
		check_result $(firewall-cmd --add-port=$PORT/tcp --permanent > /dev/null 2>&1 && firewall-cmd --reload > /dev/null 2>&1) 0
	fi
	
	if have_prog curl; then
		output "Checking proxy auth" $BLUE

		result=$(curl --max-time 5 --socks5 $LOGIN:$PASSW@$HOST_IP:$PORT/ -sL -w "%{http_code} %{url_effective}\\n" "$PROBE_HOST" -o /dev/null)
		if [[ $result == *"200"* ]]; then
			check_result 0 0
		else
			check_result 1 0
		fi
	fi
}

function have_prog() {
	if hash $1 2>/dev/null; then
		return 0;
	else
		return 1;
	fi
}

function output() {
	echo -e "$2$1$RESTORE"
}

function check_result {
	local status=$?
	local is_fatal=0

	if [ $# -eq 1 ]; then
		is_fatal=$1
	else
		status=$1
		is_fatal=$2
	fi

	if [ $status -ne 0 ]; then
		output "FAIL" $RED
		if [ $is_fatal -eq 1 ]; then
			exit
		fi
	else
		output "OK" $GREEN
	fi
}

function drop_initd {
	cat > $DANTE_INITD_PATH <<- EOM
	#!/bin/sh
	### BEGIN INIT INFO
	# Provides:          sockd
	# Required-Start:    \$remote_fs \$network \$syslog
	# Required-Stop:     \$remote_fs \$network \$syslog
	# Default-Start:     2 3 4 5
	# Default-Stop:      0 1 6
	# Description:       Proxy daemon
	### END INIT INFO

	SCRIPT=$DANTE_PATH
	CONFFILE=$DANTE_CFG_PATH
	PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
	NAME=sockd

	PIDFILE=/var/run/\$NAME.pid
	LOGFILE=/var/log/\$NAME.log

	touch_pidfile ()
	{
		if [ -r \$CONFFILE ]; then
			uid="\`sed -n -e 's/[[:space:]]//g' -e 's/#.*//' -e '/^user\.privileged/{s/[^:]*://p;q;}' \$CONFFILE\`"
			if [ -n "\$uid" ]; then
				touch \$PIDFILE
				chown \$uid \$PIDFILE
			fi
		fi
	}

	start() {
		if [ -f /var/run/\$PIDNAME ] && kill -0 \$(cat /var/run/\$PIDNAME); then
			echo 'Service already running' >&2
			return 1
		fi
		echo 'Starting service…' >&2
		touch_pidfile
		local CMD="\$SCRIPT &> \"\$LOGFILE\" & echo \$!"
		su -c "\$CMD" \$RUNAS > "\$PIDFILE"
		echo 'Service started' >&2
	}

	stop() {
		if [ ! -f "\$PIDFILE" ] || ! kill -0 \$(cat "\$PIDFILE"); then
			echo 'Service not running' >&2
			return 1
		fi
		echo 'Stopping service…' >&2
		kill -15 \$(cat "\$PIDFILE") && rm -f "\$PIDFILE"
		echo 'Service stopped' >&2
	}

	uninstall() {
		echo -n "Are you really sure you want to uninstall this service? That cannot be undone. [yes|No] "
		local SURE
		read SURE
		if [ "\$SURE" = "yes" ]; then
			stop
			rm -f "\$PIDFILE"
			echo "Notice: log file is not be removed: '\$LOGFILE'" >&2
			update-rc.d -f \$NAME remove
			rm -fv "$0"
		fi
	}

	case "\$1" in
	  start)
	    start
	    ;;
	  stop)
	    stop
	    ;;
	  uninstall)
	    uninstall
	    ;;
	  retart)
	    stop
	    start
	    ;;
	  *)
	    echo "Usage: \$0 {start|stop|restart|uninstall}"
	esac
EOM
	
	check_result 0 1
}

main "$@"
