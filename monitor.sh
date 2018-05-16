
#!/bin/bash

# ----------------------------------------------------------------------------------------
# GENERAL INFORMATION
# ----------------------------------------------------------------------------------------
#
# Written by Andrew J Freyer
# GNU General Public License
# http://github.com/andrewjfreyer/presence
#
# Credits to:
#		Radius Networks iBeacon Script
#			• http://developer.radiusnetworks.com/ibeacon/idk/ibeacon_scan
#
#		Reely Active advlib
#			• https://github.com/reelyactive/advlib
#
# ----------------------------------------------------------------------------------------

#KILL ANY OTHER PRESENCE SCRIPT; DEBUG ONLY 
[ ! -z "$1" ] && while read line; do `$line` ;done < <(ps ax | grep "bash monitor" | grep -v "$$" | awk '{print "sudo kill "$1}')

#VERSION NUMBER
version=0.1 

#CYCLE BLUETOOTH INTERFACE 
sudo hciconfig hci0 down && sudo hciconfig hci0 up

#SETUP MAIN PIPE
sudo rm main_pipe 2>&1 1>/dev/null
mkfifo main_pipe

#FIND DEPENDENCY PATHS, ELSE MANUALLY SET
mosquitto_pub_path=$(which mosquitto_pub)
mosquitto_sub_path=$(which mosquitto_sub)
hcidump_path=$(which hcidump)
bc_path=$(which bc)
git_path=$(which git)

#ERROR CHECKING FOR MOSQUITTO PUBLICATION 
[ -z "$mosquitto_pub_path" ] && echo "Required package 'mosquitto_pub' not found. Please install." && exit 1
[ -z "$mosquitto_sub_path" ] && echo "Required package 'mosquitto_sub' not found. Please install." && exit 1
[ -z "$hcidump_path" ] && echo "Required package 'hcidump' not found. Please install." && exit 1
[ -z "$bc_path" ] && echo "Required package 'bc' not found. Please install." && exit 1
[ -z "$git_path" ] && echo "Recommended package 'git' not found. Please consider installing."

#COLOR OUTPUT FOR RICH DEBUG 
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'

# ----------------------------------------------------------------------------------------
# BLUETOOTH LE BACKGROUND SCANNING
# ----------------------------------------------------------------------------------------
bluetooth_scanner () {
	echo "BTLE scanner started" >&2 
	while true; do 
		local error=$(sudo timeout --signal SIGINT 45 hcitool lescan 2>&1 | grep -iE 'input/output error')
		[ ! -z "$error" ] && echo "ERRO$error" > main_pipe
		sleep 1
	done
}

# ----------------------------------------------------------------------------------------
# BLUETOOTH LE RAW PACKET ANALYSIS
# ----------------------------------------------------------------------------------------
btle_listener () {
	echo "BTLE trigger started" >&2 
	
	#DEFINE VARAIBLES
	local capturing=""
	local packet=""

	while read segment; do

		#MATCH A SECOND OR LATER SEGMENT OF A PACKET
		if [[ $segment =~ ^[0-9a-fA-F]{2}\ [0-9a-fA-F] ]]; then
			packet="$packet $segment"
		else
			#NEXT PACKET
			capturing=""
			packet=""
		fi

		#BEACON PACKET?
		if [[ $packet =~ ^04\ 3E\ 2A\ 02\ 01\ .{26}\ 02\ 01\ .{14}\ 02\ 15 ]]; then

			#IF iBEACON PACKET NOT COMPLETE, CONTINUE
			[ ${#packet} -lt 133 ] && continue

			#RAW VALUES
			local UUID=$(echo $packet | sed 's/^.\{69\}\(.\{47\}\).*$/\1/')
			local MAJOR=$(echo $packet | sed 's/^.\{117\}\(.\{5\}\).*$/\1/')
			local MINOR=$(echo $packet | sed 's/^.\{123\}\(.\{5\}\).*$/\1/')
			local POWER=$(echo $packet | sed 's/^.\{129\}\(.\{2\}\).*$/\1/')
			local UUID=$(echo $UUID | sed -e 's/\ //g' -e 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')

			#MAJOR CALCULATION
			MAJOR=$(echo $MAJOR | sed 's/\ //g')
			MAJOR=$(echo "ibase=16; $MAJOR" | bc)

			#MINOR CALCULATION
			MINOR=$(echo $MINOR | sed 's/\ //g')
			MINOR=$(echo "ibase=16; $MINOR" | bc)

			#POWER CALCULATION
			POWER=$(echo "ibase=16; $POWER" | bc)
			POWER=$[POWER - 256]

			#RSSI CALCULATION
			RSSI=$(echo $packet | sed 's/^.\{132\}\(.\{2\}\).*$/\1/')
			RSSI=$(echo "ibase=16; $RSSI" | bc)
			RSSI=$[RSSI - 256]

            #ADD BEACON 
            key_identifier="$UUID-$MAJOR-$MINOR"

			#SEND TO MAIN LOOP
			echo "BEAC$UUID|$MAJOR|$MINOR|$RSSI|$POWER" > main_pipe

			#RESET
			capturing=""
			packet=""

			continue 
		
		#FIND ADVERTISEMENT PACKET OF RANDOM ADDRESSES                                  __
		elif [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 01\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')

			#SEND TO MAIN LOOP
			echo "RAND$received_mac_address" > main_pipe

			#RESET
			capturing=""
			packet=""
			continue
		
		#FIND ADVERTISEMENT PACKET OF PUBLIC ADDRESSES                                  __
		elif [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 00\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')

			#SEND TO MAIN LOOP
			echo "PUBL$received_mac_address" > main_pipe

			#RESET
			capturing=""
			packet=""
			continue
		fi 

		#NAME RESPONSE 
		if [[ $packet =~ ^04\ 07\ FF\ .*? ]]; then

			#GET HARDWARE MAC ADDRESS FOR THIS REQUEST; REVERSE FOR BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $10":"$9":"$8":"$7":"$6":"$5}')

			#CONVERT RECEIVED HEX DATA INTO ASCII
			local name_as_string=$(echo "${packet:29}" | xxd -r -p)

			#SEND TO MAIN LOOP
			echo "NAME$received_mac_address|$name_as_string" > main_pipe

			#RESET PACKET STREAM VARIABLES
			capturing=""
			packet=""

			continue
		fi

		#CONTINUE BUILD OF FULL PACKET
		if [ ! "$capturing" ]; then
			if [[ $segment =~ ^\> ]]; then
				#PACKET STARTS
				packet=$(echo $segment | sed 's/^>.\(.*$\)/\1/')
				capturing=1
			fi
		fi
	done < <(sudo hcidump --raw filter hci)
}

# ----------------------------------------------------------------------------------------
# MQTT LISTENER
# ----------------------------------------------------------------------------------------
mqtt_listener (){
	echo "MQTT trigger started" >&2 
	#MQTT LOOP
	while read instruction; do 
		echo "MQTT$instruction" > main_pipe
	done < <($(which mosquitto_sub) -v -h "HOSTNAME" -u "USERNAME" -P "PASSWORD" -t "location/scan") 
}

# ----------------------------------------------------------------------------------------
# PERIODIC TRIGGER TO MAIN LOOP
# ----------------------------------------------------------------------------------------
period_trigger (){
	echo "TIME trigger started" >&2 
	#MQTT LOOP
	while : ; do 
		sleep 15
		echo "TIME" > main_pipe
	done
}

# ----------------------------------------------------------------------------------------
# OBTAIN MANUFACTURER INFORMATION FOR A PARTICULAR BLUETOOTH MAC ADDRESS
# ----------------------------------------------------------------------------------------
determine_manufacturer () {

	#IF NO ADDRESS, RETURN BLANK
	if [ ! -z "$1" ]; then  
		local address="$1"

		#CHECK CACHE
		local manufacturer=$(cat ".manufacturer_cache" | grep "${address:0:8}" | awk -F "\t" '{print $2}')

		#IF CACHE DOES NOT EXIST, USE MACVENDORS.COM
		if [ -z "$manufacturer" ]; then 
			local remote_result=$(curl -sL https://api.macvendors.com/$address | grep -vi "error")
			[ ! -z "$remote_result" ] && echo "${address:0:8}	$remote_result" >> .manufacturer_cache
			manufacturer="$remote_result"
		fi 
		echo "$manufacturer"
	fi 
}

# ----------------------------------------------------------------------------------------
# INITATE SINGLE SCAN, SKIPPING HCITOOL 'NAME' LOGIC (REPETITIONS)
# ----------------------------------------------------------------------------------------
hci_name_scan () {
	if [ ! -z "$1" ]; then 
		#ONLY SCAN FOR PROPERLY-FORMATTED MAC ADDRESSES
		mac=$(echo "$1" | grep -ioE "([0-9a-f]{2}:){5}[0-9a-f]{2}")
		if [ ! -z "$mac" ]; then
			#SET SCAN STATUS FOR THIS DEVICE
			scan_status["$mac"]=1

			echo -e "${GREEN}**********	${GREEN}Scanning: $mac${NC}"

			#SCAN FORMATTING; REVERSE MAC ADDRESS FOR BIG ENDIAN
			hcitool cmd 0x01 0x0019 $(echo "$mac" | awk -F ":" '{print "0x"$6" 0x"$5" 0x"$4" 0x"$3" 0x"$2" 0x"$1}') 0x02 0x00 0x00 0x00 2>&1 1>/dev/null

			#SCHEDULE A TIMEOUT MESSAGE
			(sleep 10 && echo "NAME$mac|TIMEOUT" > main_pipe) & 
		fi 
	fi 
}

# ----------------------------------------------------------------------------------------
# OBTAIN PIDS OF BACKGROUND PROCESSES FOR TRAP
# ----------------------------------------------------------------------------------------
bluetooth_scanner & 
scan_pid="$!"

mqtt_listener & 
mqtt_pid="$!"

btle_listener &
btle_pid="$!"

period_trigger & 
period_pid="$!"

#TRAP EXIT FOR CLEANUP
trap "sudo rm main_pipe; sudo kill -9 $btle_pid; sudo kill -9 $mqtt_pid; sudo kill -9 $scan_pid; sudo kill -9 $period_pid" EXIT


# ----------------------------------------------------------------------------------------
# DEFINE VALUES AND VARIABLES
# ----------------------------------------------------------------------------------------

#DEFINE VARIABLES FOR EVENT PROCESSING
declare -A device_log
declare -A scan_log
declare -A scan_status

#NOTE: EDIT LATER FOR A CONFIGURATION FILE
devices[0]="34:08:BC:15:24:F7"
devices[1]="34:08:BC:14:6F:74"

#LOOP SCAN VARIABLES
device_count=${#devices[@]}
device_index=-1

# ----------------------------------------------------------------------------------------
# MAIN LOOPS. INFINITE LOOP CONTINUES, NAMED PIPE IS READ INTO SECONDARY LOOP
# ----------------------------------------------------------------------------------------

scan_next () {

	#DETERMINE IF SAN IS REQUIRED
	#ARE WE SCANNING FOR *ANYTHING* RIGHT NOW? 
	for key in "${!scan_status[@]}"; do
		if [ "${scan_status[$key]}" == "1" ]; then 
			return 0
		fi  
	done 

	#ITERATE TO DETERMINE WHETHER AT LEAST ONE DEVICE IS NOT HOME
	device_index=$((device_index + 1))
	[ "$device_index" -gt $(( device_count - 1 )) ] && device_index=-1

	#ONLY PROCEED IF THE LOOP IS INCOMPLETE
	if [ "$device_index" != -1 ]; then 

		#GET DEVICE
		device=${devices[$device_index]}

		#GET TIME NOW  
		now=$(date +%s)

		#PREVIOUS TIME SCANNED
		previous_scan="${scan_log[$device]}"

		#UPDATE THE SCAN LOG
		scan_log["$device"]=$now

		#ONLY SCAN FOR A DEVICE ONCE EVER [X] SECONDS
		if [ "$((now - previous_scan))" -gt "60" ]; then 

			status=${device_log["$device"]}
			scanning=${scan_status["$device"]}

			#SET DEFAULT VALUES IF THESE HAVE NOT BEEN 
			#SEEN OR SCANNED FOR THE FIRST TIME YET
			[ -z "$status" ] && status=0 
			[ -z "$scanning" ] && scanning=0

			#ONLY SET FOR SCANNING IF THE DEVICE IS NOT PRESENT
			#AND IF THE DEVICE IS NOT CURRENTLY SCANNING
			if [ "$status" == "0" ] && [ "$scanning" == 0 ] ; then 
				#SET VALUES
				unset device_log["$device"]
				scan_status["$device"]=1

				#SCAN THE ABSENT DEVICE 
				hci_name_scan $device
			fi 
		fi 
	fi  
}

#MAIN LOOP
while true; do 

	#READ FROM THE MAIN PIPE
	while read event; do 
		#DIVIDE EVENT MESSAGE INTO TYPE AND DATA
		cmd="${event:0:4}"
		data="${event:4}"
		timestamp=$(date +%s)
		is_new=false
		manufacturer=""
		name=""
		
		#PROCEED BASED ON COMMAND TYPE
		if [ "$cmd" == "RAND" ]; then 
			#DATA IS RANDOM MAC ADDRESS; ADD TO LOG
			[ -z "${device_log[$data]}" ] && is_new=true
			device_log["$data"]="$timestamp"

		elif [ "$cmd" == "PUBL" ]; then 
			#DATA IS PUBLIC MAC ADDRESS; ADD TO LOG
			[ -z "${device_log[$data]}" ] && is_new=true
			device_log["$data"]="$timestamp"
			manufacturer="$(determine_manufacturer $data)"

		elif [ "$cmd" == "NAME" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			name=$(echo "$data" | awk -F "|" '{print $2}')
			data=$mac

			#IS THIS A NAME SCAN TIMEOUT EVENT
			if [ "$name" == "TIMEOUT" ]; then 
				if [ "${scan_status["$mac"]}" == 1 ]; then 
					#NAME SCANNING FAILED; RESET NAME TO BLANK
					name=""
				else 
					#NAME SCANNING SUCCEEDED (RETURNING EITHER 
					#BLANK NAME OR ACTUAL DEVICE NAME; IGNORE 
					#FALLBACK TIMOUT)
					continue
				fi
			fi

			#ONLY PROCESS THIS ONE IF WE REQUSETED THE 
			#NAME OF THE DEVICE IN AN EARLIER STEP
			if [ "${scan_status["$mac"]}" == 1 ]; then 

				manufacturer="$(determine_manufacturer $data)"

				#SCAN STATUS IS ZERO
				scan_status["$mac"]=0
				
				#IF NAME FIELD IS BLANK; DEVICE IS NOT PRESENT
				#AND SHOULD BE REMOVED FROM THE LOG
				if [ -z "$name" ]; then 
					unset device_log["$mac"]
				else 
					#ADD TO LOG
					[ -z "${device_log[$mac]}" ] && is_new=true
					device_log["$mac"]="$timestamp"
				fi 
			fi 

			#LASTLY SCAN THE NEXT DEVICE
			scan_next

		elif [ "$cmd" == "BEAC" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			uuid=$(echo "$data" | awk -F "|" '{print $1}')
			major=$(echo "$data" | awk -F "|" '{print $2}')
			minor=$(echo "$data" | awk -F "|" '{print $3}')
			rssi=$(echo "$data" | awk -F "|" '{print $4}')
			power=$(echo "$data" | awk -F "|" '{print $5}')

			#KEY DEFINED AS UUID-MAJOR-MINOR
			key="$uuid-$major-$minor"
			[ -z "${device_log[$key]}" ] && is_new=true
			device_log["$key"]="$timestamp"
		fi

		#SHOULD TRIGGER PUBLIC SCAN
		if [ "$cmd" == "RAND" ] && [ "$is_new" == true ]; then
			scan_next $mac
		fi 

		#ECHO VALUES FOR DEBUGGING
		if [ "$cmd" == "NAME" ] || [ "$cmd" == "BEAC" ]; then 
			debug_name="$name"
			[ -z "$debug_name" ] && debug_name="${RED}[Error]"
			#PRINT RAW COMMAND; DEBUGGING
			echo -e "${BLUE}[CMD-$cmd]	${NC}$data ${GREEN}$debug_name${NC} $manufacturer${NC}"
			continue

		elif [ "$cmd" == "PUBL" ] && [ "$is_new" == true ]; then 
			echo -e "${RED}[CMD-$cmd]	${NC}$data ${NC} $manufacturer${NC}"
			continue
		elif [ "$cmd" == "RAND" ] && [ "$is_new" == true ]; then 
			echo -e "${RED}[CMD-$cmd]	${NC}$data $name${NC} $manufacturer${NC}"
			continue
		fi 

		#CLEAN THE DEVICE LOG
		for key in "${!device_log[@]}"; do
			#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
			now=$(date +%s)
			last_seen=${device_log["$key"]}
			difference=$((now - last_seen))

			#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
			[ -z "$last_seen" ] && continue 

			#TIMEOUT AFTER 120 SECONDS
			if [ "$difference" -gt "45" ]; then 
				echo -e "${BLUE}[CLEARED]	${NC}$key Expired after $difference seconds.${NC} "
				unset device_log["$key"]
			fi 
		done
	done < <(cat < main_pipe)
	#IF WE ARE HERE, THE MAIN_PIPE HAS CLOSED = NO MESSAGES FOR A WHILE
done