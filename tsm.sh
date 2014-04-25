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
zabbix_sender="/usr/bin/zabbix_sender"
zabbix_config="/etc/zabbix_agentd.conf"
tsm_binary="/usr/bin/dsmadmc" # Path to the admin CLI binary tool
tsm_user="ID" # TSM username
tsm_pass="PASSWORD" # TSM Password

#################
#  FUNCTIONS    #
#################
function send_value {
	"$zabbix_sender" -c $zabbix_config -k $1 -o $2
}

function tsm_cmd {
	"$tsm_binary" -id=$tsm_user -pa=$tsm_pass -dataonly=yes "$1" | grep -v ANS0102W # shuts up persistent warning
}

#################
#  TAPE STATS   #
#################

function tsm_scratchvols { # Number of scratch volumes
	scratchvols=$(tsm_cmd "select count(*) Scratch_Vols from libvolumes where status='Scratch'")
	send_value tsm.tapes.scratchvols "$scratchvols"
}
function tsm_totalvols { # Total number of volumes
	totalvols=$(tsm_cmd "select count(*) Total_Vols from libvolumes" )
	send_value tsm.tapes.totalvols "$totalvols"
}
function tsm_consolidate_num { # Number of tapes marked for consolidation
	volCount=$(tsm_cmd "SELECT count(volume_name) FROM volumes WHERE status='FULL' AND pct_utilized < 30")
	send_value tsm.tapes.consolidate.count "$volCount"
}
function tsm_tapes_errors { # Number of tapes with an error status
	tapeErrors=$(tsm_cmd "SELECT COUNT(*) FROM volumes WHERE error_state='YES'")
	send_value tsm.tapes.errors.status "$tapeErrors"
}

#################
#  DRIVE STATS  #
#################

function tsm_drives_offline { # Number of drives marked as offline
	offlineDrives=$(tsm_cmd "SELECT COUNT(*) FROM drives WHERE NOT online='YES'")
	send_value tsm.drives.offline.count "$offlineDrives"
}

function tsm_drives_loaded { # Number of drives with a tape (loaded)
	loadedDrives=$(tsm_cmd "SELECT COUNT(*) FROM drives WHERE drive_state='LOADED'")
	send_value tsm.drives.loaded.count "$loadedDrives"
}

function tsm_drives_empty { # Number of "empty" Drives within your library
	emptyDrives=$(tsm_cmd "SELECT COUNT(*) FROM drives WHERE drive_state='EMPTY'")
	send_value tsm.drives.empty.count "$emptyDrives"
}

#################
#  POOL  STATS  #
#################

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

#################
#   TSM STATS   #
#################

function tsm_nodes_count { #Total number of nodes in your TSM environment
	nodeCount=$(tsm_cmd "SELECT COUNT(*) FROM nodes")
	send_value tsm.nodes.count "$nodeCount"
}

function tsm_nodes_locked { # number of nodes marked as locked
	lockedNodes=$(tsm_cmd "SELECT count(node_name) FROM nodes WHERE locked='YES'")
	send_value tsm.nodes.locked.count "$lockedNodes"
}

function tsm_nodes_sessioncount {
	sessCount=$(tsm_cmd "SELECT COUNT(*) FROM sessions WHERE session_type='Node'")
	send_value tsm.nodes.sessions.count "$sessCount"
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



function tsm_summary_24hrs { 
        summary=$(tsm_cmd "SELECT activity,cast(float(sum(bytes))/1024/1024/1024 as dec(8,2)) as "GB" FROM summary where end_time>current_timestamp-24 hours GROUP BY activity")

        for jobtype in ARCHIVE BACKUP EXPIRATION FULL_DBBACKUP MIGRATION OFFSITERECLAMATION RECLAMATION RESTORE RETRIEVE STGPOOLBACKUP TAPEMOUNT
        do
                send_value tsm.summary.daily.$jobtype $(echo "$summary" | grep $jobtype | awk {'print $2'})
        done
}


function tsm_summary_total_stored { # Total data stored in TB
	totalStored=$(tsm_cmd "SELECT SUM(logical_mb)*1024*1024 FROM occupancy")
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
