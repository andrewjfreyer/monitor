#!/bin/bash

# ----------------------------------------------------------------------------------------
# GENERAL INFORMATION
# ----------------------------------------------------------------------------------------
#
# Written by Andrew J Freyer
# GNU General Public License
# http://github.com/andrewjfreyer/monitor
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
export version=0.2.200

if [ -z ${NO_COLOR} -o -z ${NOCOLOR} ] ; then
	#COLOR OUTPUT FOR RICH OUTPUT
	ORANGE=$'\e[1;33m'
	RED=$'\e[1;31m'
	NC=$'\e[0m'
	GREEN=$'\e[1;32m'
	PURPLE=$'\e[1;35m'
	BLUE=$'\e[1;34m'
	CYAN=$'\e[1;36m'
	YELLOW=$'\e[01;33m'
	REPEAT=$'\e[1A'
else
	:
fi

# ----------------------------------------------------------------------------------------
# BETA WARNING ONLY IF ON THE BETA CHANNEL
# ----------------------------------------------------------------------------------------

if [[ $(git status) =~ .*beta.* ]]; then 

	printf "\n%s\n" 	"${RED}===================================================${NC}"
	printf "\n%s\n"		"${RED}              ${PURPLE}*** BETA/DEV BRANCH ***${NC}"
	printf "\n%s\n" 	"${RED}===================================================${NC}"

fi 

#CAPTURE ARGS IN VAR TO USE IN SOURCED FILE
export RUNTIME_ARGS=("$@")

# ----------------------------------------------------------------------------------------
# SOURCES
# ----------------------------------------------------------------------------------------
#SOURCE SETUP AND ARGV FILES
source './support/argv'
source './support/init'

#SOURCE FUNCTIONS
source './support/mqtt'
source './support/log'
source './support/data'
source './support/btle'
source './support/time'
# ----------------------------------------------------------------------------------------
# CLEANUP ROUTINE 
# ----------------------------------------------------------------------------------------
clean() {
	#CLEANUP FOR TRAP
	pkill -f monitor.sh

	#REMOVE PIPES
	rm main_pipe &>/dev/null
	rm log_pipe &>/dev/null
	rm packet_pipe &>/dev/null

	#MESSAGE
	echo 'Exited.'
}

trap "clean" EXIT

# ----------------------------------------------------------------------------------------
# DEFINE VALUES AND VARIABLES
# ----------------------------------------------------------------------------------------

#CYCLE BLUETOOTH INTERFACE 
hciconfig "$PREF_HCI_DEVICE" down && sleep 3 && hciconfig "$PREF_HCI_DEVICE" up

#STOP OTHER INSTANCES OF MONITOR WITHOUT STOPPING THIS ONE
for pid in $(pidof -x "$(basename "$0")"); do
    if [ "$pid" != $$ ]; then
        kill -9 "$pid"
    fi 
done

#SETUP MAIN PIPE
rm main_pipe &>/dev/null
mkfifo main_pipe

#SETUP LOG PIPE
rm log_pipe &>/dev/null
mkfifo log_pipe

#SETUP BTLE PIPE
rm packet_pipe &>/dev/null
mkfifo packet_pipe


#DEFINE DEVICE TRACKING VARS
declare -A public_device_log
declare -A random_device_log
declare -A rssi_log

#STATIC DEVICE ASSOCIATIVE ARRAYS
declare -A known_public_device_log
declare -A expiring_device_log
declare -A known_static_device_scan_log
declare -A known_public_device_name
declare -A blacklisted_devices
declare -A beacon_mac_address_log
declare -A mqtt_aliases
declare -A advertisement_interval_observation

#LAST TIME THIS 
scan_pid=""
scan_type=""

#SCAN VARIABLES
now=$(date +%s)
last_rssi_scan=""
last_arrival_scan=$((now - 25))
last_depart_scan=$((now - 25))
first_arrive_scan=true

# ----------------------------------------------------------------------------------------
# POPULATE THE ASSOCIATIVE ARRAYS THAT INCLUDE INFORMATION ABOUT THE STATIC DEVICES
# WE WANT TO TRACK
# ----------------------------------------------------------------------------------------

#LOAD PUBLIC ADDRESSES TO SCAN INTO ARRAY, IGNORING COMMENTS
mapfile -t known_static_beacons < <(sed 's/#.\{0,\}//gi' < "$BEAC_CONFIG" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" )
mapfile -t known_static_addresses < <(sed 's/#.\{0,\}//gi' < "$PUB_CONFIG" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" )
mapfile -t address_blacklist < <(sed 's/#.\{0,\}//gi' < "$ADDRESS_BLACKLIST" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" )

#ASSEMBLE COMMENT-CLEANED BLACKLIST INTO BLACKLIST ARRAY
for addr in "${address_blacklist[@]^^}"; do 
	blacklisted_devices[$addr]=1
	printf "%s\n" "> ${RED}blacklisted device:${NC} $addr"
done 

# ----------------------------------------------------------------------------------------
# POPULATE MAIN DEVICE ARRAY
# ----------------------------------------------------------------------------------------

#LIST CONNECTED DEVICES
previously_connected_devices=$(echo "paired-devices" | bluetoothctl | grep -Eio "Device ([0-9A-F]{2}:){5}[0-9A-F]{2}" | sed 's/Device //gi')

#POPULATE KNOWN DEVICE ADDRESS
for addr in "${known_static_addresses[@]^^}"; do 

	#================= SHOULD WE USE AN ALIAS? =====================

	#WAS THERE A NAME HERE?
	known_name=$(grep -i "$addr" "$PUB_CONFIG" | tr "\\t" " " | sed 's/  */ /gi;s/#.\{0,\}//gi' | sed "s/$addr //gi;s/  */ /gi" )

   	#IF THE VALUE DOES NOT EXIST, USE THE KEY (MAC ADDRESS INSTEAD)
   	alias_value=${known_name//[^A-Za-z0-9]/_}

   	#LOWERCASE
  	alias_value=${alias_value,,}

  	#REMOVE FINAL UNDERSCORES SHOUDL THERE BE
   	alias_value=$(echo "$alias_value" | sed 's/[^0-9a-z]\{1,\}$//gi;s/^[^0-9a-z]\{1,\}//gi;s/__*/_/gi')

  	#DEFAULT
   	alias_value=${alias_value:-$addr}

   	#ALIASES
   	[ -n "$addr" ] && [ -n "$alias_value" ] && mqtt_aliases[$addr]="$alias_value" 

	#================= PROCESS THE KNOWN ADDR =====================

	#IF WE FOUND A NAME, RECORD IT
	[ -n "$known_name" ] && known_public_device_name[$addr]="$known_name"

	#CONNECTED?
	is_connected="not previously connected"
	[[ $previously_connected_devices =~ .*$addr.* ]] && is_connected="previously connected"

	#CORRECT 
	$PREF_ALIAS_MODE && mqtt_topic_branch=${mqtt_aliases[$addr]:-$addr} || mqtt_topic_branch=$addr

	#PUBLICATION TOPIC 
	pub_topic="$mqtt_topicpath/$mqtt_publisher_identity/$mqtt_topic_branch"
	$PREF_MQTT_SINGLE_TOPIC_MODE && pub_topic="$mqtt_topicpath/$mqtt_publisher_identity { id: $addr ... }"

	#FOR DEBUGGING
	printf "%s\n" "> ${GREEN}$addr${NC} confidence topic: $pub_topic (has $is_connected to $PREF_HCI_DEVICE)"
	[ "$PREF_DEVICE_TRACKER_REPORT" == 'true' ] && printf "%s\n" "> ${GREEN}$addr${NC} device_tracker topic: $pub_topic/$PREF_DEVICE_TRACKER_TOPIC_BRANCH [$PREF_DEVICE_TRACKER_AWAY_STRING or $PREF_DEVICE_TRACKER_HOME_STRING]"
done

# ----------------------------------------------------------------------------------------
# POPULATE BEACON ADDRESS ARRAY
# ----------------------------------------------------------------------------------------
#POPULATE KNOWN DEVICE ADDRESS
for addr in "${known_static_beacons[@]^^}"; do 

	#WAS THERE A NAME HERE?
	known_name=$(grep "$addr" "$BEAC_CONFIG" | tr "\\t" " " | sed 's/  */ /gi;s/#.\{0,\}//gi' | sed "s/$addr //gi;s/  */ /gi" )

	#================= SHOULD WE USE AN ALIAS? =====================

   	#IF THE VALUE DOES NOT EXIST, USE THE KEY (MAC ADDRESS INSTEAD)
   	alias_value=${known_name//[^A-Za-z0-9]/_}

   	#LOWERCASE
  	alias_value=${alias_value,,}

  	#REMOVE FINAL UNDERSCORES SHOUDL THERE BE
   	alias_value=$(echo "$alias_value" | sed 's/[^0-9a-z]\{1,\}$//gi;s/^[^0-9a-z]\{1,\}//gi;s/__*/_/gi')

  	#DEFAULT
   	alias_value=${alias_value:-$addr}

   	#ALIASES
   	[ -n "$addr" ] && [ -n "$alias_value" ] && mqtt_aliases[$addr]="$alias_value" 

	#IF WE FOUND A NAME, RECORD IT
	[ -n "$known_name" ] && known_public_device_name[$addr]="$known_name"

	#CORRECT 
	$PREF_ALIAS_MODE && mqtt_topic_branch=${mqtt_aliases[$addr]:-$addr} || mqtt_topic_branch=$addr

	#PUBLICATION TOPIC 
	pub_topic="$mqtt_topicpath/$mqtt_publisher_identity/$mqtt_topic_branch"
	$PREF_MQTT_SINGLE_TOPIC_MODE && pub_topic="$mqtt_topicpath/$mqtt_publisher_identity { id: $addr ... }"

	#FOR DBUGGING
	echo "> known beacon: $addr publishes to: $pub_topic"
done

# ----------------------------------------------------------------------------------------
# ASSEMBLE RSSI LISTS
# ----------------------------------------------------------------------------------------

connectable_present_devices () {

	#DEFINE LOCAL VARS
	local this_state
	local known_device_rssi
	local avg_total
	local scan_result

	#ITERATE THROUGH THE KNOWN DEVICES 
	local known_addr
	for known_addr in "${known_static_addresses[@]^^}"; do 
		
		#GET STATE; ONLY SCAN FOR DEVICES WITH SPECIFIC STATE
		this_state="${known_public_device_log[$known_addr]}"
		this_state=${this_state:-0}

		#TEST IF THIS DEVICE MATCHES THE TARGET SCAN STATE
		if [ "$this_state" == "1" ] && [[ "$previously_connected_devices" =~ .*$known_addr.* ]] ; then 
				
			#CREATE CONNECTION AND DETERMINE RSSI 
			#AVERAGE OVER THREE CYCLES; IF BLANK GIVE VALUE OF 100
			known_device_rssi=$(counter=0; \
				avg_total=0; \
				hcitool cc "$known_addr"; \
				avg_total=""; \
				for i in 1 2 3; \
				do scan_result=$(hcitool rssi "$known_addr" 2>&1); \
				scan_result=${scan_result//[^0-9]/}; \
				scan_result=${scan_result:-99}; \
				[[ "$scan_result" == "0" ]] && scan_result=99; \
				counter=$((counter+1)); \
				avg_total=$((avg_total + scan_result )); \
				sleep 0.5; \
				done; \
				printf "%s" "$(( avg_total / counter ))")

			#PUBLISH MESSAGE TO RSSI SENSOR 
			publish_rssi_message \
			"$known_addr" \
			"-$known_device_rssi"

			#REPORT 
			$PREF_VERBOSE_LOGGING && log "${CYAN}[CMD-RSSI]	${NC}$known_addr ${GREEN}$cmd ${NC}RSSI: -$known_device_rssi dBm ${NC}"

			#SET RSSI LOG
			rssi_log[$known_addr]="$known_device_rssi"
		fi 
	done
}

# ----------------------------------------------------------------------------------------
# ASSEMBLE SCAN LISTS
# ----------------------------------------------------------------------------------------

scannable_devices_with_state () {

	#DEFINE LOCAL VARS
	local return_list
	local timestamp
	local scan_state
	local scan_type_diff
	local this_state
	local last_scan
	local time_diff

	#SET VALUES AFTER DECLARATION
	timestamp=$(date +%s)
	scan_state="$1"

	#FIRST, TEST IF WE HAVE DONE THIS TYPE OF SCAN TOO RECENTLY
	if [ "$scan_state" == "1" ]; then 
		#SCAN FOR DEPARTED DEVICES
		scan_type_diff=$((timestamp - last_depart_scan))
	elif [ "$scan_state" == "0" ]; then 
		#SCAN FOR ARRIVED DEVICES
		scan_type_diff=$((timestamp - last_arrival_scan))
	fi 

	#REJECT IF WE SCANNED TO RECENTLY
	[ "$scan_type_diff" -lt "$PREF_MINIMUM_TIME_BETWEEN_SCANS" ] && return 0

	#SCAN ALL? SET THE DEFAULT SCAN STATE TO [X]
	scan_state=${scan_state:-2}
		 	
	#ITERATE THROUGH THE KNOWN DEVICES 
	local known_addr
	for known_addr in "${known_static_addresses[@]^^}"; do 
		
		#GET STATE; ONLY SCAN FOR DEVICES WITH SPECIFIC STATE
		this_state="${known_public_device_log[$known_addr]}"

		#IF WE HAVE NEVER SCANNED THIS DEVICE BEFORE, WE MARK AS 
		#SCAN STATE [X]; THIS ALLOWS A FIRST SCAN TO PROGRESS TO 
		#COMPLETION FOR ALL DEVICES
		this_state=${this_state:-3}

		#FIND LAST TIME THIS DEVICE WAS SCANNED
		last_scan="${known_static_device_scan_log[$known_addr]}"
		time_diff=$((timestamp - last_scan))

		#SCAN IF DEVICE HAS NOT BEEN SCANNED 
		#WITHIN LAST [X] SECONDS
		if [ "$time_diff" -gt "$PREF_MINIMUM_TIME_BETWEEN_SCANS" ]; then 

			#TEST IF THIS DEVICE MATCHES THE TARGET SCAN STATE
			if [ "$this_state" == "$scan_state" ]; then 
				#ASSEMBLE LIST OF DEVICES TO SCAN
				return_list="$return_list $this_state$known_addr"

			elif [ "$this_state" == "2" ] || [ "$this_state" == "3" ]; then

				#SCAN FOR ALL DEVICES THAT HAVEN'T BEEN RECENTLY SCANNED; 
				#PRESUME DEVICE IS ABSENT
				return_list="$return_list $this_state$known_addr"
			fi 
		fi 
	done
 
	#RETURN LIST, CLEANING FOR EXCESS SPACES OR STARTING WITH SPACES
	return_list=$(echo "$return_list" | sed 's/^ //gi;s/ $//gi;s/  */ /gi')

	#RETURN THE LIST
	echo "$return_list"
}

# ----------------------------------------------------------------------------------------
# SCAN FOR DEVICES
# ----------------------------------------------------------------------------------------

perform_complete_scan () {
	#IF WE DO NOT RECEIVE A SCAN LIST, THEN RETURN 0
	if [ -z "$1" ]; then
		#log "${GREEN}[CMD-INFO]	${GREEN}**** Rejected group scan. No devices in desired state. **** ${NC}"
		return 0
	fi

	#REPEAT THROUGH ALL DEVICES THREE TIMES, THEN RETURN 
	local repetitions=2
	[ -n "$2" ] && repetitions="$2"
	[ "$repetitions" -lt "1" ] && repetitions=1

	#PRE
	local previous_state=0
	[ -n "$3" ] && previous_state="$3"

	#SCAN TYPE
	local transition_type="arrival"
	[ "$previous_state" == "1" ] && transition_type="departure"

	#INTERATION VARIABLES
	local devices="$1"
	local devices_next="$devices"
	local scan_start=""
	local scan_duration=""
	local should_report=""
	local manufacturer="Unknown"
	local has_requested_collaborative_depart_scan=false
	
	#LOG START OF DEVICE SCAN 
	$PREF_MQTT_REPORT_SCAN_MESSAGES && publish_cooperative_scan_message "$transition_type/start"
	$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INFO]	${GREEN}**** started $transition_type scan [x$repetitions max rep] **** ${NC}"

	#ITERATE THROUGH THE KNOWN DEVICES 	
	local repetition 
	for repetition in $(seq 1 $repetitions); do

		#SET DONE TO MAIN PIPE
		printf "%s\n" "DONE" > main_pipe

		#SET DEVICES
		devices="$devices_next"

		#ITERATE THROUGH THESE 
		local known_addr
		local known_addr_stated
		local expected_name
		local name_raw
		local name
		local scan_end
		local scan_duration
		local percent_confidence
		local adjusted_delay

		for known_addr_stated in $devices; do 

			#EXTRACT KNOWN ADDRESS FROM STATE-PREFIXED KNOWN ADDRESS, IF PRESENT
			if [[ "$known_addr_stated" =~ .*[0-9A-Fa-f]{3}.* ]]; then 
				#SET KNOWN ADDRESS
				known_addr=${known_addr_stated:1}

				#SET PREVIOUS STATE
				previous_state=${known_addr_stated:0:1}
			else
				#THIS ELEMENT OF THE ARRAY DOES NOT CONTAIN A STATE PREFIX; GO WITH GLOBAL
				#STATE SCAN TYPE
				known_addr=$known_addr_stated
			fi 

			#DETERMINE MANUFACTUERE
			manufacturer="$(determine_manufacturer "$known_addr")"
			manufacturer=${manufacturer:-Unknown}

			#IN CASE WE HAVE A BLANK ADDRESS, FOR WHATEVER REASON
			[ -z "$known_addr" ] && continue

			#DETERMINE START OF SCAN
			scan_start="$(date +%s)"

			#GET LOCAL NAME
			expected_name="$(determine_name "$known_addr")"
			expected_name=${expected_name:-Unknown}

			#DEBUG LOGGING
			$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SCAN]	${GREEN}(No. $repetition)${NC} $known_addr $transition_type? ${NC}"

			#PERFORM NAME SCAN FROM HCI TOOL. THE HCITOOL CMD 0X1 0X0019 IS POSSIBLE, BUT HCITOOL NAME
			#SCAN PERFORMS VERIFICATIONS THAT REDUCE FALSE NEGATIVES. 

			#L2SCAN MAY INVOLVE LESS INTERFERENCE
			name_raw=$(hcitool -i "$PREF_HCI_DEVICE" name "$known_addr" 2>/dev/null)
			name=$(echo "$name_raw" | grep -ivE 'input/output error|invalid device|invalid|error|network')

			#COLLECT STATISTICS ABOUT THE SCAN 
			scan_end="$(date +%s)"
			scan_duration=$((scan_end - scan_start))

			#MARK THE ADDRESS AS SCANNED SO THAT IT CAN BE LOGGED ON THE MAIN PIPE
			printf "%s\n" "SCAN$known_addr" > main_pipe & 

			#IF STATUS CHANGES TO PRESENT FROM NOT PRESENT, REMOVE FROM VERIFICATIONS
			if [ -n "$name" ] && [ "$previous_state" == "0" ]; then 

				#PUSH TO MAIN POPE
				printf "%s\n" "NAME$known_addr|$name" > main_pipe 

				#DEVICE FOUND; IS IT CHANGED? IF SO, REPORT 
				publish_presence_message \
				"id=$known_addr" \
				"confidence=100" \
				"name=$expected_name" \
				"manufacturer=$manufacturer" \
				"type=KNOWN_MAC"

				#REMOVE FROM SCAN
				devices_next=$(echo "$devices_next" | sed "s/$known_addr_stated//gi;s/  */ /gi")

			elif [ -n "$name" ] && [ "$previous_state" == "3" ]; then 
				#HERE, WE HAVE FOUND A DEVICE FOR THE FIRST TIME
				devices_next=$(echo "$devices_next" | sed "s/$known_addr_stated//gi;s/  */ /gi")

				#NEED TO UPDATE STATE TO MAIN THREAD
				printf "%s\n" "NAME$known_addr|$name" > main_pipe 

				#NEVER SEEN THIS DEVICE; NEED TO PUBLISH STATE MESSAGE
				publish_presence_message \
				"id=$known_addr" "confidence=100" \
				"name=$expected_name" \
				"manufacturer=$manufacturer" \
				"type=KNOWN_MAC"

				#COOPERATIVE SCAN ON RESTART
				$PREF_TRIGGER_MODE_REPORT_OUT && publish_cooperative_scan_message "arrive" 


			elif [ -n "$name" ] && [ "$previous_state" == "1" ]; then 

				#THIS DEVICE IS STILL PRESENT; REMOVE FROM VERIFICATIONS
				devices_next=$(echo "$devices_next" | sed "s/$known_addr_stated//gi;s/  */ /gi")

				#NEED TO REPORT? 
				if [[ $should_report =~ .*$known_addr.* ]] || [ "$PREF_REPORT_ALL_MODE" == true ] ; then 			
					#REPORT PRESENCE
					publish_presence_message \
					"id=$known_addr" \
					"confidence=100" \
					"name=$expected_name" \
					"manufacturer=$manufacturer" \
					"type=KNOWN_MAC"			
				fi 
			fi 

			#SHOULD WE REPORT A DROP IN CONFIDENCE? 
			if [ -z "$name" ] && [ "$previous_state" == "1" ]; then 

				#CALCULATE PERCENT CONFIDENCE
				percent_confidence=$(echo "scale=1; ($repetitions - $repetition + 1) / $repetitions * 90" | bc )

				#FALLBACK TO REMOVE DECIMAL AND PRINT INTEGER ONLY
				percent_confidence=${percent_confidence%.*}

				#ONLY PUBLISH COOPERATIVE SCAN MODE IF WE ARE NOT IN TRIGGER MODE
				#TRIGGER ONLY MODE DOES NOT SEND COOPERATIVE MESSAGES
				if [ "$has_requested_collaborative_depart_scan" == false ]; then 
					#SEND THE MESSAGE IF APPROPRIATE
					if [ "$percent_confidence" -lt "$PREF_COOPERATIVE_SCAN_THRESHOLD" ] && $PREF_TRIGGER_MODE_REPORT_OUT; then 
						has_requested_collaborative_depart_scan=true
						publish_cooperative_scan_message "depart" 
					fi 
				fi 

				#REPORT PRESENCE OF DEVICE
				publish_presence_message \
				"id=$known_addr" \
				"confidence=$percent_confidence" \
				"name=$expected_name" \
				"manufacturer=$manufacturer" \
				"type=KNOWN_MAC"

				#IF WE DO FIND A NAME LATER, WE SHOULD REPORT OUT 
				should_report="$should_report$known_addr"

			elif [ -z "$name" ] && [ "$previous_state" == "3" ]; then 

				#NEVER SEEN THIS DEVICE; NEED TO PUBLISH STATE MESSAGE
				publish_presence_message \
				"id=$known_addr" \
				"confidence=0" \
				"name=$expected_name" \
				"manufacturer=$manufacturer" \
				"type=KNOWN_MAC"

				#PUBLISH MESSAGE TO RSSI SENSOR 
				publish_rssi_message \
				"$known_addr" \
				"-99"

				#NREMOVE FROM THE SCAN LIST TO THE MAIN BECAUSE THIS IS A BOOT UP 
				devices_next=$(echo "$devices_next" | sed "s/$known_addr_stated//gi;s/  */ /gi")

				#PUBLISH A NOT PRESENT TO THE NAME PIPE
				printf "%s\n" "NAME$known_addr|" > main_pipe 

				#COOPERATIVE SCAN ON RESTART
				$PREF_TRIGGER_MODE_REPORT_OUT && publish_cooperative_scan_message "depart"

			elif [ -z "$name" ] && [ "$previous_state" == "0" ]; then 

				if [ "$PREF_REPORT_ALL_MODE" == true ] ; then 			
					#REPORT PRESENCE
					publish_presence_message \
					"id=$known_addr" \
					"confidence=0" \
					"name=$expected_name" \
					"manufacturer=$manufacturer" \
					"type=KNOWN_MAC"			

					#PUBLISH MESSAGE TO RSSI SENSOR 
					publish_rssi_message \
					"$known_addr" \
					"-99"

				fi 
			fi 

			#IF WE HAVE NO MORE DEVICES TO SCAN, IMMEDIATELY RETURN
			[ -z "$devices_next" ] && break

			#TO PREVENT HARDWARE PROBLEMS
			if [ "$scan_duration" -lt "$PREF_INTERSCAN_DELAY" ]; then 
				adjusted_delay="$((PREF_INTERSCAN_DELAY - scan_duration))"

				if [ "$adjusted_delay" -gt "0" ]; then 
					sleep "$adjusted_delay"
				else
					#DEFAULT MINIMUM SLEEP
					sleep "$PREF_INTERSCAN_DELAY"
				fi 
			else
				#DEFAULT MINIMUM SLEEP
				sleep "$PREF_INTERSCAN_DELAY"
			fi 
		done

		#ARE WE DONE WITH ALL DEVICES? 
		[ -z "$devices_next" ] && break
	done 

	#ANYHTING LEFT IN THE DEVICES GROUP IS NOT PRESENT
	local known_addr_stated
	local known_addr
	local expected_name
	for known_addr_stated in $devices_next; do 
		#EXTRACT KNOWN ADDRESS FROM STATE-PREFIXED KNOWN ADDRESS, IF PRESENT
		if [[ "$known_addr_stated" =~ .*[0-9A-Fa-f]{3}.* ]]; then 
			#SET KNOWN ADDRESS
			known_addr=${known_addr_stated:1}
		else
			#THIS ELEMENT OF THE ARRAY DOES NOT CONTAIN A STATE PREFIX
			known_addr=$known_addr_stated
		fi

		#PUBLISH MESSAGE
		if [ ! "$previous_state" == "0" ]; then 
			expected_name="$(determine_name "$known_addr")"
			expected_name=${expected_name:-Unknown}

					#DETERMINE MANUFACTUERE
			manufacturer="$(determine_manufacturer "$known_addr")"
			manufacturer=${manufacturer:-Unknown}

			#PUBLISH PRESENCE METHOD
			publish_presence_message \
			"id=$known_addr" \
			"confidence=0" \
			"name=$expected_name" \
			"manufacturer=$manufacturer" \
			"type=KNOWN_MAC"

			#PUBLISH MESSAGE TO RSSI SENSOR 
			publish_rssi_message \
			"$known_addr" \
			"-99"
		fi 

		printf "%s\n" "NAME$known_addr|" > main_pipe 
	done


	#SET DONE TO MAIN PIPE
	printf "%s\n" "DONE" > main_pipe

	#GROUP SCAN FINISHED
	$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INFO]	${GREEN}**** completed $transition_type scan **** ${NC}"

	#PUBLISH END OF COOPERATIVE SCAN
	$PREF_MQTT_REPORT_SCAN_MESSAGES && publish_cooperative_scan_message "$transition_type/end"
}

# ----------------------------------------------------------------------------------------
# SCAN TYPE FUNCTIONS 
# ----------------------------------------------------------------------------------------

perform_departure_scan () {

	#SET SCAN TYPE
 	local depart_list
 	depart_list=$(scannable_devices_with_state 1)

 	#LOCAL SCAN ACTIVE VARIABLE
	local scan_active
	scan_active=true 

 	#SCAN ACTIVE?
 	kill -0 "$scan_pid" >/dev/null 2>&1 && scan_active=true || scan_active=false 
	
	#ONLY ASSEMBLE IF WE NEED TO SCAN FOR ARRIVAL
	if [ "$scan_active" == false ] ; then 

	 	#ADD A FLAG TO SCAN FOR 
		[ -n "$depart_list" ] && printf "%s\n" "BEXP" > main_pipe & 

		#ONCE THE LIST IS ESTABLISHED, TRIGGER SCAN OF THESE DEVICES IN THE BACKGROUND
		perform_complete_scan "$depart_list" "$PREF_DEPART_SCAN_ATTEMPTS" "1" & 
		disown "$!"

		scan_pid=$!
		scan_type=1
	else 
		#HERE A DEPART SCAN IS ACTIVE; ENQUEUE ANOTHER DEPART SCAN AFTER DELAY 
		[ "$scan_type" == "0" ] && sleep 5 && printf "%s\n" "ENQUdepart" > main_pipe & 	
	fi
}

perform_arrival_scan () {
	#SET SCAN TYPE
 	local arrive_list
 	arrive_list=$(scannable_devices_with_state 0)

	#LOCAL SCAN ACTIVE VARIABLE
	local scan_active
	scan_active=true 

 	#SCAN ACTIVE?
 	kill -0 "$scan_pid" >/dev/null 2>&1 && scan_active=true || scan_active=false 
		
	#ONLY ASSEMBLE IF WE NEED TO SCAN FOR ARRIVAL
	if [ "$scan_active" == false ] ; then 

		#FIRST SCAN IS DEAD
		first_arrive_scan=false

		#ONCE THE LIST IS ESTABLISHED, TRIGGER SCAN OF THESE DEVICES IN THE BACKGROUND
		perform_complete_scan "$arrive_list" "$PREF_ARRIVAL_SCAN_ATTEMPTS" "0" & 
		disown "$!"

		scan_pid=$!
		scan_type=0
	else 
		#HERE A DEPART SCAN IS ACTIVE; ENQUEUE ANOTHER DEPART SCAN AFTER DELAY
		[ "$scan_type" == "1" ] && sleep 5 && printf "%s\n" "ENQUarrive" > main_pipe & 
	fi 
}

# ----------------------------------------------------------------------------------------
# NAME DETERMINATIONS
# ----------------------------------------------------------------------------------------

determine_name () {

	#SET DATA 
	local address
	address="$1"

	#RETURN ADDRESS
	[ -z "$address" ] && return 0

	#ALTERNATIVE ADDRESS 
	local alternate_address
	alternate_address="$2"
	alternate_address=${alternate_address:-Unknown}
	
	#IF IS NEW AND IS PUBLIC, SHOULD CHECK FOR NAME
	local expected_name
	expected_name="${known_public_device_name[$address]}"

	#ALTERNATE NAME? 
	[ -z "$expected_name" ]	&& expected_name="${known_public_device_name[$alternate_address]}"

	#FIND PERMANENT DEVICE NAME OF PUBLIC DEVICE
	if [ -z "$expected_name" ]; then 

		#CHECK CACHE
		expected_name=$(grep "$address" < "$base_directory/.public_name_cache" | awk -F "\t" '{print $2}')

		#IF CACHE DOES NOT EXIST, TRY TO SCAN
		if [ -z "$expected_name" ]; then 

			#DOES SCAN PROCESS CURRENTLY EXIST? 
			kill -0 "$scan_pid" >/dev/null 2>&1 && scan_active=true || scan_active=false 

		 	#ONLY SCAN IF WE ARE NOT OTHERWISE SCANNING; NAME FOR THIS DEVICE IS NOT IMPORTANT
		 	if [ "$scan_active" == false ] ; then 

				#FIND NAME OF THIS DEVICE
				expected_name=$(hcitool -i "$PREF_HCI_DEVICE" name "$address" 2>/dev/null)

				#IS THE EXPECTED NAME BLANK? 
				if [ -n "$expected_name" ]; then 

					#ADD TO SESSION ARRAY
					known_public_device_name[$address]="$expected_name"

					#ADD TO CACHE
					echo "$address	$expected_name" >> .public_name_cache
				else
					#ADD TO CACHE TO PREVENT RE-SCANNING
					echo "$address	Undeterminable" >> .public_name_cache

				fi 
			fi 
		else
			#WE HAVE A CACHED NAME, ADD IT BACK TO THE PUBLIC DEVICE ARRAY 
			known_public_device_name[$address]="$expected_name"
		fi
	fi 

	printf "%s\n" "$expected_name"
}

# ----------------------------------------------------------------------------------------
# BACKGROUND PROCESSES
# ----------------------------------------------------------------------------------------

#SET LOG
(rm .pids) 2>&1 1>/dev/null 

log_listener &
listener_pid="$!"
echo "> log listener pid = $listener_pid" >> .pids
$PREF_VERBOSE_LOGGING && echo "> log listener pid = $listener_pid"
disown "$listener_pid"

btle_scanner & 
btle_scan_pid="$!"
echo "> btle scan pid = $btle_scan_pid" >> .pids
$PREF_VERBOSE_LOGGING && echo "> btle scan pid = $btle_scan_pid"
disown "$btle_scan_pid"

btle_text_listener &
btle_text_pid="$!"
echo "> btle text pid = $btle_text_pid" >> .pids
$PREF_VERBOSE_LOGGING && echo "> btle text pid = $btle_text_pid"
disown "$btle_text_pid"

btle_listener &
btle_listener_pid="$!"
echo "> btle listener pid = $btle_listener_pid" >> .pids
$PREF_VERBOSE_LOGGING && echo "> btle listener pid = $btle_listener_pid" 
disown "$btle_listener_pid"

mqtt_listener &
mqtt_pid="$!"
echo "> mqtt listener pid = $mqtt_pid" >> .pids
$PREF_VERBOSE_LOGGING && echo "> mqtt listener pid = $mqtt_pid"
disown "$mqtt_pid"

btle_packet_listener &
btle_packet_listener_pid="$!"
echo "> packet listener pid = $btle_packet_listener_pid" >> .pids
$PREF_VERBOSE_LOGGING && echo "> packet listener pid = $btle_packet_listener_pid"
disown "$btle_packet_listener_pid"

beacon_database_expiration_trigger &
beacon_database_expiration_trigger_pid="$!"
echo "> beacon database time trigger pid = $beacon_database_expiration_trigger_pid" >> .pids
$PREF_VERBOSE_LOGGING && echo "> beacon database time trigger pid = $beacon_database_expiration_trigger_pid"
disown "$beacon_database_expiration_trigger_pid"

# ----------------------------------------------------------------------------------------
# MAIN LOOPS. INFINITE LOOP CONTINUES, NAMED PIPE IS READ INTO SECONDARY LOOP
# ----------------------------------------------------------------------------------------

#MAIN LOOP
while true; do 
	
	#READ FROM THE MAIN PIPE
	while read -r event; do

		#DIVIDE EVENT MESSAGE INTO TYPE AND DATA
		cmd="${event:0:4}"
		data="${event:4}"
		timestamp=$(date +%s)
		uptime=$((timestamp - now))

		#FLAGS TO DETERMINE FRESHNESS OF DATA
		is_new=false
		should_update=false
		did_change=false
		is_apple_beacon=false

		#CLEAR DATA IN NONLOCAL VARS
		manufacturer="unknown"
		current_associated_beacon_mac_address=""
		name=""
		expected_name=""
		mac=""
		rssi=""
		adv_data=""
		resolvable=""
		pdu_header=""
		power=""
		major=""
		minor=""
		uuid=""
		beacon_type="GENERIC_BEACON"
		beacon_last_seen=""
		key_last_seen=""
		uuid_reference=""
		last_appearance=""
		beacon_uuid_key=""
		instruction_timestamp=""
		instruction_delay=""
		observation_made=false
		most_recent_beacon=""
		observed_max_advertisement_interval=""
		temp_observation=""
		device_state=""

		#PROCEED BASED ON COMMAND TYPE
		if [ "$cmd" == "ENQU" ] && [ "$uptime" -gt "$PREF_STARTUP_SETTLE_TIME" ]; then 

			#WE HAVE AN ENQUEUED OPPOSITE SCAN; NEED TO TRIGGER THAT SCAN
			if [ "$data" == "arrive" ]; then 

				#LOG
				$PREF_VERBOSE_LOGGING && log "${GREEN}[ENQ-ARR]	${NC}Enqueued arrival scan triggered.${NC}" 

				#WAIT 5 SECONDS
				sleep 5
				
				#TRIGGER 
				perform_arrival_scan

			elif [ "$data" == "depart" ]; then 		
				#LOG
				$PREF_VERBOSE_LOGGING && log "${GREEN}[ENQ-DEP]	${NC}Enqueued depart scan triggered.${NC}" 

				#WAIT 5 SECONDS
				sleep 5

				#TRIGGER 
				perform_departure_scan
			fi

		elif [ "$cmd" == "RAND" ]; then 
			#PARSE RECEIVED DATA
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			pdu_header=$(echo "$data" | awk -F "|" '{print $2}')
			name=$(echo "$data" | awk -F "|" '{print $3}')
			rssi=$(echo "$data" | awk -F "|" '{print $4}')
			adv_data=$(echo "$data" | awk -F "|" '{print $5}')
			manufacturer=$(echo "$data" | awk -F "|" '{print $6}')
			device_type=$(echo "$data" | awk -F "|" '{print $7}')
			flags=$(echo "$data" | awk -F "|" '{print $8}')
			oem_data=$(echo "$data" | awk -F "|" '{print $9}')
			instruction_timestamp=$(echo "$data" | awk -F "|" '{print $10}')
			resolvable=$(echo "$data" | awk -F "|" '{print $11}')
			hex_data=$(echo "$data" | awk -F "|" '{print $12}')

			#FIND DELAY BASED ON INSTRUCTINO TIMESTAMP
			instruction_delay=$((timestamp - instruction_timestamp))

			#GET LAST RSSI
			rssi_latest="${rssi_log[$mac]}"
			
			#IF WE HAVE A NAME; UNSEAT FROM RANDOM AND ADD TO STATIC
			#THIS IS A BIT OF A FUDGE, A RANDOM DEVICE WITH A LOCAL 
			#NAME IS TRACKABLE, SO IT'S UNLIKELY THAT ANY CONSUMER
			#ELECTRONIC DEVICE OR CELL PHONE IS ASSOCIATED WITH THIS 
			#ADDRESS. CONSIDER THE ADDRESS AS A STATIC ADDRESS

			#ALSO NEED TO CHECK WHETHER THE RANDOM BROADCAST
			#IS INCLUDED IN THE KNOWN DEVICES LOG...

			if [ -n "${public_device_log[$mac]}" ]; then
					
				#GET INTERVAL SINCE LAST SEEN
				last_appearance=${public_device_log[$mac]:-$timestamp}
				if [ "$observation_made" == false ]; then 
					observation_made=true
					temp_observation="" && temp_observation=$((((timestamp - last_appearance - 1 + PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) / PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) * PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP))
					[ "$temp_observation" -gt "${advertisement_interval_observation[$mac]:-0}" ] && [ "$temp_observation" -gt "0" ] && [ "$temp_observation" -lt "300" ] &&	advertisement_interval_observation[$mac]=$temp_observation
					
				fi

				#IS THIS A NEW STATIC DEVICE?
				public_device_log[$mac]="$timestamp"
				[ -n "$rssi" ] && rssi_log[$mac]="$rssi"
				cmd="PUBL"

				#BEACON TYPE
				beacon_type="GENERIC_BEACON_PUBLIC"

			else
				#DO WE HAVE A NAME FOR THIS MAC ADDRESSS? 
				#THAT IS NOT IN THE PUBLIC DEVICE ARRAY?
				expected_name="${known_public_device_name[$mac]}"

				#DOES THIS DEVICE HAVE A NAME? 
				if [ -n "$name" ] || [ -n "$expected_name" ]; then 
					#RESET COMMAND
					cmd="PUBL"
					unset "random_device_log[$mac]"

					#BEACON TYPE
					beacon_type="GENERIC_BEACON_RANDOM"

					#SAVE THE NAME
					known_public_device_name[$mac]="$name"
					[ -n "$rssi" ] && rssi_log[$mac]="$rssi"

					#IS THIS A NEW STATIC DEVICE?
					if [ -n "${public_device_log[$mac]}" ]; then 					
						#GET INTERVAL SINCE LAST SEEN
						last_appearance=${public_device_log[$mac]:-$timestamp}
						if [ "$observation_made" == false ]; then 
							observation_made=true
							temp_observation="" && temp_observation=$((((timestamp - last_appearance - 1 + PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) / PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) * PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP))
							[ "$temp_observation" -gt "${advertisement_interval_observation[$mac]:-0}" ] && [ "$temp_observation" -gt "0" ] && [ "$temp_observation" -lt "300" ] &&	advertisement_interval_observation[$mac]=$temp_observation
							
						fi
						
					else 
						is_new=true
					fi 

					public_device_log[$mac]="$timestamp"

				else 

					#DATA IS RANDOM MAC Addr.; ADD TO LOG
					[ -z "${random_device_log[$mac]}" ] && is_new=true

					#WHEN DOES THIS RANDOM BEACON EXPIRE?
					last_appearance=${random_device_log[$mac]:-$timestamp}
					if [ "$observation_made" == false ]; then 
						observation_made=true
						temp_observation="" && temp_observation=$((((timestamp - last_appearance - 1 + PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) / PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) * PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP))
						[ "$temp_observation" -gt "${advertisement_interval_observation[$mac]:-0}" ] && [ "$temp_observation" -gt "0" ] && [ "$temp_observation" -lt "300" ] &&	advertisement_interval_observation[$mac]=$temp_observation
						
					fi
					
					#ONLY ADD THIS TO THE DEVICE LOG 
					random_device_log[$mac]="$timestamp"
					[ -n "$rssi" ] && rssi_log[$mac]="$rssi"
				fi 
			fi

		elif [ "$cmd" == "SCAN" ]; then 
			#SET MAC = DATA
			mac=$data

			#ADD TO THE SCAN LOG
			known_static_device_scan_log[$mac]=$(date +%s)
			continue

		elif [ "$cmd" == "DONE" ]; then 

			#SCAN MODE IS COMPLETE
			scan_pid=""

			#SET LAST ARRIVAL OR DEPARTURE SCAN
			[ "$scan_type" == "0" ] && last_arrival_scan=$(date +%s)
			[ "$scan_type" == "1" ] && last_depart_scan=$(date +%s)

			scan_type=""
			continue

		elif [ "$cmd" == "MQTT" ] && [ "$uptime" -gt "$PREF_STARTUP_SETTLE_TIME" ]; then 

			#GET INSTRUCTION 
			topic_path_of_instruction="${data%%|*}"
			data_of_instruction="${data##*|}"

			#IGNORE INSTRUCTION FROM SELF
			if [[ ${data_of_instruction^^} =~ .*${mqtt_publisher_identity^^}.* ]] || [[ ${topic_path_of_instruction^^} =~ .*${mqtt_publisher_identity^^}.* ]]; then 
				continue
			fi 

			#GET THE TOPIC 
			mqtt_topic_branch=$(basename "$topic_path_of_instruction")

			#NORMALIZE TO UPPERCASE
			mqtt_topic_branch=${mqtt_topic_branch^^}

			if [[ $mqtt_topic_branch =~ .*ARRIVE.* ]]; then 

				#IGNORE OR PASS MQTT INSTRUCTION?
				scan_type_diff=$((timestamp - last_arrival_scan))
				if [ "$scan_type_diff" -gt "$PREF_MINIMUM_TIME_BETWEEN_SCANS" ]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] arrive scan requested ${NC}"
					perform_arrival_scan
				else
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${RED}fail mqtt${NC}] arrive scan rejected due to recent scan ${NC}"
				fi 
				
			elif [[ $mqtt_topic_branch =~ .*KNOWN\ DEVICE\ STATES.* ]]; then 				

				#SIMPLE STATUS MESSAGE FOR KNOWN
				device_state=""
				for addr in "${known_static_addresses[@]^^}"; do 
					#GET STATE; ONLY SCAN FOR DEVICES WITH SPECIFIC STATE
					device_state="${known_public_device_log[$addr]}"
					device_state=${device_state:-0}

					#SET TO CONFIDENCE RANGE
					[ "$device_state" == "1" ] && device_state=100

					#SEND STATUS UPDATE
					publish_presence_message  \
					"id=$addr" \
					"confidence=$device_state" \
					"name=${known_public_device_name[$addr]}" \
					"type=KNOWN_MAC"

				done
				
			elif [[ $mqtt_topic_branch =~ .*ADD\ STATIC\ DEVICE.* ]] || [[ $mqtt_topic_branch =~ .*DELETE\ STATIC\ DEVICE.* ]]; then 

				if [[ "${data_of_instruction^^}" =~ ([A-F0-9]{2}:){5}[A-F0-9]{2} ]]; then 
					#GET MAC ADDRESSES
					mac="${BASH_REMATCH}"
					if [ ! ${known_public_device_name[$mac]+true} ]; then 

						#HERE, WE KNOW THAT WE HAVE A MAC ADDRESS AND A VALID INSTRUCTION
						if [[ $mqtt_topic_branch =~ .*ADD\ STATIC\ DEVICE.* ]]; then 
							#WAS THERE A NAME HERE?
							name=$(echo "$data_of_instruction" | tr "\\t" " " | sed 's/  */ /gi;s/#.\{0,\}//gi' | sed "s/$mac //gi;s/  */ /gi" )

							#IF THE VALUE DOES NOT EXIST, USE THE KEY (MAC ADDRESS INSTEAD)
						   	alias_value=${name//[^A-Za-z0-9]/_}

						   	#LOWERCASE
						  	alias_value=${alias_value,,}

						  	#REMOVE FINAL UNDERSCORES SHOUDL THERE BE
						   	alias_value=$(echo "$alias_value" | sed 's/[^0-9a-z]\{1,\}$//gi;s/^[^0-9a-z]\{1,\}//gi;s/__*/_/gi')

							#ADD TO KNOWN PUBLIC DEVICE ARRAY
							known_public_device_name[$mac]="$name"

							#ESTABLISH ALIAS
							[ -n "$mac" ] && [ -n "$alias_value" ] && mqtt_aliases[$mac]="$alias_value" 

							#ADD TO KNOWN_STATIC_ADDRESSES FILE
							echo "$mac ${name:-}" >> $PUB_CONFIG
							
							#UPDATE FROM STATIC ADDRESSES TOO
							mapfile -t known_static_addresses < <(sed 's/#.\{0,\}//gi' < "$PUB_CONFIG" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" )

							#LOGGING
							$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] new static device ${GREEN}$mac${NC} added with alias ${GREEN}${name:-none}${NC}"

							#PERFORM ARRIVAL SCAN FOR NEW DEVICE
							perform_arrival_scan
						fi
						
					else

						#ONLY PERFORM IF WE HAVE A DEVICE TO DELETE
						if [[ $mqtt_topic_branch =~ .*DELETE\ STATIC\ DEVICE.* ]]; then 

							#HERE, WE NOW THAT WE HAVE TO DELETE THE DEVICE WITH THE MAC ADDRESS
							sed -i '/'"$mac"'/Id' $PUB_CONFIG

							#UNSET FROM MEMORY
							unset "known_public_device_name[$mac]"
							unset "mqtt_aliases[$mac]"

							#REMOVE FROM STATIC ADDRESSES TOO
							mapfile -t known_static_addresses < <(sed 's/#.\{0,\}//gi' < "$PUB_CONFIG" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" )

							#LOGGING
							$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] removed static device ${GREEN}$mac${NC}"

							#PERFORM DEPARTURE SCAN TO MAKE SURE THIS DEVICE IS GONE
							perform_departure_scan
						fi 
					fi 
				else
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${RED}fail mqtt${NC}] new static device request did not contain a device address ${NC}"
				fi

			elif [[ $mqtt_topic_branch =~ .*DEPART.* ]]; then 
				
				#IGNORE OR PASS MQTT INSTRUCTION?
				scan_type_diff=$((timestamp - last_depart_scan))
				if [ "$scan_type_diff" -gt "$PREF_MINIMUM_TIME_BETWEEN_SCANS" ]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] depart scan requested ${NC}"
					perform_departure_scan
				else
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${RED}fail mqtt${NC}] depart scan rejected due to recent scan ${NC}"
				fi 	

			elif [[ $mqtt_topic_branch =~ .*RSSI.* ]]; then 
				
				#SCAN FOR RSSI
				difference_last_rssi=$((timestamp - last_rssi_scan))

				#ONLY EVER 5 MINUTES
				if [ "$difference_last_rssi" -gt "100" ] || [ -z "$last_rssi_scan" ] ; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] rssi update scan requested ${NC}"
					connectable_present_devices
					last_rssi_scan=$(date +%s)
				else
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${RED}fail mqtt${NC}] rssi update scan rejected due to recent scan ${NC}"
				fi 

			elif [[ $mqtt_topic_branch =~ .*RESTART.* ]]; then 
				$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] service restart requested ${NC}"
				
				#RESTART SYSTEM
				systemctl restart monitor.service	

				#exit
				exit 0	

			elif [[ $mqtt_topic_branch =~ .*ECHO.* ]] && [[ -z "$data_of_instruction" ]]; then 
				$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] echo  ${NC}"				
				
				mqtt_echo
			
			elif [[ $mqtt_topic_branch =~ .*UPDATEBETA.* ]]; then

				$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] beta update requested ${NC}"				
				
				#GIT FETCH
				git fetch
				
				#GIT FETCH
				git checkout beta				
				
				#GIT PULL
				git pull

				#RESTART SYSTEM
				systemctl restart monitor.service	

				#exit
				exit 0
				
			elif [[ $mqtt_topic_branch =~ .*UPDATE.* ]]; then 

				$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-INST]	${NC}[${GREEN}pass mqtt${NC}] update requested ${NC}"				
				
				#GIT FETCH
				git fetch
				
				#GIT FETCH
				git checkout master				
				
				#GIT PULL
				git pull

				#RESTART SYSTEM
				systemctl restart monitor.service	

				#exit
				exit 0

			elif [[ ${mqtt_topic_branch^^} =~ .*START.* ]] || [[ ${mqtt_topic_branch^^} =~ .*END.* ]] || [[ ${mqtt_topic_branch^^} =~ .*STATUS.* ]]; then 
				#IGNORE ERRORS
				#$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SCAN]	${NC}[${RED}ignore mqtt${NC}] ${BLUE}topic:${NC} $topic_path_of_instruction ${BLUE}data:${NC} $data_of_instruction${NC}"

				continue

			elif [[ ${mqtt_topic_branch^^} =~ .*[0-9A-F:-]{2,}.* ]]; then 
				#LOG THE OUTPU
				#log "${GREEN}[CMD-INST]	${NC}[${ORANGE}ignored mqtt${NC}] ${BLUE}topic:${NC} $topic_path_of_instruction ${BLUE}data:${NC} $data_of_instruction${NC}"
				continue

			else

				#LOG THE OUTPU
				#log "${GREEN}[CMD-INST]	${NC}[${RED}fail mqtt${NC}] ${BLUE}topic:${NC} $topic_path_of_instruction ${BLUE}data:${NC} $data_of_instruction${NC}"

				#DO A LITTLE SPELL CHECKING HERE
				if [[ ${mqtt_topic_branch^^} =~ .*ARR.* ]]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SUGG]	${NC}[${RED}fail mqtt${NC}] did you mean .../scan/${RED}arrive${NC}? ${NC}"
				elif [[ ${mqtt_topic_branch^^} =~ .*DEP.* ]]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SUGG]	${NC}[${RED}fail mqtt${NC}] did you mean .../scan/${RED}depart${NC}? ${NC}"
				elif [[ ${mqtt_topic_branch^^} =~ .*BET.* ]]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SUGG]	${NC}[${RED}fail mqtt${NC}] did you mean .../scan/${RED}updatebeta${NC}? ${NC}"
				elif [[ ${mqtt_topic_branch^^} =~ .*RSS.* ]]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SUGG]	${NC}[${RED}fail mqtt${NC}] did you mean .../scan/${RED}rssi${NC}? ${NC}"
				elif [[ ${mqtt_topic_branch^^} =~ .*STAR.* ]]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SUGG]	${NC}[${RED}fail mqtt${NC}] did you mean .../scan/${RED}restart${NC}? ${NC}"
				elif [[ ${mqtt_topic_branch^^} =~ .*DAT.* ]]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SUGG]	${NC}[${RED}fail mqtt${NC}] did you mean .../scan/${RED}update${NC} or .../scan/${RED}updatebeta${NC}? ${NC}"
				elif [[ ${mqtt_topic_branch^^} =~ .*ECH.* ]]; then 
					$PREF_VERBOSE_LOGGING && log "${GREEN}[CMD-SUGG]	${NC}[${RED}fail mqtt${NC}] did you mean .../scan/${RED}echo${NC} or .../scan/${RED}updatebeta${NC}? ${NC}"
				fi 

			fi

		elif [ "$cmd" == "BOFF" ] || [ "$cmd" == "BEXP" ]; then 

			[ "$uptime" -lt "$PREF_STARTUP_SETTLE_TIME" ] && continue
			
			#ONLY WHEN BLUETOOTH IS OFF DO WE ATTEMPT TO SCAN FOR RSSI OF KNOWN/CONNECTED DEVICES
			if [ "$cmd" == "BOFF" ]; then 
				#FIND RSSI OF KNOWN DEVICES PREVIOUSLY CONNECTED WHILE HICTOOL IS NOT 
				#SCANNING			
				difference_last_rssi=$((timestamp - last_rssi_scan))

				#ONLY EVER 5 MINUTES
				if [ "$difference_last_rssi" -gt "90" ] || [ -z "$last_rssi_scan" ] ; then 
					connectable_present_devices
					last_rssi_scan=$(date +%s)
				fi 
			fi 

			#RETURN PERIODIC SCAN MODE	
			if [ "$PREF_PERIODIC_MODE" == true ]; then 

				#SCANNED RECENTLY? 
				duration_since_arrival_scan=$((timestamp - last_arrival_scan))
				
				#CALCULATE DEPARTURE
				duration_since_depart_scan=$((timestamp - last_depart_scan))

				if [ "$duration_since_depart_scan" -gt "$PREF_DEPART_SCAN_INTERVAL" ]; then 

					perform_departure_scan

				elif [ "$duration_since_arrival_scan" -gt "$PREF_ARRIVE_SCAN_INTERVAL" ]; then 

					perform_arrival_scan 
				fi
			fi

			#**********************************************************************
			#
			#
			#	THE FOLLOWING LOOPS CLEAR CACHES OF ALREADY SEEN DEVICES BASED 
			#	ON APPROPRIATE TIMEOUT PERIODS FOR THOSE DEVICES. 
			#	
			#
			#**********************************************************************

			#DID ANY DEVICE EXPIRE? 
			should_scan=false
			last_seen=""
			key=""
			beacon_specific_expiration_interval=""
			
			#PURGE OLD KEYS FROM THE RANDOM DEVICE LOG
			for key in "${!random_device_log[@]}"; do

				#FIND WHEN THIS KEYW AS LAST SEEN? 
				last_seen="${random_device_log[$key]}"

				#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
				difference=$((timestamp - last_seen))

				#FIND THE EXPIRATION INTERVAL FOR THIS PARTICULAR BEACON
				beacon_specific_expiration_interval="${advertisement_interval_observation[$key]}"
				beacon_specific_expiration_interval=$(( beacon_specific_expiration_interval * PREF_DEPART_SCAN_ATTEMPTS ))

				#SET EXPIRATION
				beacon_specific_expiration_interval=$(( beacon_specific_expiration_interval > 45 && beacon_specific_expiration_interval  < PREF_RANDOM_DEVICE_EXPIRATION_INTERVAL ? beacon_specific_expiration_interval : PREF_RANDOM_DEVICE_EXPIRATION_INTERVAL ))

				#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
				[ -z "$last_seen" ] && continue

				#IS THIS A BEACON??
				if [ "$difference" -gt "$beacon_specific_expiration_interval" ]; then 
					
					#REMOVE FROM RANDOM DEVICE LOG
					unset "random_device_log[$key]"
					unset "rssi_log[$key]"
					[ -z "${blacklisted_devices[$key]}" ] && log "${BLUE}[DEL-RAND]	${NC}RAND $key expired after $difference seconds ${NC}"

					#AT LEAST ONE DEVICE EXPIRED
					should_scan=true 
				fi 
			done

			#RANDOM DEVICE EXPIRATION SHOULD TRIGGER DEPARTURE SCAN
			[ "$should_scan" == true ] && [ "$PREF_TRIGGER_MODE_DEPART" == false ] && perform_departure_scan

			#THIS IS A LIST OF ALL DEVIES PURGED FROM THE RECORDS; MAY INCLUDE BEACONS
			notification_sent="____ "

			#RESET VARIABLES
			last_seen=""
			key=""

			#TEMP VAR
			most_recent_beacon=""
			observed_max_advertisement_interval=""

			#PURGE OLD KEYS FROM THE BEACON DEVICE LOG
			for key in "${!public_device_log[@]}"; do

				#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
				last_seen="${public_device_log[$key]}"

				#RSSI
				latest_rssi="${rssi_log[$key]}" 

				#ADJUST FOR BEACON?
				is_apple_beacon=false

				#RESET BEACON KEY
				observed_max_advertisement_interval="${advertisement_interval_observation[$key]}"
				most_recent_beacon=""
				beacon_uuid_found=""
				beacon_mac_found=""

				#THE PROBLEM HEERE IS THAT WE CAN RUN THROUGH THIS AND HIT ONE OR THE OTHER OF MAC OR ADDRESS FIRST; 
				#THEN WE EXIT

				#IS THIS RANDOM ADDRESS ASSOCIATED WITH A BEACON
				for beacon_uuid_key in "${!beacon_mac_address_log[@]}"; do
					#FIND ASSOCIATED BEACON
					current_associated_beacon_mac_address="${beacon_mac_address_log[$beacon_uuid_key]}"

					#COMPARE TO CURRENT KEY
					if [ "$current_associated_beacon_mac_address" == "$key" ]; then 
						
						#SET THIS IS A BEACON
						is_apple_beacon=true

						#SET VALUES
						beacon_mac_found="$current_associated_beacon_mac_address"
						beacon_uuid_found="$beacon_uuid_key"
						break

					elif [ "$beacon_uuid_key" == "$key" ]; then 

						#SET THIS IS A BEACON
						is_apple_beacon=true

						#SET THIS IS A BEACON
						is_apple_beacon=true

						#SET VALUES
						beacon_uuid_found="$beacon_uuid_key"
						beacon_mac_found="$current_associated_beacon_mac_address"
						break					
					fi
				done

				#DETERMINE IF THIS WAS A BEACON AND, IF SO, WHETHER THE BEACON IS SEEN MORE RECENTLY 
				if [ "$is_apple_beacon" == true ]; then 
					
					#DETERMINE DIFFERENCE SET DEFAULT NON-EXPIRING VALUE FOR DEVUGGING PURPOSES
					[ "${public_device_log[$beacon_mac_found]:--1}" -ge "${public_device_log[$beacon_uuid_found]:--1}" ] && most_recent_beacon=${public_device_log[$beacon_mac_found]}
					[ "${public_device_log[$beacon_uuid_found]:--1}" -ge "${public_device_log[$beacon_mac_found]:--1}" ] && most_recent_beacon=${public_device_log[$beacon_uuid_found]}
					
					last_seen="$most_recent_beacon"

					#WHICH PREDICTION SHOULD WE USE? 
					[ "${advertisement_interval_observation[$beacon_mac_found]:--1}" -ge "${advertisement_interval_observation[$beacon_uuid_found]:--1}" ] && observed_max_advertisement_interval="${advertisement_interval_observation[$beacon_mac_found]}"
					[ "${advertisement_interval_observation[$beacon_uuid_found]:--1}" -ge "${advertisement_interval_observation[$beacon_mac_found]:--1}" ] && observed_max_advertisement_interval="${advertisement_interval_observation[$beacon_uuid_found]}"

					#CALCUALTE DIFFERENCE FOR CONFIDENCE FINDING
					difference=$((timestamp - most_recent_beacon))

				else

					#DETERMINE DIFFERENCE
					difference=$((timestamp - last_seen))

					#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
					[ -z "$last_seen" ] && continue 
				fi 

				#FIND THE EXPIRATION INTERVAL FOR THIS PARTICULAR BEACON
				beacon_specific_expiration_interval="${advertisement_interval_observation[$key]}"

				#ADJUST TO BUFFER BASED ON USER PREFERENCES
				beacon_specific_expiration_interval=$(( beacon_specific_expiration_interval * PREF_DEPART_SCAN_ATTEMPTS ))

				#SET EXPIRATION 
				beacon_specific_expiration_interval=$(( beacon_specific_expiration_interval > 45 && beacon_specific_expiration_interval  < PREF_BEACON_EXPIRATION ? beacon_specific_expiration_interval : PREF_BEACON_EXPIRATION ))

				#TIMEOUT AFTER [XXX] SECONDS; ALL BEACONS HONOR THE SAME EXPRIATION THRESHOLD INCLUDING IBEACONS
				if [ "$difference" -gt "$beacon_specific_expiration_interval" ]; then 
					#REMOVE FROM EXPIRING DEVICE LOG
					[ -n "${expiring_device_log[$key]}" ] && unset "expiring_device_log[$key]"

					#IS BEACON?
					if [ "$is_apple_beacon" == true ] && [ "$PREF_BEACON_MODE" == true ]; then 

						#REMOVE FROM LOGS
						unset "rssi_log[$beacon_uuid_found]"

						#REMOVE MAC FROM PUBLIC LOG
						unset "public_device_log[$beacon_mac_found]"
						unset "rssi_log[$beacon_mac_found]"

						#REMOVE BEACON FROM MAC ADDRESS ARRAY
						unset "beacon_mac_address_log[$beacon_uuid_found]"

						#REMOVE FROM BEACON ASSOCIATION
						unset "advertisement_interval_observation[$beacon_uuid_found]"
						unset "advertisement_interval_observation[$beacon_mac_found]"
						
						#PUBLISH EXPIRATION
						[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$beacon_uuid_found]}" ] && log "${BLUE}[DEL-BEAC]	${NC}BEAC $beacon_uuid_found expired after $difference seconds ${NC}"
						[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$beacon_mac_found]}" ] && log "${BLUE}[DEL-PUBL]	${NC}BEAC $beacon_mac_found expired after $difference seconds ${NC}"

						[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$beacon_uuid_found]}" ] && publish_presence_message "id=$beacon_uuid_found" "confidence=0" "last_seen=$most_recent_beacon"
						[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$beacon_mac_found]}" ] && publish_presence_message "id=$beacon_mac_found" "confidence=0" "last_seen=$most_recent_beacon"
					
					else 

						unset "public_device_log[$key]"
						unset "rssi_log[$key]"

						##REMOVE FROM BEACON ASSOCIATION
						unset "advertisement_interval_observation[$key]"

						[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$key]}" ] && log "${BLUE}[DEL-PUBL]	${NC}PUBL $key expired after $difference seconds ${NC}"
						
						#REPORT PRESENCE OF DEVICE
						[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$key]}" ] && publish_presence_message "id=$key" "confidence=0" "last_seen=$last_seen"
				
					fi

				elif [ "${observed_max_advertisement_interval:-0}" -gt "0" ] && [ "$difference" -gt "$(( (beacon_specific_expiration_interval - observed_max_advertisement_interval)  / 2 + observed_max_advertisement_interval))" ]; then

					#SHOULD REPORT A DROP IN CONFIDENCE? 
					percent_confidence=$(( 100 - (difference - observed_max_advertisement_interval) * 100 / (PREF_BEACON_EXPIRATION - observed_max_advertisement_interval) )) 
					[ "$percent_confidence" -lt "5" ] && percent_confidence=0


					if [ "$PREF_REPORT_ALL_MODE" == true ]; then						
						#REPORTING ALL 	
						if [ "$is_apple_beacon" == true ] && [ "$PREF_BEACON_MODE" == true ]; then 
							#DEBUG LOGGING
							[ -z "${blacklisted_devices[$beacon_uuid_found]}" ] && publish_presence_message "id=$beacon_uuid_found" "confidence=$percent_confidence" "mac=$key" "last_seen=$most_recent_beacon" && expiring_device_log[$beacon_uuid_found]='true'
							[ -z "${blacklisted_devices[$beacon_mac_found]}" ] && publish_presence_message "id=$beacon_mac_found" "confidence=$percent_confidence" "last_seen=$most_recent_beacon" && expiring_device_log[$beacon_mac_found]='true'

						else 
							[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$key]}" ] && publish_presence_message "id=$key" "confidence=$percent_confidence" "last_seen=$last_seen" && expiring_device_log[$key]='true'
						fi 
					else 
						#REPORT PRESENCE OF DEVICE ONLY IF IT IS ABOUT TO BE AWAY; ALSO DO NOT REPORT DEVICES THAT WE'VE ALREADY REPORTEDI IN THIS LOOP
						if [ "$is_apple_beacon" == true ]; then 								
							#IF NOT SEEN AND BELOW THRESHOLD
							if ! [[ $notification_sent  =~ $key ]] && [ "$percent_confidence" -lt "$PREF_PERCENT_CONFIDENCE_REPORT_THRESHOLD" ]; then 
								[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$beacon_uuid_found]}" ] && publish_presence_message "id=$beacon_uuid_found" "confidence=$percent_confidence" "mac=$beacon_mac_found" "last_seen=$most_recent_beacon" && expiring_device_log[$beacon_uuid_found]='true' && notification_sent="$notification_sent $beacon_uuid_found"
								[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$beacon_mac_found]}" ] && publish_presence_message "id=$beacon_mac_found" "confidence=$percent_confidence" "last_seen=$most_recent_beacon" && expiring_device_log[$beacon_mac_found]='true' && notification_sent="$notification_sent $beacon_mac_found"
							fi 
						else 
							[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$key]}" ] && [ "$percent_confidence" -lt "$PREF_PERCENT_CONFIDENCE_REPORT_THRESHOLD" ] && publish_presence_message "id=$key" "confidence=$percent_confidence" "last_seen=$last_seen" && expiring_device_log[$key]='true' && notification_sent="$notification_sent $key"
							notification_sent="$notification_sent $key"
						fi
					fi  
				fi 
			done

			continue

		elif [ "$cmd" == "NAME" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			name=$(echo "$data" | awk -F "|" '{print $2}')
			rssi_latest="${rssi_log[$mac]}"

			#PREVIOUS STATE; SET DEFAULT TO UNKNOWN
			previous_state="${known_public_device_log[$mac]}"
			previous_state=${previous_state:--1}

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer "$mac")"

			#IF NAME IS DISCOVERED, PRESUME HOME
			if [ -n "$name" ]; then 
				known_public_device_log[$mac]=1
				[ "$previous_state" != "1" ] && did_change=true
			else
				known_public_device_log[$mac]=0
				[ "$previous_state" != "0" ] && did_change=true
			fi 
		fi 

		#NEED TO VERIFY WHETHER WE HAVE TO UPDATE INFORMATION FOR A PRIVATE BEACON THAT IS 
		#ACTUALLY PUBLIC

		if [ "$cmd" == "PUBL" ]; then 
			#PARSE RECEIVED DATA
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			pdu_header=$(echo "$data" | awk -F "|" '{print $2}')
			name=$(echo "$data" | awk -F "|" '{print $3}')
			rssi=$(echo "$data" | awk -F "|" '{print $4}')
			adv_data=$(echo "$data" | awk -F "|" '{print $5}')
			manufacturer=$(echo "$data" | awk -F "|" '{print $6}')
			device_type=$(echo "$data" | awk -F "|" '{print $7}')
			flags=$(echo "$data" | awk -F "|" '{print $8}')
			oem_data=$(echo "$data" | awk -F "|" '{print $9}')
			instruction_timestamp=$(echo "$data" | awk -F "|" '{print $10}')
			resolvable=$(echo "$data" | awk -F "|" '{print $11}')
			hex_data=$(echo "$data" | awk -F "|" '{print $12}')

			#DEFAULT?
			instruction_timestamp=${instruction_timestamp:-$timestamp}
			instruction_delay=$((timestamp - instruction_timestamp))

			#RESET BEACON UUID
			beacon_uuid_key=""

			#SET TYPE
			beacon_type="GENERIC_BEACON_PUBLIC"
			matching_beacon_uuid_key=""
			
			#DETERMINE WHETHER THIS DEVICE IS ASSOCIATED WITH AN IBEACON
			current_associated_beacon_mac_address=""
			for beacon_uuid_key in "${!beacon_mac_address_log[@]}"; do
				current_associated_beacon_mac_address="${beacon_mac_address_log[$beacon_uuid_key]}"
				if [ "$current_associated_beacon_mac_address" == "$mac" ]; then 
					matching_beacon_uuid_key="$beacon_uuid_key"
					break
				fi 
			done

			#SET ADVERTISEMENT INTERVAL OBSERVATION
			last_appearance=${public_device_log[$mac]:-$timestamp}
			if [ "$observation_made" == false ]; then 
				observation_made=true 
				temp_observation="" && temp_observation=$((((timestamp - last_appearance - 1 + PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) / PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) * PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP))
				[ "$temp_observation" -gt "${advertisement_interval_observation[$mac]:-0}" ] && [ "$temp_observation" -gt "0" ] && [ "$temp_observation" -lt "300" ] &&	advertisement_interval_observation[$mac]=$temp_observation
				
			fi
			
			#SET ADVERTISEMENT INTERVAL OBSERVATION
			if [ -n "$matching_beacon_uuid_key" ]; then 
				#GET INTERVAL SINCE LAST SEEN
				last_appearance=${public_device_log[$matching_beacon_uuid_key]:-$timestamp}
				temp_observation="" && temp_observation=$((((timestamp - last_appearance - 1 + PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) / PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) * PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP))
				[ "$temp_observation" -gt "${advertisement_interval_observation[$matching_beacon_uuid_key]:-0}" ] && [ "$temp_observation" -gt "0" ] && [ "$temp_observation" -lt "300" ] &&	advertisement_interval_observation[$matching_beacon_uuid_key]=$temp_observation
			fi

			#SET NAME 
			[ -n "$name" ] && known_public_device_name[$mac]="$name"
			[ -z "$name" ] && name="$(determine_name "$mac")"

			#DATA IS PUBLIC MAC Addr.; ADD TO LOG
			[ -z "${public_device_log[$mac]}" ] && is_new=true

			#HAS THIS DEVICE BEEN MARKED AS EXPIRING SOON? IF SO, SHOULD REPORT 100 AGAIN
			[ -n "${expiring_device_log[$mac]}" ] && should_update=true
			[ -n "$matching_beacon_uuid_key" ] && [ -n "${expiring_device_log[$matching_beacon_uuid_key]}" ] && should_update=true

			#GET LAST RSSI
			rssi_latest="${rssi_log[$mac]}" 
			[ -z "$rssi_latest" ] && [ -n "$matching_beacon_uuid_key" ] && rssi_latest="${rssi_log[$matching_beacon_uuid_key]}" 

			#IF NOT IN DATABASE, BUT FOUND HERE
			if [ -n "$name" ]; then

				#FIND PUBLIC NAME 
				known_public_device_name[$mac]="$name"

				#GET NAME FROM CACHE
				cached_name=$(grep "$mac" < ".public_name_cache" | awk -F "\t" '{print $2}')

				#ECHO TO CACHE IF DOES NOT EXIST
				[ -z "$cached_name" ] && echo "$mac	$name" >> .public_name_cache

				#IS THIS ASSOCITED WITH A BEACON? 
				if [ -n "$matching_beacon_uuid_key" ]; then 
				
					#IF THIS IS AN IBEACON, WE ADD THE NAME TO THAT ARRAY TOO
					known_public_device_name[$matching_beacon_uuid_key]="$name"

					#GET NAME FROM CACHE
					cached_name=""
					cached_name=$(grep "$matching_beacon_uuid_key" < ".public_name_cache" | awk -F "\t" '{print $2}')

					#ECHO TO CACHE IF DOES NOT EXIST
					[ -z "$cached_name" ] && echo "$matching_beacon_uuid_key	$name" >> .public_name_cache
				fi 
			fi 

			#STATIC DEVICE DATABASE AND RSSI DATABASE
			public_device_log[$mac]="$timestamp"
			[ -n "$rssi" ] && rssi_log[$mac]="$rssi"

			#MANUFACTURER
			[ -z "$manufacturer" ] && manufacturer="$(determine_manufacturer "$mac")"
		
		elif [ "$cmd" == "BEAC" ]; then 

			#DATA IS DELIMITED BY VERTICAL PIPE
			uuid=$(echo "$data" | awk -F "|" '{print $1}')
			major=$(echo "$data" | awk -F "|" '{print $2}')
			minor=$(echo "$data" | awk -F "|" '{print $3}')
			rssi=$(echo "$data" | awk -F "|" '{print $4}')
			power=$(echo "$data" | awk -F "|" '{print $5}')
			mac=$(echo "$data" | awk -F "|" '{print $6}')
			beacon_type="APPLE_IBEACON"
			name=""

			#FIND INSTRUCTION TIMESTAMP
			instruction_timestamp=$(echo "$data" | awk -F "|" '{print $7}')

			#DEFAULT?
			instruction_timestamp=${instruction_timestamp:-$timestamp}
			instruction_delay=$((timestamp - instruction_timestamp))

			#GET MAC AND PDU HEADER
			uuid_reference="$uuid-$major-$minor"

			#HAS THIS DEVICE BEEN MARKED AS EXPIRING SOON? IF SO, SHOULD REPORT 100 AGAIN
			[ -n "${expiring_device_log[$uuid_reference]}" ] && should_update=true && unset "expiring_device_log[$uuid_reference]"

			#UPDATE MAC ADDRESS OF BEACON 

			#FIRST FIND PREVIOUS ASSOCIATION OF MAC ADDRESS TO DETERMINE 
			#WHETHER THIS ADDRESS HAS BEEN REMOVED BY AN EXPIRATION 

			if [ -n "${beacon_mac_address_log[$uuid_reference]}" ]; then 

				#FIND PREVIOUS ASSOCIATION; HAS THIS BEEN REMOVED?
				previous_association=${beacon_mac_address_log[$uuid_reference]}

				#IF THE ADDRESS HAS CHANGED, THEN WE NEED TO UPDATE THE ADDRESS
				if [ ! "$previous_association" == "$mac" ]; then  

					#REMOVE THIS FROM PUBLIC RECORDS
					unset "public_device_log[$previous_association]"
				fi
			else 
				#SET THIS AS NEW
				is_new=true
			fi 

			#SET ADVERTISEMENT INTERVAL OBSERVATION
			last_appearance=${public_device_log[$mac]:-$timestamp}
			[ "$observation_made" == false ] && observation_made=true && advertisement_interval_observation[$mac]=$((((timestamp - last_appearance - 1 + PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) / PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) * PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP))

			#GET INTERVAL SINCE LAST SEEN
			last_appearance=${public_device_log[$mac]:-$timestamp}
			if [ "$observation_made" == false ]; then 
				observation_made=true
				temp_observation="" && temp_observation=$((((timestamp - last_appearance - 1 + PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) / PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP) * PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP))
				[ "$temp_observation" -gt "${advertisement_interval_observation[$mac]:-0}" ] && [ "$temp_observation" -gt "0" ] && [ "$temp_observation" -lt "300" ] &&	advertisement_interval_observation[$mac]=$temp_observation

			fi
			
			#SAVE BEACON ADDRESS LOG
			beacon_mac_address_log[$uuid_reference]="$mac"

			#FIND NAME OF BEACON
			[ -z "$name" ] && name="$(determine_name "$mac")"

			#GET LAST RSSI
			rssi_latest="${rssi_log[$uuid_reference]}" 
			[ -z "$rssi_latest" ] && rssi_latest="${rssi_log[$mac]}" 

			#IS THIS A NEW DEVICE? 
			[ -z "${public_device_log[$uuid_reference]}" ] && is_new=true

			#RECORD BASED ON UUID AND MAC ADDRESS
			public_device_log[$uuid_reference]="$timestamp"	

			#RSSI LOGS
			[ -n "$rssi" ] && rssi_log[$uuid_reference]="$rssi"
		fi

		#**********************************************************************
		#
		#
		#	THE FOLLOWING REPORTS RSSI CHANGES FOR PUBLIC OR RANDOM DEVICES 
		#	
		#
		#**********************************************************************

		#REPORT RSSI CHANGES
		if [ -n "$rssi" ] && [ "${#rssi}" -lt "5" ] && [ "$uptime" -gt "$PREF_STARTUP_SETTLE_TIME" ]; then 

			#ONLY FOR PUBLIC OR BEAON DEVICES
			if [ "$cmd" == "PUBL" ] || [ "$cmd" == "BEAC" ]; then 

				#SET RSSI LATEST IF NOT ALREADY SET 
				rssi_latest=${rssi_latest:--200}

				#IS RSSI THE SAME? 
				rssi_change=$((rssi - rssi_latest))
				abs_rssi_change=${rssi_change#-}

				#DETERMINE MOTION DIRECTION
				motion_direction="depart"
				[ "$rssi_change" == "$abs_rssi_change" ] && motion_direction="approach"

				#IF POSITIVE, APPROACHING IF NEGATIVE DEPARTING
				case "1" in
					$(( abs_rssi_change >= 50)) )
						change_type="fast $motion_direction"
						;;
					$(( abs_rssi_change >= 30)) )
						change_type="moderate $motion_direction"
						;;
					$(( abs_rssi_change >= 10)) )
						change_type="slow movement $motion_direction"
						;;
					$(( abs_rssi_change >= 3)) )
						change_type="drifting"
						;;			
					*)
						change_type="stationary"
						;;	
				esac

				#WITHOUT ANY DATA OR INFORMATION, MAKE SURE TO REPORT
				[ "$rssi_latest" == "-200" ] && change_type="initial reading" && should_update=true

				#ONLY PRINT IF WE HAVE A CHANCE OF A CERTAIN MAGNITUDE
				[ -z "${blacklisted_devices[$mac]}" ] && [ "$abs_rssi_change" -gt "$PREF_RSSI_CHANGE_THRESHOLD" ] && log "${CYAN}[CMD-RSSI]	${NC}$cmd $mac ${GREEN}${NC}RSSI: ${rssi:-100} dBm ($change_type | $abs_rssi_change dBm) ${NC}" && should_update=true
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

		if [ "$cmd" == "NAME" ] ; then 
			
			#PRINTING FORMATING
			debug_name="$name"
			expected_name="$(determine_name "$mac")"
			

			current_state="${known_public_device_log[$mac]}"

			#IF NAME IS NOT PREVIOUSLY SEEN, THEN WE SET THE STATIC DEVICE DATABASE NAME
			[ -z "$expected_name" ] && [ -n "$name" ] && known_public_device_name[$mac]="$name" 
			[ -n "$expected_name" ] && [ -z "$name" ] && name="$expected_name"

			#OVERWRITE WITH EXPECTED NAME
			[ -n "$expected_name" ] && [ -n "$name" ] && name="$expected_name"

			#FOR LOGGING; MAKE SURE THAT AN UNKNOWN NAME IS ADDED
			if [ -z "$debug_name" ]; then 
				#SHOW ERROR
				debug_name="Unknown Name"
				
				#CHECK FOR KNOWN NAME
				[ -n "$expected_name" ] && debug_name="$expected_name"
			fi 

			#IF WE HAVE DEPARTED OR ARRIVED; MAKE A NOTE UNLESS WE ARE ALSO IN THE TRIGGER MODE
			[ "$did_change" == true ] && [ "$current_state" == "1" ] && $PREF_TRIGGER_MODE_REPORT_OUT && publish_cooperative_scan_message "arrive"

			#PRINT RAW COMMAND; DEBUGGING
			log "${CYAN}[CMD-$cmd]	${NC}$mac ${GREEN}$debug_name ${NC} $manufacturer${NC}"
		
		elif [ "$cmd" == "BEAC" ] && [ "$PREF_BEACON_MODE" == true ] && ([ "$should_update" == true ] || [ "$is_new" == true ]); then 
		
			#PROVIDE USEFUL LOGGING
			if [ -z "${blacklisted_devices[$uuid_reference]}" ] && [ -z "${blacklisted_devices[$mac]}" ]; then 

				#REMOVE 
				[ -n "${expiring_device_log[$uuid_reference]}" ] && unset "expiring_device_log[$uuid_reference]"
				[ -n "${expiring_device_log[$mac]}" ] && unset "expiring_device_log[$mac]"

				#LOG
				log "${GREEN}[CMD-$cmd]	${NC}$mac ${GREEN}$uuid $major $minor ${NC}$name${NC}"
				
				publish_presence_message  \
				"id=$uuid_reference" \
				"confidence=100" \
				"name=$name" \
				"type=$beacon_type" \
				"rssi=$rssi" \
				"mac=$mac" \
				"report_delay=$instruction_delay" \
				"observed_interval=${advertisement_interval_observation[$mac]:--1}" \
				"power=$power" \
				"movement=$change_type"

				#LOG
				log "${PURPLE}[CMD-PUBL]${NC}	$mac ${GREEN}$name${NC} ${BLUE}$manufacturer${NC} $rssi dBm"
				
				publish_presence_message \
				"id=$mac" \
				"confidence=100" \
				"name=$name" \
				"manufacturer=$manufacturer" \
				"type=GENERIC_BEACON_PUBLIC" \
				"report_delay=$instruction_delay" \
				"observed_interval=${advertisement_interval_observation[$mac]:--1}" \
				"rssi=$rssi" \
				"flags=$flags" \
				"movement=${change_type:-none}"
			fi 
		
		elif [ "$cmd" == "PUBL" ] && [ "$PREF_BEACON_MODE" == true ] && ([ "$should_update" == true ] || [ "$is_new" == true ]); then 

			#PUBLISH PRESENCE MESSAGE FOR BEACON
			if [ -z "${blacklisted_devices[$mac]}" ]; then 
				[ -n "${expiring_device_log[$mac]}" ] && unset "expiring_device_log[$mac]" 

				#FIND NAME
				expected_name="$(determine_name "$mac")"

				log "${PURPLE}[CMD-$cmd]${NC}	$mac ${GREEN}$name${NC} ${BLUE}$manufacturer${NC} $rssi dBm"

				publish_presence_message \
				"id=$mac" \
				"confidence=100" \
				"name=$name" \
				"manufacturer=$manufacturer" \
				"type=$beacon_type" \
				"report_delay=$instruction_delay" \
				"rssi=$rssi" \
				"observed_interval=${advertisement_interval_observation[$mac]:--1}" \
				"flags=${flags:-none}" \
				"movement=${change_type:-none}" \
				"oem_data=${oem_data:-not advertised}" \
				"hex_data=${hex_data:-none}" \
				"resolvable=${resolvable:-PUBLIC}"

				#PERFORM SCAN HERE AS WELL
				if [ "$is_new" == true ]; then 
					#REJECTION FILTER
					if [[ ${flags,,} =~ ${PREF_FAIL_FILTER_ADV_FLAGS_ARRIVE,,} ]] || [[ ${manufacturer,,} =~ ${PREF_FAIL_FILTER_MANUFACTURER_ARRIVE,,} ]]; then 

						$PREF_VERBOSE_LOGGING && log "${RED}[CMD-$cmd]${NC}	[${RED}failed filter${NC}] data: ${BLUE}${mac:-none}${NC} pdu: ${BLUE}${pdu_header:-none}${NC} rssi: ${BLUE}${rssi:-UKN} dBm${NC} flags: ${RED}${flags:-none}${NC} man: ${RED}${manufacturer:-unknown}${NC} delay: ${BLUE}${instruction_delay:-UKN}${NC}"

						continue
					fi 

					#FLAG AND MFCG FILTER
					if [[ ${flags,,} =~ ${PREF_PASS_FILTER_ADV_FLAGS_ARRIVE,,} ]] && [[ ${manufacturer,,} =~ ${PREF_PASS_FILTER_MANUFACTURER_ARRIVE,,} ]]; then 
						#PROVIDE USEFUL LOGGING
						$PREF_VERBOSE_LOGGING && log "${RED}[CMD-$cmd]${NC}	[${GREEN}passed filter${NC}] data: ${BLUE}${mac:-none}${NC} pdu: ${BLUE}${pdu_header:-none}${NC} rssi: ${BLUE}${rssi:-UKN} dBm${NC} flags: ${BLUE}${flags:-none}${NC} man: ${BLUE}${manufacturer:-unknown}${NC} delay: ${BLUE}${instruction_delay:-UKN}${NC}"

						#WE ARE PERFORMING THE FIRST ARRIVAL SCAN?
						first_arrive_scan=false

						#SCAN ONLY IF WE ARE NOT IN TRIGGER MODE
						perform_arrival_scan 

						continue
					else 
						#PROVIDE USEFUL LOGGING
						$PREF_VERBOSE_LOGGING && log "${RED}[CMD-$cmd]${NC}	[${RED}failed filter${NC}] data: ${BLUE}${mac:-none}${NC} pdu: ${BLUE}${pdu_header:-none}${NC} rssi: ${BLUE}${rssi:-UKN} dBm${NC} flags: ${RED}${flags:-none}${NC} man: ${RED}${manufacturer:-unknown}${NC} delay: ${BLUE}${instruction_delay:-UKN}${NC}"

						continue
					fi 
				fi 
			fi 


		elif [ "$cmd" == "RAND" ] && [ "$is_new" == true ] && [ "$PREF_TRIGGER_MODE_ARRIVE" == false ] && [ -z "${blacklisted_devices[$mac]}" ]; then 
			
			#REJECTION FILTER
			if [[ ${flags,,} =~ ${PREF_FAIL_FILTER_ADV_FLAGS_ARRIVE,,} ]] || [[ ${manufacturer,,} =~ ${PREF_FAIL_FILTER_MANUFACTURER_ARRIVE,,} ]]; then 

				$PREF_VERBOSE_LOGGING && log "${RED}[CMD-$cmd]${NC}	[${RED}failed filter${NC}] data: ${BLUE}${mac:-none}${NC} pdu: ${BLUE}${pdu_header:-none}${NC} rssi: ${BLUE}${rssi:-UKN} dBm${NC} flags: ${RED}${flags:-none}${NC} man: ${RED}${manufacturer:-unknown}${NC} delay: ${BLUE}${instruction_delay:-UKN}${NC}"

				continue
			fi 

			#FLAG AND MFCG FILTER
			if [[ ${flags,,} =~ ${PREF_PASS_FILTER_ADV_FLAGS_ARRIVE,,} ]] && [[ ${manufacturer,,} =~ ${PREF_PASS_FILTER_MANUFACTURER_ARRIVE,,} ]]; then 
				#PROVIDE USEFUL LOGGING
				$PREF_VERBOSE_LOGGING && log "${RED}[CMD-$cmd]${NC}	[${GREEN}passed filter${NC}] data: ${BLUE}${mac:-none}${NC} pdu: ${BLUE}${pdu_header:-none}${NC} rssi: ${BLUE}${rssi:-UKN} dBm${NC} flags: ${BLUE}${flags:-none}${NC} man: ${BLUE}${manufacturer:-unknown}${NC} delay: ${BLUE}${instruction_delay:-UKN}${NC}"

				#WE ARE PERFORMING THE FIRST ARRIVAL SCAN?
				first_arrive_scan=false

				#SCAN ONLY IF WE ARE NOT IN TRIGGER MODE
				perform_arrival_scan 

				continue
			else 
				#PROVIDE USEFUL LOGGING
				$PREF_VERBOSE_LOGGING && log "${RED}[CMD-$cmd]${NC}	[${RED}failed filter${NC}] data: ${BLUE}${mac:-none}${NC} pdu: ${BLUE}${pdu_header:-none}${NC} rssi: ${BLUE}${rssi:-UKN} dBm${NC} flags: ${RED}${flags:-none}${NC} man: ${RED}${manufacturer:-unknown}${NC} delay: ${BLUE}${instruction_delay:-UKN}${NC}"

				continue
			fi 
		fi 

		#SHOUD WE PERFORM AN ARRIVAL SCAN AFTER THIS FIRST LOOP?
		if [ "$first_arrive_scan" == true ] && [ "$uptime" -lt "$PREF_STARTUP_SETTLE_TIME" ] ; then 
			perform_arrival_scan 
		fi 

	done < main_pipe

	#SHOUD WE PERFORM AN ARRIVAL SCAN AFTER THIS FIRST LOOP?
	if [ "$first_arrive_scan" == true ] && [ "$uptime" -lt "$PREF_STARTUP_SETTLE_TIME" ] ; then 
		perform_arrival_scan 
	fi
done
