#!/bin/sh
# Backup routine to execute borg backups.
# Should be started with the wrapper script borgcron.sh.
#
# LICENSE: MIT license, see LICENSE.md
#

BORG_BIN="borg"
LAST_BACKUP_DIR="/var/log/borg/last"
RUN_PID_DIR="/var/run/borg"

# default settings for backup
# (can be overwritten by config files)
COMPRESSION="lz4"
ADD_BACKUP_PARAMS=""
SLEEP_TIME="5m"
REPEAT_NUM="3"

# log system
log_line() {
	echo "[$( date +'%F %T' )]"
}
info_log() {
	echo "$( log_line ) $*" >&1
}
error_log() {
	echo "$( log_line ) $*" >&2
}

is_lock() {
	# check if locking system is disabled
	if [ "$RUN_PID_DIR" = "" ]; then
		return 1 # not locked
	fi

	# when file is not present -> unlocked
	if [ ! -f "$RUN_PID_DIR/BORG_$BACKUP_NAME.pid" ]; then
		return 1 # false
	fi
	# when PID listed in file is not running -> unlocked
	if ! pgrep -F "$RUN_PID_DIR/BORG_$BACKUP_NAME.pid" > /dev/null; then
		return 1 # false
	fi

	return 0 # true, locked
}
do_lock() {
	# check if locking system is disabled
	if [ "$RUN_PID_DIR" = "" ]; then
		return
	fi

	if [ ! -d "$RUN_PID_DIR" ]; then
		mkdir -p "$RUN_PID_DIR" || exit 2
	fi

	# write PID into file
	echo $$ > "$RUN_PID_DIR/BORG_$BACKUP_NAME.pid" || exit 2

	if ! is_lock; then
		error_log "Locking was not successful. Cancel."
		exit 2
	fi
}
rm_lock() {
	# check if locking system is disabled
	if [ "$RUN_PID_DIR" = "" ]; then
		return
	fi

	rm "$RUN_PID_DIR/BORG_$BACKUP_NAME.pid"
}

# add trap to catch backup interruptions
trapterm() {
    rm_lock 2> /dev/null
    error_log "Backup $BACKUP_NAME (PID: $$) interrupted by $1."
    exit 2
}
trap 'trapterm INT' INT
trap 'trapterm TERM' TERM

# abort, if started without backup config file as input
if [ "$1" != '' ]; then
	# shellcheck source=config/example-backup.sh
	. "$1"
else
	echo "Please pass a path of a config file to $(basename "$0")."
	exit 1
fi

# check lock
if is_lock; then
	error_log "Backup $BACKUP_NAME is locked. Prevent start."
	exit 1
fi

# check that variables are set
if [ "$BACKUP_NAME" = "" ] ||
   [ "$BORG_REPO" = "" ] ||
   [ "$ARCHIVE_NAME" = "" ] ||
   [ "$BACKUP_DIRS" = "" ]; then
	echo 'Some required variables may not be set in the config file. Cancel backup.'
	exit 1
fi
if ! export|grep "BORG_REPO"; then
	echo 'The BORG_REPO variable is not exported in the config file. Cancel backup.'
	exit 1
fi

# log
echo
info_log "Backup $BACKUP_NAME started with $( borg -V ), PID: $$."

for i in $( seq "$REPEAT_NUM" ); do
	if is_lock; then
		error_log "Backup $BACKUP_NAME is locked. Cancel."
		exit 1
	fi

	if [ "$i" -gt 1 ]; then
		info_log "$i. try…"
	fi

	# add local lock
	do_lock

	# backup dir (some variables intentionally not quoted)
	# shellcheck disable=SC2086
	$BORG_BIN create -v --stats \
		--compression "$COMPRESSION" \
		$ADD_BACKUP_PARAMS \
		"::$ARCHIVE_NAME" \
		$BACKUP_DIRS

	# check return code
	errorcode="$?"

	# remove local lock
	rm_lock

	# show output
	# see https://borgbackup.readthedocs.io/en/stable/usage.html?highlight=return%20code#return-codes
	case ${errorcode} in
		2 )
			error_log "Borg exited with fatal error." #(2)

			# wait some time to recover from the error
			info_log "Wait $SLEEP_TIME…"
			sleep "$SLEEP_TIME"

			# break-lock if backup has not locked by another process in the meantime
			if is_lock; then
				error_log "Backup $BACKUP_NAME is locked locally by other process. Cancel."
				exit 1
			fi

			if [ "$RUN_PID_DIR" != "" ]; then
				info_log "Breaking lock…"
				$BORG_BIN break-lock "$REPOSITORY"
			fi
			;;
		1 )
			error_log "Borg had some WARNINGS, but everything else was okay."
			;;
		0 )
			info_log "Borg has been successful."
			;;
		* )
			error_log "Unknown error with code ${errorcode} happened."
			;;
	esac

	# exit on non-critical errors (ignore 1 = warnings)
	if [ ${errorcode} -le 1 ]; then
		# save/update last backup time
		if [ -d $LAST_BACKUP_DIR ]; then
			date +'%s' > "$LAST_BACKUP_DIR/$BACKUP_NAME.time"
		fi
		# get out of loop
		break;
	fi
done

# The '{hostname}-$BACKUP_NAME-' prefix makes sure only backups from
# this machine with this backup-type are touched.
# (some variables intentionally not quoted)

if [ "$PRUNE_PARAMS" ]; then
	echo "Running prune for $BACKUP_NAME…"
	do_lock
	# shellcheck disable=SC2086
	$BORG_BIN prune -v --list --prefix "{hostname}-$BACKUP_NAME-" $PRUNE_PARAMS
	rm_lock
fi

# log
info_log "Backup \"$BACKUP_NAME\" ended."
