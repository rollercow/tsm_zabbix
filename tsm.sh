#!/bin/bash
# Title: tsm.sh
# Version: 1.0 Beta 2
# Description: Script to gather data from TSM and report back to zabbix.
# Author: Chris S. / [wings4marie @ gmail DOT com] / [IRC: Parabola@Freenode]
# Modified: 06/21/2012
###################################################################################
#
#################
#     NOTES     #
#################
# I will be updating this as I get time.  If you have any questions or issues, feel free to contact me.
#
# 1.) Firstly, this is a work in progress. The functionality is sound, and its stable, however you'll notice some cleaning is needed.
# 2.) Also, until I get time, to remove the dependency. I've included a couple TSM scripts that a few of the functions are based on (see tsm_scripts.txt)
# 3.) LogPools/DiskPools - At this time I've yet to find a better way to do this. the looping will send values for all found, however the Key must exist in zabbix
#     I've created 3 LogPool keys, and 7 Diskpool keys (included in template) you will want to add/remove to match your environment
#
#################
# INSTRUCTIONS  #
#################
# 1.) Import/Add the TSM scripts included with this release. File: "tsm_scripts.txt" (They are in MACRO format, ready for copy/paste..See notes for more info)
# 2.) Put the script in your "externalscripts" directory (specified in the zabbix_server.conf)
# 3.) Update the variables in the configuration section below
# 4.) Verify the schedule section at the bottom of this script meets your needs, I've included my cron entries for reference
# 5.) Import the template (make sure you change the "MAX_TAPES" and "LOW_SCRATCHVOLS" Macros!!)
# 6.) Ensure the TSM client is installed on the zabbix server (we need the dsmadmc binary!)
#
#################
# CONFIGURATION #
#################
zabbix_server="localhost" # Enter the hostname or IP of the zabbix server
zabbix_sender="/usr/local/bin/zabbix_sender"
zabbix_nodename="Zabbix server"		# Hostname in zabbix, I've left the default zabbix server name.
tsm_binary="/opt/tivoli/tsm/client/ba/bin/dsmadmc" # Path to the admin CLI binary tool
tsm_user="TSM_USER" # TSM username
tsm_pass="TSM_PASS" # TSM Password
serviceDesk_support=1 # 1=on / 2=off. If you're using serviceDesk for ticketing, below is an open_ticket function, simply update the categories to match
serviceDesk_url="http://SERVERNAME.DOMAIN.com:80/servlets/RequestServlet" # URL for serviceDesk (unused if serviceDesk support is disabled)
serviceDesk_user="SERVICEDESK_USER"
serviceDesk_pass="SERVICEDESK_PASS"

#################
#  FUNCTIONS    #
#################
function send_value {
	"$zabbix_sender" -vvv --zabbix-server "$zabbix_server" --host "$zabbix_nodename" --key $1 --value $2
}

function tsm_cmd {
	"$tsm_binary" -id=$tsm_user -pa=$tsm_pass $1
}

function tsm_scratchvols { # Total number of scratch volumes
	scratchvols=$(tsm_cmd "run scratchvols" | sed -n '13p' | sed 's/^[ \t]*//')
	send_value tsm.tapes.scratchvols "$scratchvols"
}

function tsm_totalvols { # Total number of volumes
	totalvols=$(tsm_cmd "run scratchvols" | sed -n '21p' | sed 's/^[ \t]*//' )
	send_value tsm.tapes.totalvols "$totalvols"
}

function open_ticket { # Uses curl (version: 7.16+) to open a ticket in serviceDesk (See CONFIGURATION and NOTES for more info)
	if (($serviceDesk_support == 1)); then
		echo "YES"
		curl "$serviceDesk_url" -s \
			-d operation=AddRequest \
			--data-urlencode subject="$tsm_failed_subject" \
			--data-urlencode category="Operating System" \
			--data-urlencode subcategory="Linux" \
			--data-urlencode item="Preventive Maintenance" \
			--data-urlencode group="Linux/AIX Tier 2" \
			--data-urlencode description="$desc" \
			--data-urlencode requester="System API" \
			-d status=Open \
			--data-urlencode priority="2. Response 1-4 hours" \
			-d mode=API \
			-d username="$serviceDesk_user" \
			-d password="$serviceDesk_pass"
		fi
}

function tsm_failedjobs { # Number of jobs marked as "Failed"
	mkfifo tsmPipeFailed
	failedLog=$(tsm_cmd "run failedjobs" | sed '1,12d' | sed -e :a -e '$d;N;2,4ba' -e 'P;D' | awk '{print $1,$2,$5,$6,$7}' | sed '$d' | sed -n 'p;N' | grep -v Missed)
	if [[ $(echo $failedLog) == *Failed* ]]; then
		echo "$failedLog" > tsmPipeFailed & 
		while read line; do
			failedInt=$(($failedInt+1))
			tsm_failed_subject="Monitoring - TSM - Failed backup for host $(echo $line | awk '{print $4}')"
			open_ticket "$line"
		done < tsmPipeFailed
		send_value tsm.jobs.failed "$failedInt"
	fi
	rm -f tsmPipeFailed
}

function tsm_missedjobs { # Number of jobs marked as "Missed"
	mkfifo tsmPipeMissed
	missedLog=$(tsm_cmd "run failedjobs" | sed '1,12d' | sed -e :a -e '$d;N;2,4ba' -e 'P;D' | awk '{print $1,$2,$4,$5,$6,$7}' | sed '$d' | sed -n 'p;N' | grep -v Failed)
	if [[ $(echo $missedLog) == *Missed* ]]; then
		echo "$missedLog" > tsmPipeMissed & 
		while read line; do
			missedInt=$(($missedInt+1))
			tsm_failed_subject="Monitoring - TSM - Missed backup for host $(echo $line | awk '{print $3}')"
			open_ticket "$line"
		done < tsmPipeMissed
		send_value tsm.jobs.missed "$missedInt"
		rm -f tsmPipeMissed
	else
		send_value tsm.jobs.missed 0
	fi
}

function tsm_diskpool_usage { # See NOTES
	diskpool=$(tsm_cmd "SELECT volume_name,stgpool_name,pct_utilized FROM volumes WHERE stgpool_name= 'DISKPOOL' ORDER BY stgpool_name DESC" | tail -n +13 | head -n -3)
	echo "$diskpool" | while read disk _ num
	do
		send_value tsm.pools."${disk:(-5)}" "$num"
	done
}

function tsm_logpool_usage { # See NOTES
	logpool=$(tsm_cmd "SELECT volume_name,stgpool_name,pct_utilized FROM volumes WHERE stgpool_name= 'LOGPOOL' ORDER BY stgpool_name DESC" | tail -n +13 | head -n -3)
	echo "$logpool" | while read log _ num
	do 
		send_value tsm.pools."${log:(-4)}" "$num"
	done
}

function tsm_consolidate { # Takes tapes that are <30% full, that are marked "FULL" and dumps the data back to the storagepool
	consolidate=$(tsm_cmd "SELECT volume_name,pct_utilized,stgpool_name FROM volumes WHERE status='FULL' AND pct_utilized < 30 ORDER BY pct_utilized ASC" | tail -n +13 | head -n -3)
	echo "$consolidate" | while read col1 col2 col3
	do
		tsm_cmd "move data $col1 stgpool=$col3"
	done
}

function tsm_consolidate_num { # Number of tapes marked for consolidation
	volCount=$(tsm_cmd "SELECT volume_name FROM volumes WHERE status='FULL' AND pct_utilized < 30" | tail -n +13 | head -n -3 | wc -l | cut -c 1-2)
	send_value tsm.tapes.consolidate.count "$volCount"
}

function tsm_nodes_count { #Total number of nodes in your TSM environment
	nodeCount=$(tsm_cmd "SELECT COUNT(*) FROM nodes" | tail -n +13 | head -n -3 | sed 's/^[ \t]*//')
	send_value tsm.nodes.count "$nodeCount"
}

function tsm_nodes_locked { # number of nodes marked as locked
	tsm_failed_subject="Monitoring - TSM - Locked nodes detected"
	lockedNodes=$(tsm_cmd "SELECT node_name FROM nodes WHERE locked='YES'" | sed 's/^[ \t]*//' | tail -n +13 | head -n -3 | wc -l | cut -c 1-2)
	send_value tsm.nodes.locked.count "$lockedNodes"
	if [[ "$lockedNodes" -ge 1 ]];then
		open_ticket
	fi
}

function tsm_nodes_sessioncount {
	sessCount=$(tsm_cmd "SELECT COUNT(*) FROM sessions WHERE session_type='Node'" | sed 's/^[ \t]*//' | tail -n +13 | head -n -3)
	send_value tsm.nodes.sessions.count "$sessCount"
}

function tsm_drives_offline { # Number of drives marked as offline
	offlineDrives=$(tsm_cmd "SELECT COUNT(*) FROM drives WHERE NOT online='YES'" | sed 's/^[ \t]*//' | tail -n +13 | head -n -3)
	send_value tsm.drives.offline.count "$offlineDrives"
}

function tsm_drives_loaded { # Number of drives with a tape (loaded)
	loadedDrives=$(tsm_cmd "SELECT COUNT(*) FROM drives WHERE drive_state='LOADED'" | sed 's/^[ \t]*//' | tail -n +13 | head -n -3)
	send_value tsm.drives.loaded.count "$loadedDrives"
}

function tsm_drives_empty { # Number of "empty" Drives within your library
	emptyDrives=$(tsm_cmd "SELECT COUNT(*) FROM drives WHERE drive_state='EMPTY'" | sed 's/^[ \t]*//' | tail -n +13 | head -n -3)
	send_value tsm.drives.empty.count "$emptyDrives"
}

function tsm_summary_24hrs { #1-backup,2-full_dbbackup,3-migration,4/5-offiste reclimation,6-retrieve,7-stgpool backup
	summary=$(tsm_cmd "SELECT cast(float(sum(bytes))/1024/1024/1024 as dec(8,2)) as "GB" FROM summary WHERE activity<>'TAPE MOUNT' AND activity<>'EXPIRATION' AND end_time>current_timestamp-24 hours GROUP BY activity"| tail -n +14 | head -n -3 | sed '6d' | sed 's/^[ \t]*//;s/[ \t]*$//')
	backup=$(echo "$summary" | sed -n '1p')
	dbbackup=$(echo "$summary" | sed -n '2p')
	migration=$(echo "$summary" | sed -n '3p')
	offsite=$(echo "$summary" | sed -n '4p')
	retrieve=$(echo "$summary" | sed -n '5p')
	stgpool=$(echo "$summary" | sed -n '6p')
	send_value tsm.summary.daily.backup "$backup"
	send_value tsm.summary.daily.dbbackup "$dbbackup"
	send_value tsm.summary.daily.migration "$migration"
	send_value tsm.summary.daily.offsite "$offsite"
	send_value tsm.summary.daily.retrieve "$retrieve"
	send_value tsm.summary.daily.stgpool "$stgpool"
}

function tsm_tapes_errors { # Number of tapes with an error status
	tapeErrors=$(tsm_cmd "SELECT COUNT(*) FROM volumes WHERE error_state='YES'" | sed 's/^[ \t]*//' | tail -n +13 | head -n -3)
	send_value tsm.tapes.errors.status "$tapeErrors"
}

function tsm_summary_total_stored { # Total data stored in TB
	totalStored=$(tsm_cmd "SELECT CAST(FLOAT(SUM(logical_mb)) / 1024 / 1024 AS DEC(8,2)) FROM occupancy" | sed 's/^[ \t]*//' | tail -n +13 | head -n -3)
	send_value tsm.summary.total.stored "$totalStored"
}

#################
#  SCHEDULING   #
#################
###############################################################################
# Place functions within each Category for execution 						  #
# INFO: (Use Cron)				    										  #
# daily_morning - Scheduled for 8am, 7 days a week   						  #
# daily_afternoon - 2pm Mon - Saturday		   	     						  #
# hourly_jobs - Run every 60 minutes  									   	  #
# Below are my Cron entries			               							  #
# 																			  #
# 0 8 * * 1,2,3,4,5,6 /bin/bash "/etc/zabbix/externalscripts/tsm.sh" morning  #
# 0 14 * * * /bin/bash "/etc/zabbix/externalscripts/tsm.sh" afternoon         #
# 0,60 * * * * /bin/bash "/etc/zabbix/externalscripts/tsm.sh" hourly          #
#																			  #
###############################################################################
function daily_morning {
	tsm_scratchvols	
	tsm_failedjobs
	tsm_missedjobs
	tsm_summary_24hrs
	tsm_summary_total_stored
}

function daily_afternoon {
	tsm_consolidate
}

function hourly_jobs {
	tsm_totalvols
	tsm_diskpool_usage
	tsm_logpool_usage
	tsm_consolidate_num
	tsm_nodes_count
	tsm_nodes_locked
	tsm_nodes_sessioncount
	tsm_drives_offline
	tsm_drives_loaded
	tsm_drives_empty
	tsm_tapes_errors
}

if [[ "$1" == *hourly* ]]; then
	hourly_jobs
elif [[ "$1" == *morning* ]]; then
	daily_morning
elif [[ "$1" == *afternoon* ]]; then
	daily_afternoon
else echo " "
fi
