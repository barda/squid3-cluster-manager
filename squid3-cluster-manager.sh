#!/bin/bash

function __frontend_configfile {
	ls -1 /etc/squid3/squid-??-frontend*.conf | tail -1
}

function add {
	declare -i available_backend_configs=`ls -1 /etc/squid3/squid-??-backend*.conf | wc -l`
	if [ $available_backend_configs -lt 1 ]; then
		echo "I cannot create a backend without an example configuration" >&2
		exit 3
	fi

	frontend_configfile=`__frontend_configfile`
	if [ ! -f "$frontend_configfile" ]; then
		echo "Frontend config file not found" >&2
		exit 4
	fi

	lastconffile=`ls /etc/squid3/squid-??-backend*.conf | sort | tail -1`
	declare -i lastnum=`echo $lastconffile | egrep -o '([0-9]+)'.conf  | cut -d. -f1`
	config_prefix=`echo $lastconffile | egrep -o '([0-9]+)-backend' | cut -d'-' -f1`
	oldname="backend$lastnum"

	declare -i nextnum
	let nextnum=$lastnum+1

	name="backend$nextnum"
	port=400$nextnum
	configfile="/etc/squid3/squid-$config_prefix-$name.conf"
	cache_dir="/var/spool/squid3/$name/"

	cp -i $lastconffile $configfile
	sed -i $configfile \
		-e "s/http_port 127.0.0.1:.*/http_port 127.0.0.1:$port/" \
		-e "s/visible_hostname $oldname/visible_hostname $name/" \
		-e "s/unique_hostname $oldname/unique_hostname $name/" \
		-e "s/cache_dir aufs \/var\/spool\/squid3\/$oldname/cache_dir aufs \/var\/spool\/squid3\/$name/" \
		-e "s/access_log \/var\/log\/squid3\/$oldname-access.log/access_log \/var\/log\/squid3\/$name-access.log/" \
		-e "s/cache_log \/var\/log\/squid3\/$oldname-cache.log/cache_log \/var\/log\/squid3\/$name-cache.log/" \
		-e "s/pid_filename \/var\/run\/squid3-$oldname.pid/pid_filename \/var\/run\/squid3-$name.pid/"

	if [ ! -d "$cache_dir" ]; then
		mkdir "$cache_dir"
	fi
	chown proxy. "$cache_dir"

	squid3 -z "$cache_dir" -f $configfile &>/dev/null
  __instance_handler 'start' "$name" "$configfile"

	# not so simple do not use $oldname because involve append only on first occurrence with sed
	sed -i "$frontend_configfile" \
		-e "/cache_peer.*name=$oldname/a cache_peer localhost parent $port 0 carp login=PASS name=$name"
  __instance_handler 'restart' 'frontend' "$frontend_configfile"
}

function remove {
	declare -i num=$1

	configfile=`ls /etc/squid3/squid-??-backend$num.conf 2>/dev/null`
	if [ ! -f "$configfile" ]; then
		echo "Backend '$num' not found" >&2
		exit 2
	fi

	declare -i available_backend_configs=`ls -1 /etc/squid3/squid-??-backend*.conf | wc -l`
	if [ $available_backend_configs -lt 2 ]; then
		echo "I dont allow to remove the last backend '$num'" >&2
		exit 3
	fi

	frontend_configfile=`__frontend_configfile`
	if [ ! -f "$frontend_configfile" ]; then
		echo "Frontend config file not found" >&2
		exit 4
	fi

	config_prefix=`echo $configfile | egrep -o '([0-9]+)-backend' | cut -d'-' -f1`

	name="backend$num"
	configfile="/etc/squid3/squid-$config_prefix-$name.conf"
	cache_dir="/var/spool/squid3/$name/"

  __instance_handler 'stop' "$name" "$configfile"
	rm "$configfile"

	sed -i "$frontend_configfile" \
		-e "/cache_peer.*name=$name/d"
  __instance_handler 'restart' 'frontend' "$frontend_configfile"

	really=''
	while true; do
		read -p "Really remove cache_dir '$cache_dir'? (y|n) " really
		case $really in
			y|Y)
				rm -rf "$cache_dir"
				break
				;;
			n|N)
				break
				;;
		esac
	done
}

function __instance_handler {
  action_name=$1
  instance_name=$2
	configfile=$3

  if [ $action_name = 'start' ]; then
    action="$START_HANDLER"
  elif [ $action_name = 'stop' ]; then
    action="$STOP_HANDLER"
  elif [ $action_name = 'restart' ]; then
    action="$RESTART_HANDLER"
  fi

	$action squid3-cluster-instance NAME="$instance_name" SQUID_ARGS='-YC' CONFIG="$configfile" >/dev/null
}

function list {
	$INIT_HANDLER list | grep squid3-cluster-instance | sort
}

function __frontend_is_up {
	$INIT_HANDLER list | grep squid3-cluster-instance | grep frontend
}

function usage {
	cat <<E
$0
-l: node list
-a: add a backend node
-r backend_num: remove a backend node by its number
-C: squid config directory
-K: squid config skeleton directory
E
}

function exit_1_if_action_already_defined {
  if [ ! -z "$ACTION" ]; then
    echo 'Too actions defined' >&2
    exit 1
  fi
}

ACTION=''
CONF_DIR='/etc/squid3'
SKELETON_DIR='/var/share/squid3-cluste3-manager/skel'
ACTION_ARGS=''

INIT_HANDLER=`which initctl`
START_HANDLER=`which start`
STOP_HANDLER=`which stop`
RESTART_HANDLER=`which restart`

if [ -z "$INIT_HANDLER" ] || [ -z "$START_HANDLER" ] || [ -z "$STOP_HANDLER" ] || [ -z "$RESTART_HANDLER" ]; then
		echo "You must be root. If you are root maybe 'initctl', 'start', 'stop' or 'restart' are not in path or the system do not use Upstart" >&2
		usage
		exit 1
fi

while getopts ":alhr:C:K:" opt; do
	case $opt in
	a)
    exit_1_if_action_already_defined
    ACTION='add'
    ACTION_ARGS=''
		;;
	r)
    exit_1_if_action_already_defined
    ACTION='remove'
    ACTION_ARGS="$OPTARG"
    ;;
  l)
    exit_1_if_action_already_defined
    ACTION='list'
    ;;
	h)
		usage
		;;
	C)
		CONF_DIR="$OPTARG"
		;;
	K)
		SKELETON_DIR="$OPTARG"
		;;
  \?)
		echo "Invalid option '-$OPTARG'" >&2
		usage
		exit 1
		;;
	:)
		echo "Missing required argument for option '-$OPTARG'" >&2
		usage
		exit 1
		;;
	*)
		echo "Unimplemented option '-$OPTARG'" >&2
		exit 1
		;;
	esac
done

if [ -z "$ACTION" ]; then
  echo "Please specify an action: list, add or remove" >&2
  exit 1
fi

if [ ! -d "$CONF_DIR" ]; then
  echo "Squid config directory '$CONF_DIR' not found" >&2
  exit 1
fi

if [ ! -d "$SKELETON_DIR" ]; then
  echo "Squid config scheleton directory '$SKELETON_DIR' not found" >&2
  exit 1
fi

if [ "$ACTION" = 'list' ]; then
  list "$ACTION_ARGS"
elif [ "$ACTION" = 'add' ]; then
  add "$ACTION_ARGS"
elif [ "$ACTION" = 'remove' ]; then
  remove "$ACTION_ARGS"
fi

exit 0
