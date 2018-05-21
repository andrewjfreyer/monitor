
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
#                        _ _             
#                       (_) |            
#  _ __ ___   ___  _ __  _| |_ ___  _ __ 
# | '_ ` _ \ / _ \| '_ \| | __/ _ \| '__|
# | | | | | | (_) | | | | | || (_) | |   
# |_| |_| |_|\___/|_| |_|_|\__\___/|_|
#
# ----------------------------------------------------------------------------------------

#KILL ANY OTHER MONITOR SCRIPT; ONLY NECESSARY ON WHEEZY INSTALLATIOS; DEBUG ONLY 
[ ! -z "$1" ] && while read line; do `$line` ;done < <(ps ax | grep "bash monitor" | grep -v "$$" | awk '{print "sudo kill "$1}')

#VERSION NUMBER
version=0.1.30

#CYCLE BLUETOOTH INTERFACE 
sudo hciconfig hci0 down && sleep 2 && sudo hciconfig hci0 up

#SETUP MAIN PIPE
sudo rm main_pipe &>/dev/null
mkfifo main_pipe

#SETUP SCAN PIPE
sudo rm scan_pipe &>/dev/null
mkfifo scan_pipe

#BASE DIRECTORY REGARDLESS OF INSTALLATION; ELSE MANUALLY SET HERE
base_directory=$(dirname "$(readlink -f "$0")")

#MQTT PREFERENCES
MQTT_CONFIG=$base_directory/mqtt_preferences
if [ -f $MQTT_CONFIG ]; then 
	source $MQTT_CONFIG
else
	#IF NO PREFERENCE FILE; LOAD 
	echo "mqtt_address=ip.address.of.server" >> $MQTT_CONFIG
	echo "mqtt_user=username" >> $MQTT_CONFIG
	echo "mqtt_password=password" >> $MQTT_CONFIG
	echo "mqtt_topicpath=location" >> $MQTT_CONFIG
	echo "mqtt_room=''" >> $MQTT_CONFIG

	#LOAD VALUES INTO MQTT CONFIG
	source $MQTT_CONFIG
fi 

# ----------------------------------------------------------------------------------------
# DEFINE VALUES AND VARIABLES
# ----------------------------------------------------------------------------------------

#DEFINE VARIABLES FOR EVENT PROCESSING
declare -A device_log
declare -A scan_log
declare -A status_log

#STATUS OF THE BLUETOOTH HARDWARE
scan_status=0
last_scan=0

#NOTE: EDIT LATER FOR A CONFIGURATION FILE
devices[0]="34:08:BC:15:24:F7"
devices[1]="34:08:BC:14:6F:74"
devices[2]="20:78:f0:dd:7D:94"
devices[3]="C8:69:CD:6A:89:2A"

#LOOP SCAN VARIABLES
device_count=${#devices[@]}
device_index=0
scanned_devices=0
scan_responses=0

#FIND DEPENDENCY PATHS, ELSE MANUALLY SET
mosquitto_pub_path=$(which mosquitto_pub)
mosquitto_sub_path=$(which mosquitto_sub)
hcidump_path=$(which hcidump)
bc_path=$(which bc)
git_path=$(which git)

#ERROR CHECKING FOR MOSQUITTO PUBLICATION 
should_exit=false
[ -z "$mosquitto_pub_path" ] && echo "Required package 'mosquitto_pub' not found. Please install." && should_exit=true
[ -z "$mosquitto_sub_path" ] && echo "Required package 'mosquitto_sub' not found. Please install." && should_exit=true
[ -z "$hcidump_path" ] && echo "Required package 'hcidump' not found. Please install." && should_exit=true
[ -z "$bc_path" ] && echo "Required package 'bc' not found. Please install." && should_exit=true
[ -z "$git_path" ] && echo "Recommended package 'git' not found. Please consider installing."

#ARE REQUIREMENTS MET? 
[ "$should_exit" == true ] && echo "Exiting." && exit 1

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

			#RESET PACKET STREAM VARIABLES
			capturing=""
			packet=""

			continue 
		
		#FIND ADVERTISEMENT PACKET OF RANDOM ADDRESSES                                  __
		elif [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 01\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')

			#SEND TO MAIN LOOP
			echo "RAND$received_mac_address" > main_pipe

			#RESET PACKET STREAM VARIABLES
			capturing=""
			packet=""
			continue
		
		#FIND ADVERTISEMENT PACKET OF PUBLIC ADDRESSES                                  __
		elif [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 00\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')

			#SEND TO MAIN LOOP
			echo "PUBL$received_mac_address" > main_pipe

			#RESET PACKET STREAM VARIABLES
			capturing=""
			packet=""
			continue
		fi 

		#NAME RESPONSE 
		if [[ $packet =~ ^04\ 07\ FF\ .*? ]]; then

			packet=$(echo "$packet" | tr -d '\0')

			#GET HARDWARE MAC ADDRESS FOR THIS REQUEST; REVERSE FOR BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $10":"$9":"$8":"$7":"$6":"$5}')

			#CONVERT RECEIVED HEX DATA INTO ASCII
			local name_as_string=$(echo "${packet:29}" | sed 's/ 00//g' | xxd -r -p )

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
	done < <($(which mosquitto_sub) -v -h "$mqtt_address" -u "$mqtt_user" -P "$mqtt_password" -t "$mqtt_topicpath/scan") 
}

# ----------------------------------------------------------------------------------------
# PERIODIC TRIGGER TO MAIN LOOP
# ----------------------------------------------------------------------------------------
periodic_trigger (){
	echo "TIME trigger started" >&2 
	#MQTT LOOP
	while : ; do 
		sleep 30
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

		#SET THE FILE IF IT DOESN'T EXIST
		[ ! -f ".manufacturer_cache" ] && echo "" > ".manufacturer_cache"

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
# PUBLIC DEVICE ADDRESS SCAN LOOP
# ----------------------------------------------------------------------------------------
public_device_scanner () {
	echo "Public device scanner started" >&2 

	#PUBLIC DEVICE SCANNER LOOP
	while true; do 

		#READ FROM THE MAIN PIPE
		while read scan_event; do 
			
			#ONLY SCAN FOR PROPERLY-FORMATTED MAC ADDRESSES
			local mac=$(echo "$scan_event" | grep -ioE "([0-9a-f]{2}:){5}[0-9a-f]{2}")

			echo -e "${GREEN}[CMD-SCAN]	${GREEN}Scanning:${NC} $mac${NC}"

			name=$(hcitool name "$mac")
			#SCAN FORMATTING; REVERSE MAC ADDRESS FOR BIG ENDIAN
			#hcitool cmd 0x01 0x0019 $(echo "$mac" | awk -F ":" '{print "0x"$6" 0x"$5" 0x"$4" 0x"$3" 0x"$2" 0x"$1}') 0x02 0x00 0x00 0x00 &>/dev/null

			#NEED TO TIMEOUT
			[ ! -z "$name" ] && echo "NAME$mac|TIMEOUT" > main_pipe) & 

			#TESTING
			echo -e "${GREEN}[CMD-SCAN]	${GREEN}Complete:${NC} $mac${NC}"

		done < <(cat < scan_pipe)

		#PREVENT UNNECESSARY LOOPING
		sleep 1
	done 
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

periodic_trigger & 
period_pid="$!"

public_device_scanner & 
public_pid="$!"


#TRAP EXIT FOR CLEANUP ON OLDER INSTALLATIONS
trap "sudo rm main_pipe &>/dev/null; sudo rm scan_pipe &>/dev/null; sudo kill -9 $btle_pid &>/dev/null; sudo kill -9 $mqtt_pid &>/dev/null; sudo kill -9 $scan_pid &>/dev/null; sudo kill -9 $period_pid &>/dev/null; sudo kill -9 $public_pid &>/dev/null" EXIT

# ----------------------------------------------------------------------------------------
# SCAN NEXT DEVICE IF REQUIRED
# ----------------------------------------------------------------------------------------

request_public_mac_scan () {

	#DETERMINE IF SAN IS REQUIRED
	#ARE WE SCANNING FOR *ANYTHING* RIGHT NOW? 
	if [ "$scan_status" == "1" ]; then 
		echo "INVALID SCAN REQEST; REJECTING"
		return 0
	fi  

	#ITERATE TO DETERMINE WHETHER AT LEAST ONE DEVICE IS NOT HOME
	device_index=$((device_index + 1))
	[ "$device_index" -gt $(( device_count - 1 )) ] && device_index=0

	#GET DEVICE
	local device=${devices[$device_index]}

	#GET TIME NOW  
	local now=$(date +%s)

	#PREVIOUS TIME SCANNED
	local previous_scan="${scan_log[$device]}"

	#UPDATE THE SCAN LOG
	scan_log["$device"]=$now

	#GET CURRENT VALUES 
	local status="${device_log[$device]}"

	#DEFAULT SCAN INTERVAL WHEN PRESENT
	scan_interval="45"

	#DETERMINE APPROPRIATE DELAY FOR THIS DEVICE
	if [ -z "$status" ] ; then 
		scan_interval=7
	fi 

	#ONLY SCAN FOR A DEVICE ONCE EVER [X] SECONDS
	if [ "$((now - previous_scan))" -gt "$scan_interval" ] ; then 

		#SCAN THE ABSENT DEVICE 
		last_scan=$(date +%s)
		scanned_devices=$((scanned_devices + 1))
		
		#PERFORM SCAN
		echo "$device" > scan_pipe
	fi 
}

# ----------------------------------------------------------------------------------------
# MAIN LOOPS. INFINITE LOOP CONTINUES, NAMED PIPE IS READ INTO SECONDARY LOOP
# ----------------------------------------------------------------------------------------

#START BY SCANNING
request_public_mac_scan

#MAIN LOOP
while true; do 

	#READ FROM THE MAIN PIPE
	while read event; do 

		#DIVIDE EVENT MESSAGE INTO TYPE AND DATA
		cmd="${event:0:4}"
		data="${event:4}"
		timestamp=$(date +%s)
		is_new=false
		did_change=false
		manufacturer=""
		name=""

		#IF WE ARE SCANNING; IGNORE RANDOM AND TIME TRIGGERS
		if [ "$scan_status" == "1" ]; then 
			if [ "$cmd" == "RAND" ] || [ "$cmd" == "TIME" ]; then 
				continue
			fi 
		fi 

		#PROCEED BASED ON COMMAND TYPE
		if [ "$cmd" == "RAND" ]; then 
			#DATA IS RANDOM MAC ADDRESS; ADD TO LOG
			[ -z "${device_log[$data]}" ] && is_new=true
			device_log["$data"]="$timestamp"

		elif [ "$cmd" == "MQTT" ]; then 
			#IN RESPONSE TO MQTT SCAN 
			request_public_mac_scan

		elif [ "$cmd" == "PUBL" ]; then 
			#DATA IS PUBLIC MAC ADDRESS; ADD TO LOG
			[ -z "${device_log[$data]}" ] && is_new=true
			device_log["$data"]="$timestamp"
			manufacturer="$(determine_manufacturer $data)"

		elif [ "$cmd" == "NAME" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			name=$(echo "$data" | awk -F "|" '{print $2}')
			data="$mac"
			timedout=""

			#ONLY PROCESS THIS ONE IF WE REQUSETED THE 
			#NAME OF THE DEVICE IN AN EARLIER STEP

			if [ "$name" == "TIMEOUT" ]; then 
				#HERE, THE TIMEOUT PROCESSED BEFORE 
				#THE ACTUAL NAME ARRIVED; 
				name=""

				#IS THIS A TIMEOUT EVENT?
				timedout="${BLUE}[Timeout]${NC}"

				#SHOULD TEST IF WE HAVE HAD A RESPONSE 
				#BEFORE THIS TIMEOUT PERIOD ELAPSED
				last_update="${device_log[$mac]}"

				#SHOULD WE IGNORE?
				if [ $((timestamp - last_update)) -lt 10 ]; then 
					continue
				fi  
			fi  

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $data)"

			#SCAN STATUS IS ZERO
			scan_status=0

			#GET CURRENT DEVICE STATUS
			current_status="${status_log[$mac]}"
			[ -z "$current_status" ] && current_status=0

			#ADD TO LOG
			[ -z "${device_log[$mac]}" ] && is_new=true
			device_log["$mac"]="$timestamp"

			#IF NAME FIELD IS BLANK; DEVICE IS NOT PRESENT
			#AND SHOULD BE REMOVED FROM THE LOG
			if [ -z "$name" ]; then 
				#SET DEVICE STATUS LOG
				status_log["$mac"]=0
				[ "$current_status" -gt "0" ] && did_change=true

			else 
				#SET DEVICE STATUS LOG
				status_log["$mac"]=1
				[ "$current_status" == 0 ] && did_change=true

				#PUBLISH TO MQTT BROKER
				$(which mosquitto_pub) -h "$mqtt_address" -u "$mqtt_user" -P "$mqtt_password" -t "location/test" -m "$name Present ($manufacturer)"
			fi

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

		#ECHO VALUES FOR DEBUGGING
		if [ "$cmd" == "NAME" ] || [ "$cmd" == "BEAC" ]; then 
			debug_name="$name"
			[ -z "$debug_name" ] && debug_name="${RED}[Error]$timedout${NC}"
			
			#PRINT RAW COMMAND; DEBUGGING
			echo -e "${BLUE}[CMD-$cmd]	${NC}$data ${GREEN}$debug_name${NC} $manufacturer${NC}"

			#REQUEST NEXT SCAN
			request_public_mac_scan 
			continue

		elif [ "$cmd" == "PUBL" ] && [ "$is_new" == true ]; then 
			echo -e "${RED}[CMD-$cmd]	${NC}$data ${NC} $manufacturer${NC}"
			continue

		elif [ "$cmd" == "RAND" ] && [ "$is_new" == true ]; then 
			echo -e "${RED}[CMD-$cmd]	${NC}$data $name${NC} $manufacturer${NC}"

			#REQUEST NEXT SCAN
			request_public_mac_scan
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
			if [ "$difference" -gt "180" ]; then 
				echo -e "${BLUE}[CLEARED]	${NC}$key Expired after $difference seconds.${NC} "
				unset device_log["$key"]
			fi 
		done
	done < <(cat < main_pipe)
done