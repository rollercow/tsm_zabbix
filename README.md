#Zabbix monitoring for Tivoli Storage Manager (TSM)
Heavly based upon an existing template found here - https://www.zabbix.com/forum/showthread.php?t=25238

##Making it work

1. Put this script on any system with both the TSM client and zabbix sender installed.
2. Update the variables in the configuration section below
3. Import the template into Zabbix (make sure you change the "MAX_TAPES" and "LOW_SCRATCHVOLS" Macros!!)
4. Do stuff with the pool stats section if you wish to monitor your storage pools
5. Verify the schedule section at the bottom of this script meets your needs, I've included my cron entries for reference

