
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
[ ! -z "$1" ] && while read line; do `$line` ;done < <(ps ax | grep "monitor.sh" | grep -v "$$" | awk '{print "sudo kill "$1}')

#VERSION NUMBER
version=0.1.63

#CYCLE BLUETOOTH INTERFACE 
sudo hciconfig hci0 down && sudo hciconfig hci0 up

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
declare -A status_log
declare -A scan_log

#NOTE: EDIT LATER FOR A CONFIGURATION FILE
devices[0]="34:08:BC:15:24:F7"
devices[1]="34:08:BC:14:6F:74"
devices[2]="20:78:f0:dd:7D:94"

#LOOP SCAN VARIABLES
device_count=${#devices[@]}
device_index=0

#VERIFICIATIONS
verifications=

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
		local error=$(sudo timeout --signal SIGINT 120 hcitool lescan 2>&1 | grep -iE 'input/output error')
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
	local next_packet=""
	local packet=""

	while read segment; do

		#MATCH A SECOND OR LATER SEGMENT OF A PACKET
		if [[ $segment =~ ^[0-9a-fA-F]{2}\ [0-9a-fA-F] ]]; then
			#KEEP ADDING TO NEXT PACKET
			next_packet="$packet $segment"
			continue

		elif [[ $segment =~ ^\> ]]; then
			#NEW PACKET STARTS
			packet=next_packet
			next_packet=$(echo $segment | sed 's/^>.\(.*$\)/\1/')
		elif [[ $segment =~ ^\< ]]; then
			#INPUT COMMAND; SHOULD IGNORE LATER
			packet=next_packet
			next_packet=$(echo $segment | sed 's/^>.\(.*$\)/\1/')
		fi

		#BEACON PACKET?
		if [[ $packet =~ ^04\ 3E\ 2A\ 02\ 01\ .{26}\ 02\ 01\ .{14}\ 02\ 15 ]] && [ ${#packet} -gt 132 ]; then

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
		fi

		#FIND ADVERTISEMENT PACKET OF RANDOM ADDRESSES                                  __
		if [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 01\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')

			#SEND TO MAIN LOOP
			echo "RAND$received_mac_address" > main_pipe

		fi

		#FIND ADVERTISEMENT PACKET OF PUBLIC ADDRESSES                                  __
		if [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 00\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')

			#SEND TO MAIN LOOP
			echo "PUBL$received_mac_address" > main_pipe

		fi 

		#NAME RESPONSE 
		if [[ $packet =~ ^04\ 07\ FF\ .*? ]] && [ ${#packet} -gt 840 ]; then

			packet=$(echo "$packet" | tr -d '\0')

			#GET HARDWARE MAC ADDRESS FOR THIS REQUEST; REVERSE FOR BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $10":"$9":"$8":"$7":"$6":"$5}')

			#CONVERT RECEIVED HEX DATA INTO ASCII
			local name_as_string=$(echo "${packet:29}" | sed 's/ 00//g' | xxd -r -p )

			#SEND TO MAIN LOOP
			echo "NAME$received_mac_address|$name_as_string" > main_pipe
		fi
	done < <(sudo hcidump --raw)
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
		sleep 60
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
			local remote_result=$(curl -sL https://api.macvendors.com/${address:0:8} | grep -vi "error")
			[ ! -z "$remote_result" ] && echo "${address:0:8}	$remote_result" >> .manufacturer_cache
			manufacturer="$remote_result"
		fi

		#SET DEFAULT MANUFACTURER 
		[ -z "$manufacturer" ] && manufacturer="Unknown"
		echo "$manufacturer"
	fi 
}

# ----------------------------------------------------------------------------------------
# PUBLIC DEVICE ADDRESS SCAN LOOP
# ----------------------------------------------------------------------------------------
public_device_scanner () {
	echo "Public device scanner started" >&2 
	local scan_event_received=false

	#PUBLIC DEVICE SCANNER LOOP
	while true; do 
		#SET SCAN EVENT
		scan_event_received=false

		#READ FROM THE MAIN PIPE
		while read scan_event; do 
			#SET SCAN EVENT RECEIVED
			scan_event_received=true

			#ONLY SCAN FOR PROPERLY-FORMATTED MAC ADDRESSES
			local mac=$(echo "$scan_event" | awk -F "|" '{print $1}' |grep -ioE "([0-9a-f]{2}:){5}[0-9a-f]{2}")
			local previous_status=$( echo "$scan_event" | awk -F "|" '{print $2}' | grep -ioE  "[0-9]{1,")
			[ -z "$previous_status" ] && previous_status=0

			echo -e "${GREEN}[CMD-SCAN]	${GREEN}Scanning:${NC} $mac${NC}"

			#HCISCAN
			name=$(hcitool name "$mac")

			#DELAY BETWEEN SCANS
			sleep 3

			#IF WE HAVE A BLANK NAME AND THE PREVIOUS STATE OF THIS PUBLIC MAC ADDRESS
			#WAS A NON-ZERO VALUE, THEN WE PROCEED INTO A VERIFICATION LOOP
			if [ -z "$name" ]; then 
				if [ "$previous_status" -gt "0" ]; then  
					#SHOULD VERIFY ABSENSE
					for repetition in $(seq 1 4); do 
						#DEBUGGING
						echo -e "${GREEN}[CMD-VERI]	${GREEN}Verify:${NC} $mac${NC}"

						#HCISCAN
						name=$(hcitool name "$mac")

						#BREAK IF NAME IS FOUND
						[ ! -z "$name" ] && break

						#DELAY BETWEEN SCANS
						sleep 3
					done
				fi  
			fi 

			#SCAN FORMATTING; REVERSE MAC ADDRESS FOR BIG ENDIAN
			#hcitool cmd 0x01 0x0019 $(echo "$mac" | awk -F ":" '{print "0x"$6" 0x"$5" 0x"$4" 0x"$3" 0x"$2" 0x"$1}') 0x02 0x00 0x00 0x00 &>/dev/null

			#TESTING
			echo -e "${GREEN}[CMD-SCAN]	${GREEN}Complete:${NC} $mac${NC}"

		done < <(cat < scan_pipe)

		#PREVENT UNNECESSARILY FAST LOOPING
		[ "$scan_event_received" == false ] && sleep 3
	done 
}

# ----------------------------------------------------------------------------------------
# PUBLISH MESSAGE
# ----------------------------------------------------------------------------------------

publish_message () {
	if [ ! -z "$1" ]; then 

		#SET NAME FOR 'UNKONWN'
		local name="$3"
		local confidence="$3"
		[ -z "$confidence" ] && confidence=0

		#IF NO NAME, RETURN "UNKNOWN"
		if [ -z "$name" ]; then 
			name="Unknown"
		fi 

		#TIMESTAMP
		stamp=$(date "+%a %b %d %Y %H:%M:%S GMT%z (%Z)")

		#DEBUGGING 
		(>&2 echo -e "${PURPLE}$mqtt_topicpath/owner/$1 { confidence : $2, name : $name, timestamp : $stamp, manufacturer : $4} ${NC}")

		#POST TO MQTT
		$mosquitto_pub_path -h "$mqtt_address" -u "$mqtt_user" -P "$mqtt_password" -t "$mqtt_topicpath/owner/$mqtt_room/$1" -m "{\"confidence\":\"$2\",\"name\":\"$name\",\"timestamp\":\"$stamp\",\"manufacturer\":\"$4\"}"
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

	#ITERATE TO DETERMINE WHETHER AT LEAST ONE DEVICE IS NOT HOME
	device_index=$((device_index + 1))
	[ "$device_index" -gt $(( device_count - 1 )) ] && device_index=0

	#GET DEVICE
	local device=${devices[$device_index]}

	#GET TIME NOW  
	local now=$(date +%s)

	#GET CURRENT TIMESTAMP
	local current_status="${status_log[$device]}"
	[ -z "$current_status" ] && current_status=0

	#PREVIOUS TIME SCANNED
	local previous_scan="${scan_log[$device]}"

	#UPDATE THE SCAN LOG
	scan_log["$device"]=$now

	#DEFAULT SCAN INTERVAL WHEN PRESENT
	scan_interval="45"

	#DETERMINE APPROPRIATE DELAY FOR THIS DEVICE
	if  [ "$current_status" == 0 ] ; then 
		scan_interval=7
	fi 

	#ONLY SCAN FOR A DEVICE ONCE EVER [X] SECONDS
	if [ "$((now - previous_scan))" -gt "$scan_interval" ] ; then 
		
		#PERFORM SCAN
		echo "$device|$current_status" > scan_pipe
	fi 
}

# ----------------------------------------------------------------------------------------
# MAIN LOOPS. INFINITE LOOP CONTINUES, NAMED PIPE IS READ INTO SECONDARY LOOP
# ----------------------------------------------------------------------------------------

#START BY SCANNING
request_public_mac_scan

#MAIN LOOP
while true; do 
	event_received=false

	#READ FROM THE MAIN PIPE
	while read event; do 
		echo "EVENT: $event"

		#EVENT RECEIVED
		event_received=true

		#DIVIDE EVENT MESSAGE INTO TYPE AND DATA
		cmd="${event:0:4}"
		data="${event:4}"
		timestamp=$(date +%s)
		is_new=false
		did_change=false
		manufacturer=""
		name=""

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

			#UPDATE THE SCAN LOG SO THAT WE DONT' 
			#END UP SCANNING THIS DEVICE TOO OFTEN
			scan_log["$mac"]=$timestamp

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $data)"

			#GET CURRENT DEVICE STATUS
			current_status="${status_log[$mac]}"
			[ -z "$current_status" ] && current_status=0 && status_log[$mac]=0

			#ADD TO LOG
			[ -z "${device_log[$mac]}" ] && is_new=true
			device_log["$mac"]="$timestamp"

			#IF NAME FIELD IS BLANK; DEVICE IS NOT PRESENT
			#AND SHOULD BE REMOVED FROM THE LOG
			if [ -z "$name" ]; then 

				#DIVIDE BY FIVE; LOST CONFIDENCE
				new_status=$(( current_status / 5 ))

				#SET DEVICE STATUS LOG
				status_log["$mac"]="$new_status"
				[ "$new_status" != "$current_status" ] && did_change=true
			else 
				#SET DEVICE STATUS LOG; RESTORE TO 100
				status_log["$mac"]=100
				[ "$current_status" == 0 ] && did_change=true
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

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $data)"			
		fi

		#**********************************************************************

		#ECHO VALUES FOR DEBUGGING
		if [ "$cmd" == "NAME" ] || [ "$cmd" == "BEAC" ]; then 
			debug_name="$name"
			[ -z "$debug_name" ] && debug_name="${RED}[Error]${NC}"
			
			#PRINT RAW COMMAND; DEBUGGING
			echo -e "${BLUE}[CMD-$cmd]	${NC}$data ${GREEN}$debug_name${NC} $manufacturer${NC}"

			#GET CURRENT STATUS
			current_status="${status_log[$data]}"

			#PUBLISH TO MQTT
			publish_message "$data" "$current_status" "$name" "$manufacturer"

			#REQUEST NEXT SCAN
			request_public_mac_scan 
			continue
		fi 


		if [ "$cmd" == "PUBL" ] && [ "$is_new" == true ]; then 
			echo -e "${RED}[CMD-$cmd]	${NC}$data ${NC} $manufacturer${NC}"
			continue

		elif [ "$cmd" == "RAND" ] && [ "$is_new" == true ]; then 
			#REQUEST NEXT SCAN
			request_public_mac_scan
			continue
		fi 
	done < <(cat < main_pipe)

	#PREVENT UNNECESSARILY FAST LOOPING
	[ "$event_received" == false ] && sleep 3
done