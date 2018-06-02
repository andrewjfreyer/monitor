
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

#VERSION NUMBER
version=0.1.189

# ----------------------------------------------------------------------------------------
# PRETTY PRINT FOR DEBUG
# ----------------------------------------------------------------------------------------

#COLOR OUTPUT FOR RICH OUTPUT 
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
REPEAT='\e[1A'

last_log_line=""
duplicate_log_count=1

#PRINT TO LOG UNLESS DUPLICATE LINE
log() {
	#ECHO TO CONSOLE, REMOVING EXTRA SPACES
	line=$(echo "$1" | sed 's/  */ /g')
	should_repeat=""
	line_append=""

	#IS THIS LINE DUPLICATED?
	if [ "$last_log_line" == "$line" ]; then 
		duplicate_log_count=$((duplicate_log_count + 1 ))
		line_append=" (x$duplicate_log_count)"
		should_repeat=$REPEAT
	else 
		duplicate_log_count=1
	fi   
	#ECHO LAST LINE
	echo -e "${should_repeat}$version $(date "+%I:%M:%S %p") $line$line_append"
	last_log_line="$line"
}

# ----------------------------------------------------------------------------------------
# CHECK CONFIGURATION FILES
# ----------------------------------------------------------------------------------------

#FIND DEPENDENCY PATHS, ELSE MANUALLY SET
mosquitto_pub_path=$(which mosquitto_pub)
mosquitto_sub_path=$(which mosquitto_sub)
hcidump_path=$(which hcidump)
bc_path=$(which bc)
git_path=$(which git)

#ERROR CHECKING FOR MOSQUITTO PUBLICATION 
should_exit=false
[ -z "$mosquitto_pub_path" ] && log "${RED}Error: ${NC}Required package 'mosquitto_pub' not found. Please install." && should_exit=true
[ -z "$mosquitto_sub_path" ] && log "${RED}Error: ${NC}Required package 'mosquitto_sub' not found. Please install." && should_exit=true
[ -z "$hcidump_path" ] && log "${RED}Error: ${NC}Required package 'hcidump' not found. Please install." && should_exit=true
[ -z "$bc_path" ] && log "${RED}Error: ${NC}Required package 'bc' not found. Please install." && should_exit=true
[ -z "$git_path" ] && log "${ORANGE}Warning: ${NC}Recommended package 'git' not found. Please consider installing."

#BASE DIRECTORY REGARDLESS OF INSTALLATION; ELSE MANUALLY SET HERE
base_directory=$(dirname "$(readlink -f "$0")")

#MQTT PREFERENCES
MQTT_CONFIG="$base_directory/mqtt_preferences"
if [ -f $MQTT_CONFIG ]; then 
	source $MQTT_CONFIG

	#DOUBLECHECKS 
	[ "$mqtt_address" == "0.0.0.0" ] && log "${RED}Error: ${NC}Please customize mqtt broker address in: ${BLUE}mqtt_preferences${NC}" && should_exit=true
	[ "$mqtt_user" == "username" ] && log "${RED}Error: ${NC}Please customize mqtt username in: ${BLUE}mqtt_preferences${NC}" && should_exit=true
	[ "$mqtt_password" == "password" ] && log "${RED}Error: ${NC}Please customize mqtt password in: ${BLUE}mqtt_preferences${NC}" && should_exit=true
else
	echo "Mosquitto preferences file created. Please customize." 

	#LOAD A DEFULT PREFERENCES FILE
	echo "# ---------------------------" >> $MQTT_CONFIG
	echo "#								" >> $MQTT_CONFIG
	echo "# MOSQUITTO PREFERENCES" >> $MQTT_CONFIG
	echo "#								" >> $MQTT_CONFIG
	echo "# ---------------------------" >> $MQTT_CONFIG
	echo "" >> $MQTT_CONFIG

	echo "# IP ADDRESS OF MQTT BROKER" >> $MQTT_CONFIG
	echo "mqtt_address=0.0.0.0" >> $MQTT_CONFIG

	echo "" >> $MQTT_CONFIG
	echo "# MQTT BROKER USERNAME (OR BLANK FOR NONE)" >> $MQTT_CONFIG
	echo "mqtt_user=username" >> $MQTT_CONFIG

	echo "" >> $MQTT_CONFIG
	echo "# MQTT BROKER PASSWORD (OR BLANK FOR NONE)" >> $MQTT_CONFIG
	echo "mqtt_password=password" >> $MQTT_CONFIG

	echo "" >> $MQTT_CONFIG
	echo "# MQTT PUBLISH TOPIC ROOT " >> $MQTT_CONFIG
	echo "mqtt_topicpath=location" >> $MQTT_CONFIG

	echo "" >> $MQTT_CONFIG
	echo "# PUBLISHER IDENTITY " >> $MQTT_CONFIG
	echo "mqtt_publisher_identity=''" >> $MQTT_CONFIG

	#SET SHOULD EXIT
	should_exit=true
fi 

#MQTT PREFERENCES
PUB_CONFIG="$base_directory/known_static_addresses"
if [ -f "$PUB_CONFIG" ]; then 
	#DOUBLECHECKS 
	[ ! -z "$(cat "$PUB_CONFIG" | grep "^00:00:00:00:00:00")" ] && log "${RED}Error: ${NC}Please customize public mac addresses in: ${BLUE}known_static_addresses${NC}" && should_exit=true
else
	echo "Public MAC address list file created. Please customize."
	#IF NO PUBLIC ADDRESS FILE; LOAD 
	echo "# ---------------------------" >> $PUB_CONFIG
	echo "#" >> $PUB_CONFIG
	echo "# PUBLIC MAC ADDRESS LIST" >> $PUB_CONFIG
	echo "#" >> $PUB_CONFIG
	echo "# ---------------------------" >> $PUB_CONFIG
	echo "" >> $PUB_CONFIG
	echo "00:00:00:00:00:00 Nickname #comment" >> $PUB_CONFIG

	#SET SHOULD EXIT
	should_exit=true
fi 

#ARE REQUIREMENTS MET? 
[ "$should_exit" == true ] && exit 1

# ----------------------------------------------------------------------------------------
# DEFINE VALUES AND VARIABLES
# ----------------------------------------------------------------------------------------

#CYCLE BLUETOOTH INTERFACE 
sudo hciconfig hci0 down && sudo hciconfig hci0 up

#SETUP MAIN PIPE
sudo rm main_pipe>/dev/null
mkfifo main_pipe

#SETUP SCAN PIPE
sudo rm scan_pipe &>/dev/null
mkfifo scan_pipe

#DEFINE DEVICE TRACKING VARS
declare -A static_device_log
declare -A random_device_log
declare -A beacon_device_log
declare -A known_device_log

#LAST TIME THIS 
random_device_last_update=$(date +%s)
next_scan_type=""

#DEFINE PERFORMANCE TRACKING/IMRROVEMENT VARS
declare -A expired_device_log
declare -A named_device_log
declare -A device_expiration_biases

#GLOBAL STATE VARIABLES
all_present=false
all_absent=true

#LOAD PUBLIC ADDRESSES TO SCAN INTO ARRAY, IGNORING COMMENTS
known_static_addresses=($(cat "$PUB_CONFIG" | grep -vE "^#" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" ))

#LOOP SCAN VARIABLES
device_count=${#known_static_addresses[@]}

# ----------------------------------------------------------------------------------------
# BLUETOOTH LE BACKGROUND SCANNING
# ----------------------------------------------------------------------------------------
bluetooth_scanner () {
	echo "BTLE scanner started" >&2 
	while true; do 
		#TIMEOUT THE HCITOOL SCAN TO RESHOW THE DUPLICATES WITHOUT SPAMMING THE MAIN LOOP BY USING THE --DUPLICATES TAG
		local error=$(sudo timeout --signal SIGINT 30 hcitool lescan 2>&1 | grep -iE 'input/output error|invalid device|invalid|error')
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
		if [[ $segment =~ ^[0-9a-fA-F]{2}\ .{55}[0-9a-fA-F]$ ]]; then
			#KEEP ADDING TO NEXT PACKET; WE HAVE A COMPLETE LINE
			next_packet="$next_packet $segment"
			continue

		elif [[ $segment =~ ^[0-9a-fA-F]{2}\ [0-9a-fA-F] ]]; then
			#INCOMPLETE LINE; PACKET LIKELY DONE
			packet="$next_packet $segment"

		elif [[ $segment =~ ^\> ]]; then
			#NEW PACKET STARTS
			packet=$next_packet
			next_packet=$(echo $segment | sed 's/^>.\(.*$\)/\1/')
		elif [[ $segment =~ ^\< ]]; then
			#INPUT COMMAND; SHOULD IGNORE LATER
			packet=$next_packet
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

            #CLEAR PACKET
            packet=""

			#SEND TO MAIN LOOP
			echo "BEAC$UUID|$MAJOR|$MINOR|$RSSI|$POWER" > main_pipe 
		fi

		#FIND ADVERTISEMENT PACKET OF RANDOM ADDRESSES                                  __
		if [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 01\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')
			local pdu_header=$(pdu_type $(echo "$packet" | awk '{print $6}'))
			local gap_name_str=""

			#IF THIS IS A SCAN RESPONSE, FIND WHETHER WE HAVE USABLE GAP NAME DATA 
			if [ "$pdu_header" == 'SCAN_RSP' ]; then 
				gap_name_str=$(gap_name "$packet")

				#RECORD THE NAME IN THE DEVICE LOG
				[ ! -z "$gap_name_str" ] && named_device_log[$received_mac_address]="$gap_name_str"
	        fi

            #CLEAR PACKET
			packet=""

			#FILTER TO ADV_IND; EXPERIMENTALLY, THIS IS THE ADV PACKET MOST 
			#COMMONLY SENT BY APPLE AND ANDROID PHONES TRYING TO ADVERTISE
			#CONNECTION TO OTHER DEVICES
			
            if [ "$pdu_header" == "ADV_IND" ] || [ "$pdu_header" == "ADV_NONCONN_IND" ] ; then 
				#NAME TO RETURN
				local name_str="${named_device_log[$received_mac_address]}"

				#SEND TO MAIN LOOP
				echo "RAND$received_mac_address|$pdu_header|$name_str" > main_pipe
			fi 

		fi

		#FIND ADVERTISEMENT PACKET OF PUBLIC ADDRESSES                                  __
		if [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 00\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')
			local pdu_header=$(pdu_type $(echo "$packet" | awk '{print $6}'))
			local gap_name_str=""

			#IF THIS IS A SCAN RESPONSE, FIND WHETHER WE HAVE USABLE GAP NAME DATA 
			if [ "$pdu_header" == 'SCAN_RSP' ]; then 
				gap_name_str=$(gap_name "$packet")

				#RECORD THE NAME IN THE DEVICE LOG
				[ ! -z "$gap_name_str" ] && named_device_log[$received_mac_address]="$gap_name_str"
	        fi

            #CLEAR PACKET
            packet=""

            #NAME TO RETURN
			local name_str="${named_device_log[$received_mac_address]}"

			#SEND TO MAIN LOOP
			echo "PUBL$received_mac_address|$pdu_header|$name_str" > main_pipe
		fi 

		#NAME RESPONSE 
		if [[ $packet =~ ^04\ 07\ FF\ .*? ]] && [ ${#packet} -gt 700 ]; then

			packet=$(echo "$packet" | tr -d '\0')

			#GET HARDWARE MAC ADDRESS FOR THIS REQUEST; REVERSE FOR BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $10":"$9":"$8":"$7":"$6":"$5}')

			#CONVERT RECEIVED HEX DATA INTO ASCII
			local name_as_string=$(echo "${packet:29}" | sed 's/ 00//g' | xxd -r -p )

            #CLEAR PACKET
            packet=""

			#SEND TO MAIN LOOP; FORK FOR FASTER RESPONSE
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
	done < <($(which mosquitto_sub) -v -h "$mqtt_address" -u "$mqtt_user" -P "$mqtt_password" -t "$mqtt_topicpath/scan/#" --will-retain --will-topic "$mqtt_topicpath/owner/$mqtt_publisher_identity" --will-payload "{\"status\":\"offline\"}") 
}

# ----------------------------------------------------------------------------------------
# PERIODIC TRIGGER TO MAIN LOOP
# ----------------------------------------------------------------------------------------
periodic_trigger (){
	echo "TIME trigger started" >&2 
	#MQTT LOOP
	while : ; do 
		sleep 10
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
# EXTRACT GENERAL ACCESS PROFILE NAME
# ----------------------------------------------------------------------------------------
gap_name () {
	#SET PACKET FROM INPUT
	local packet="$1"

	#LOCAL STRING
	local name_as_string=""

	#IS A GAP NAME GIVE? COMPLETE OR LOCAL? 
	local gap_name=$(echo "$packet" | awk '{print $16}')

	#CHECK IF GAP DATA IS 
	if [[ $gap_name =~ ^0[89] ]]; then
		#HEX CONVERSION
		local name_len_hex=$(echo "$packet" | awk '{print $15}')

		#DECIMAL CONVERSION
		local name_len_dec=$(echo "ibase=16; $name_len_hex" | bc)
		
		#STR CHARACTER COUNT (2 CHAR + 1 _SPACE_ PER BYTE)
		local name_len_str=$((name_len_dec * 3))
		
		#EXTRACT LOCAL NAME
		local name_as_string=$(echo "${packet:48:name_len_str}" | xxd -r -p )
	fi

	#RETURN NAME
    echo "$name_as_string"
}

# ----------------------------------------------------------------------------------------
# OBTAIN PROTOCOL DATA UNIT TYPE
# ----------------------------------------------------------------------------------------

pdu_type () {
	#IF NO ADDRESS, RETURN BLANK
	local pdu_type_str="Reserved"
	
	if [ ! -z "$1" ]; then  
		local pdu_type="$1"
		case $pdu_type in
			"00")
				pdu_type_str="ADV_IND"
				;;
			"01")
				pdu_type_str="ADV_DIRECT_IND"
				;;	
			"02")
				pdu_type_str="ADV_NONCONN_IND"
				;;	
			"03")
				pdu_type_str="SCAN_REQ"
				;;	
			"04")
				pdu_type_str="SCAN_RSP"
				;;	
			"05")
				pdu_type_str="CONNECT_REQ"
				;;	
			"06")
				pdu_type_str="ADV_SCAN_IND"
				;;	
			*)
				pdu_type_str="Reserved"
				;;	
		esac
	fi 

	#RETURN
	echo "$pdu_type_str"
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
		(>&2 log "${PURPLE}$mqtt_topicpath/owner/$1 { confidence : $2, name : $name, timestamp : $stamp, manufacturer : $4} ${NC}")

		#POST TO MQTT
		$mosquitto_pub_path -h "$mqtt_address" -u "$mqtt_user" -P "$mqtt_password" -t "$mqtt_topicpath/owner/$mqtt_publisher_identity/$1" -m "{\"confidence\":\"$2\",\"name\":\"$name\",\"timestamp\":\"$stamp\",\"manufacturer\":\"$4\"}"
	fi
}

# ----------------------------------------------------------------------------------------
# REFRESH KNOWN DEVICE STATES
# ----------------------------------------------------------------------------------------
refresh_global_states() {
	
	#PROCESS GLOBAL STATES
	local state_sum=0
	for known_addr in "${known_static_addresses[@]}"; do 
		local state="${known_device_log[$known_addr]}"
		state_sum=$((state + state_sum))
	done

	#DETERMINE GLOBALS FROM STATE SUM
	case $state_sum in
		"0")
			all_absent=true
			all_present=false
			;;
		"$device_count")
			all_absent=false
			all_present=true
			;;
		*)
			all_absent=false
			all_present=false
			;;
	esac
}


# ----------------------------------------------------------------------------------------
# ARRIVAL SCAN LIST
# ----------------------------------------------------------------------------------------
arrival_scan_list () {

	local arrival_scan_list=""

	#DO NOT SCAN IF ALL DEVICES ARE PRESENT
	[ "$all_present" == true ] && return 0 

	#ITERATE THROUGH THE KNOWN DEVICES 
	for known_addr in "${known_static_addresses[@]}"; do 
		
		#GET STATE; ONLY SCAN FOR ARRIVED DEVICES
		local state="${known_device_log[$known_addr]}"
		[ -z "$state" ] && state=0

		#SCAN 
		if [ "$state" == "0" ]; then 
			#ASSEMBLE LIST OF DEVICE 
			arrival_scan_list=$(echo "$arrival_scan_list $known_addr")
		fi 
	done

	echo "$arrival_scan_list" | sed 's/^ //g'
}

# ----------------------------------------------------------------------------------------
# SCAN FOR DEVICES
# ----------------------------------------------------------------------------------------
scan () {

	[ -z "$1" ] && return 0

	#ITERATE THROUGH THE KNOWN DEVICES 
	for known_addr in $1; do 
		hcitool name "$known_addr"
		sleep 3
	done

	echo "$arrival_scan_list" | sed 's/^ //g'
}

# ----------------------------------------------------------------------------------------
# CLEANUP ROUTINE 
# ----------------------------------------------------------------------------------------
clean() {
	#CLEANUP FOR TRAP
	while read line; do 
		`sudo kill $line` &>/dev/null
	done < <(ps ax | grep monitor.sh | awk '{print $1}')

	#REMOVE PIPES
	sudo rm main_pipe>/dev/null
	sudo rm scan_pipe &>/dev/null

	#MESSAGE
	echo 'Exited.'
}

trap "clean" EXIT

# ----------------------------------------------------------------------------------------
# LAUNCH BACKGROUND PROCESSES
# ----------------------------------------------------------------------------------------
bluetooth_scanner & 
mqtt_listener &
btle_listener &
periodic_trigger & 

# ----------------------------------------------------------------------------------------
# MAIN LOOPS. INFINITE LOOP CONTINUES, NAMED PIPE IS READ INTO SECONDARY LOOP
# ----------------------------------------------------------------------------------------

#MAIN LOOP
while true; do 
	#READ FROM THE MAIN PIPE
	while read event; do 

		#DIVIDE EVENT MESSAGE INTO TYPE AND DATA
		cmd="${event:0:4}"
		data="${event:4}"
		timestamp=$(date +%s)

		#FLAGS TO DETERMINE FRESHNESS OF DATA
		is_new=false
		did_change=false

		#DATA FOR PUBLICATION
		manufacturer=""
		name=""

		#PROCEED BASED ON COMMAND TYPE
		if [ "$cmd" == "RAND" ]; then 
			#PARSE RECEIVED DATA
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			pdu_header=$(echo "$data" | awk -F "|" '{print $2}')
			name=$(echo "$data" | awk -F "|" '{print $3}')
			data="$mac"

			#IF WE HAVE A NAME; UNSEAT FROM RANDOM AND ADD TO STATIC
			#THIS IS A BIT OF A FUDGE, A RANDOM DEVICE WITH A LOCAL 
			#NAME IS TRACKABLE, SO IT'S UNLIKELY THAT ANY CONSUMER
			#ELECTRONIC DEVICE OR CELL PHONE IS ASSOCIATED WITH THIS 
			#ADDRESS. CONSIDER THE ADDRESS AS A STATIC ADDRESS

			if [ ! -z "$name" ]; then 
				#RESET COMMAND
				cmd="PUBL"
				unset random_device_log[$data]

				#IS THIS A NEW STATIC DEVICE?
				[ -z "${static_device_log[$data]}" ] && is_new=true
				static_device_log[$data]="$timestamp"

			else
				#DATA IS RANDOM MAC ADDRESS; ADD TO LOG
				[ -z "${random_device_log[$data]}" ] && is_new=true

				#ONLY ADD THIS TO THE DEVICE LOG 
				random_device_log[$data]="$timestamp"
			fi 
		elif [ "$cmd" == "MQTT" ]; then 
			#IN RESPONSE TO MQTT SCAN 
			#log "${GREEN}[INSTRUCT]	${NC}MQTT Trigger $data${NC}"

			#GET INSTRUCTION 
			mqtt_instruction=$(basename $data)

			#NORMALIZE TO UPPERCASE
			mqtt_instruction=${mqtt_instruction^^}

			if [ "$mqtt_instruction" == "ARRIVE" ]; then 
				#SET SCAN TYPE
				arrival_scan

			elif [ "$mqtt_instruction" == "DEPART" ]; then 

				#SET SCAN TYPE
				departure_scan

			else 
				#SET SCAN TYPE
				next_scan_type="SCAN_ALL"
			fi 

		elif [ "$cmd" == "TIME" ]; then 

			#**********************************************************************
			#
			#
			#	THE FOLLOWING LOOPS CLEAR CACHES OF ALREADY SEEN DEVICES BASED 
			#	ON APPROPRIATE TIMEOUT PERIODS FOR THOSE DEVICES. 
			#	
			#
			#**********************************************************************
				
			#PURGE OLD KEYS FROM THE RANDOM DEVICE LOG
			random_bias=0
			for key in "${!random_device_log[@]}"; do
				#GET BIAS
				random_bias=${device_expiration_biases[$key]}
				[ -z "$random_bias" ] && random_bias=0 

				#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
				last_seen=${random_device_log[$key]}
				difference=$((timestamp - last_seen))

				#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
				[ -z "$last_seen" ] && continue 

				#TIMEOUT AFTER 120 SECONDS
				if [ "$difference" -gt "$((120 + random_bias))" ]; then 
					unset random_device_log[$key]
					log "${BLUE}[CLEARED]	${NC}$key expired after $difference seconds RAND_NUM: ${#random_device_log[@]}  ${NC}"

					#UPDATE TIMESTAMP
					random_device_last_update=$(date +%s)
					next_scan_type="DEPARTURE_SCAN"

					#ADD TO THE EXPIRED LOG
					expired_device_log[$key]=$timestamp
				fi 
			done

			#PURGE OLD KEYS FROM THE BEACON DEVICE LOG
			beacon_bias=0
			for key in "${!beacon_device_log[@]}"; do
				#GET BIAS
				beacon_bias=${device_expiration_biases[$key]}
				[ -z "$beacon_bias" ] && beacon_bias=0 

				#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
				last_seen=${beacon_device_log[$key]}
				difference=$((timestamp - last_seen))

				#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
				[ -z "$last_seen" ] && continue 

				#TIMEOUT AFTER 120 SECONDS
				if [ "$difference" -gt "$(( 150 + beacon_bias ))" ]; then 
					unset beacon_device_log[$key]
					log "${BLUE}[CLEARED]	${NC}$key expired after $difference seconds BEAC_NUM: ${#beacon_device_log[@]}  ${NC}"

					#ADD TO THE EXPIRED LOG
					expired_device_log[$key]=$timestamp
				fi 
			done

		elif [ "$cmd" == "PUBL" ]; then 
			#PARSE RECEIVED DATA
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			pdu_header=$(echo "$data" | awk -F "|" '{print $2}')
			name=$(echo "$data" | awk -F "|" '{print $3}')
			data="$mac"

			#DATA IS PUBLIC MAC ADDRESS; ADD TO LOG
			[ -z "${static_device_log[$data]}" ] && is_new=true
			static_device_log[$data]="$timestamp"
			manufacturer="$(determine_manufacturer $data)"

		elif [ "$cmd" == "NAME" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			name=$(echo "$data" | awk -F "|" '{print $2}')
			data="$mac"

			#PREVIOUS STATE
			previous_state="${known_device_log[$mac]}"
			[ -z "$previous_state" ] && previous_state=0

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $data)"

			#IF NAME IS DISCOVERED, PRESUME HOME
			if [ ! -z "$name" ]; then 
				known_device_log[$mac]=1
				[ "$previous_state" == "0" ] && did_change=true
			else
				known_device_log[$mac]=0
				[ "$previous_state" == "1" ] && did_change=true
			fi 

			#MUST REFRESH GLOBAL STATES; DID WE HAVE A CHANGE
			refresh_global_states

		elif [ "$cmd" == "BEAC" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			uuid=$(echo "$data" | awk -F "|" '{print $1}')
			major=$(echo "$data" | awk -F "|" '{print $2}')
			minor=$(echo "$data" | awk -F "|" '{print $3}')
			rssi=$(echo "$data" | awk -F "|" '{print $4}')
			power=$(echo "$data" | awk -F "|" '{print $5}')

			#KEY DEFINED AS UUID-MAJOR-MINOR
			data="$uuid-$major-$minor"
			[ -z "${beacon_device_log[$data]}" ] && is_new=true
			beacon_device_log[$data]="$timestamp"	

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $uuid)"			
		fi

		#**********************************************************************
		#
		#
		#	THE FOLLOWING INCREASES DEVICE BAISES IF A DEVICE RE-
		#	APPEARS AFTER A SHORT AMOUNT OF TIME (2 MINUTES)
		#	
		#
		#**********************************************************************

		if [ "$is_new" == true ]; then 

			#GET CURRENT BIAS
			bias=${device_expiration_biases[$data]}
			[ -z "$bias" ] && bias=0

			#WHEN DID THIS LAST EXPIRE?
			last_expired=${expired_device_log[$data]}
			difference=$((timestamp - last_expired))

			#DO WE NEED TO ADD A LEANRED BIAS FOR EXPIRATION?
			if [ "$difference" -lt "120" ]; then 
				device_expiration_biases[$data]=$(( bias + 15 ))
			fi  
		fi 

		#**********************************************************************
		#
		#
		#	THE FOLLOWING CONDITIONS DEFINE BEHAVIOR WHEN A DEVICE ARRIVES
		#	OR DEPARTS
		#	
		#
		#**********************************************************************

		#ECHO VALUES FOR DEBUGGING
		if [ "$cmd" == "NAME" ] ; then 
			
			#PRINTING FORMATING
			debug_name="$name"
			[ -z "$debug_name" ] && debug_name="${RED}[Error]${NC}"
			
			#PRINT RAW COMMAND; DEBUGGING
			log "${GREEN}[CMD-$cmd]	${NC}$data ${GREEN} $debug_name ${NC} $manufacturer${NC}"
		
		elif [ "$cmd" == "BEAC" ] && [ "$is_new" == true ] ; then 
			#PRINTING FORMATING
			debug_name="$name"
			[ -z "$debug_name" ] && debug_name="${RED}[Error]${NC}"
		
			log "${GREEN}[CMD-$cmd]	${GREEN}$data ${GREEN}$debug_name${NC} $manufacturer${NC}"
		
		elif [ "$cmd" == "PUBL" ] && [ "$is_new" == true ] ; then 
		
			log "${PURPLE}[CMD-$cmd]${NC}	$data $pdu_header $name $manufacturer PUBL_NUM: ${#static_device_log[@]}"

		elif [ "$cmd" == "RAND" ] && [ "$is_new" == true ] ; then 
			log "${RED}[CMD-$cmd]${NC}	$data $pdu_header $name RAND_NUM: ${#random_device_log[@]}"
			
			#TRIGGER ARRIVAL SCAN 
			list=$(arrival_scan_list)
			scan "$list" & 
		fi 

	done < main_pipe
done