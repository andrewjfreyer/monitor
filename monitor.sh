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
export version=0.1.755

#CAPTURE ARGS IN VAR TO USE IN SOURCED FILE
export RUNTIME_ARGS=("$@")

#LOG DELIMITER
echo "====================== DEBUG ======================"

# ----------------------------------------------------------------------------------------
# KILL OTHER SCRIPTS RUNNING
# ----------------------------------------------------------------------------------------

#SOURCE SETUP AND ARGV FILES
source './support/argv'
source './support/setup'

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
echo "> stopping other instances of 'monitor.sh'"
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

#DEFINE DEVICE TRACKING VARS
declare -A public_device_log
declare -A random_device_log
declare -A rssi_log

#STATIC DEVICE ASSOCIATIVE ARRAYS
declare -A known_public_device_log
declare -A known_static_device_scan_log
declare -A known_public_device_name
declare -A blacklisted_devices
declare -A beacon_private_address_log


#LAST TIME THIS 
scan_pid=""
scan_type=""

#SCAN VARIABLES
now=$(date +%s)
last_arrival_scan=$((now - 25))
last_depart_scan=$((now - 25))
first_arrive_scan=true

# ----------------------------------------------------------------------------------------
# POPULATE THE ASSOCIATIVE ARRAYS THAT INCLUDE INFORMATION ABOUT THE STATIC DEVICES
# WE WANT TO TRACK
# ----------------------------------------------------------------------------------------

#LOAD PUBLIC ADDRESSES TO SCAN INTO ARRAY, IGNORING COMMENTS
mapfile -t known_static_beacons < <(sed 's/#.\{0,\}//g' < "$BEAC_CONFIG" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" )
mapfile -t known_static_addresses < <(sed 's/#.\{0,\}//g' < "$PUB_CONFIG" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" )
mapfile -t address_blacklist < <(sed 's/#.\{0,\}//g' < "$ADDRESS_BLACKLIST" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" )

#ASSEMBLE COMMENT-CLEANED BLACKLIST INTO BLACKLIST ARRAY
for addr in "${address_blacklist[@]}"; do 
	blacklisted_devices["$addr"]=1
	echo "> blacklisted device: $addr"
done 

# ----------------------------------------------------------------------------------------
# POPULATE MAIN DEVICE ARRAY
# ----------------------------------------------------------------------------------------

#POPULATE KNOWN DEVICE ADDRESS
for addr in "${known_static_addresses[@]}"; do 

	#WAS THERE A NAME HERE?
	known_name=$(grep "$addr" "$PUB_CONFIG" | tr "\\t" " " | sed 's/  */ /g;s/#.\{0,\}//g' | sed "s/$addr //g;s/  */ /g" )

	#IF WE FOUND A NAME, RECORD IT
	[ -n "$known_name" ] && known_public_device_name[$addr]="$known_name"

	#PUBLICATION TOPIC 
	pub_topic="$mqtt_topicpath/$mqtt_publisher_identity/$addr"
	[ "$PREF_MQTT_SINGLE_TOPIC_MODE" == true ] && pub_topic="$mqtt_topicpath/$mqtt_publisher_identity { id: $addr ... }"

	#FOR DBUGGING
	echo "> known device: $addr will publish to: $pub_topic"
done

# ----------------------------------------------------------------------------------------
# POPULATE BEACON ADDRESS ARRAY
# ----------------------------------------------------------------------------------------
#POPULATE KNOWN DEVICE ADDRESS
for addr in "${known_static_beacons[@]}"; do 

	#WAS THERE A NAME HERE?
	known_name=$(grep "$addr" "$BEAC_CONFIG" | tr "\\t" " " | sed 's/  */ /g;s/#.\{0,\}//g' | sed "s/$addr //g;s/  */ /g" )

	#IF WE FOUND A NAME, RECORD IT
	[ -n "$known_name" ] && known_public_device_name[$addr]="$known_name"

	#PUBLICATION TOPIC 
	pub_topic="$mqtt_topicpath/$mqtt_publisher_identity/$addr"
	[ "$PREF_MQTT_SINGLE_TOPIC_MODE" == true ] && pub_topic="$mqtt_topicpath/$mqtt_publisher_identity { id: $addr ... }"

	#FOR DBUGGING
	echo "> known beacon: $addr will publish to: $pub_topic"
done

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

	#SCAN ALL? SET THE SCAN STATE TO [X]
	[ -z "$scan_state" ] && scan_state=2
		 	
	#ITERATE THROUGH THE KNOWN DEVICES 
	local known_addr
	for known_addr in "${known_static_addresses[@]}"; do 
		
		#GET STATE; ONLY SCAN FOR DEVICES WITH SPECIFIC STATE
		this_state="${known_public_device_log[$known_addr]}"

		#IF WE HAVE NEVER SCANNED THIS DEVICE BEFORE, WE MARK AS 
		#SCAN STATE [X]; THIS ALLOWS A FIRST SCAN TO PROGRESS TO 
		#COMPLETION FOR ALL DEVICES
		[ -z "$this_state" ] && this_state=3

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
	return_list=$(echo "$return_list" | sed 's/^ //g;s/ $//g;s/  */ /g')

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
	[ "$PREF_MQTT_REPORT_SCAN_MESSAGES" == true ] && publish_cooperative_scan_message "$transition_type/start"
	log "${GREEN}[CMD-INFO]	${GREEN}**** Started $transition_type scan. [x$repetitions max rep] **** ${NC}"

	#ITERATE THROUGH THE KNOWN DEVICES 	
	local repetition 
	for repetition in $(seq 1 $repetitions); do

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
			[ -z "$manufacturer" ] && manufacturer="Unknown" 

			#IN CASE WE HAVE A BLANK ADDRESS, FOR WHATEVER REASON
			[ -z "$known_addr" ] && continue

			#DETERMINE START OF SCAN
			scan_start="$(date +%s)"

			#GET LOCAL NAME
			expected_name="$(determine_name $known_addr)"
			[ -z "$expected_name" ] && "Unknown"

			#DEBUG LOGGING
			log "${GREEN}[CMD-SCAN]	${GREEN}(No. $repetition)${NC} $known_addr $transition_type? ${NC}"

			#PERFORM NAME SCAN FROM HCI TOOL. THE HCITOOL CMD 0X1 0X0019 IS POSSIBLE, BUT HCITOOL NAME
			#SCAN PERFORMS VERIFICATIONS THAT REDUCE FALSE NEGATIVES. 

			#L2SCAN MAY INVOLVE LESS INTERFERENCE
			name_raw=$(hcitool -i "$PREF_HCI_DEVICE" name "$known_addr" 2>/dev/null)
			name=$(echo "$name_raw" | grep -ivE 'input/output error|invalid device|invalid|error|network')

			#COLLECT STATISTICS ABOUT THE SCAN 
			scan_end="$(date +%s)"
			scan_duration=$((scan_end - scan_start))

			#MARK THE ADDRESS AS SCANNED SO THAT IT CAN BE LOGGED ON THE MAIN PIPE
			echo "SCAN$known_addr" > main_pipe & 

			#IF STATUS CHANGES TO PRESENT FROM NOT PRESENT, REMOVE FROM VERIFICATIONS
			if [ -n "$name" ] && [ "$previous_state" == "0" ]; then 

				#PUSH TO MAIN POPE
				echo "NAME$known_addr|$name" > main_pipe 

				#DEVICE FOUND; IS IT CHANGED? IF SO, REPORT 
				publish_presence_message "$mqtt_publisher_identity/$known_addr" "100" "$expected_name" "$manufacturer" "KNOWN_MAC"

				#REMOVE FROM SCAN
				devices_next=$(echo "$devices_next" | sed "s/$known_addr_stated//g;s/  */ /g")

			elif [ -n "$name" ] && [ "$previous_state" == "3" ]; then 
				#HERE, WE HAVE FOUND A DEVICE FOR THE FIRST TIME
				devices_next=$(echo "$devices_next" | sed "s/$known_addr_stated//g;s/  */ /g")

				#NEED TO UPDATE STATE TO MAIN THREAD
				echo "NAME$known_addr|$name" > main_pipe 

				#NEVER SEEN THIS DEVICE; NEED TO PUBLISH STATE MESSAGE
				publish_presence_message "$mqtt_publisher_identity/$known_addr" "100" "$expected_name" "$manufacturer" "KNOWN_MAC"


				#COOPERATIVE SCAN ON RESTART
				[ "$PREF_TRIGGER_MODE_REPORT_OUT" == true ] && publish_cooperative_scan_message "arrive" 


			elif [ -n "$name" ] && [ "$previous_state" == "1" ]; then 

				#THIS DEVICE IS STILL PRESENT; REMOVE FROM VERIFICATIONS
				devices_next=$(echo "$devices_next" | sed "s/$known_addr_stated//g;s/  */ /g")

				#NEED TO REPORT? 
				if [[ $should_report =~ .*$known_addr.* ]] || [ "$PREF_REPORT_ALL_MODE" == true ] ; then 			
					#REPORT PRESENCE
					publish_presence_message "$mqtt_publisher_identity/$known_addr" "100" "$expected_name" "$manufacturer" "KNOWN_MAC"			
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
					if [ "$percent_confidence" -lt "$PREF_COOPERATIVE_SCAN_THRESHOLD" ] && [ "$PREF_TRIGGER_MODE_REPORT_OUT" == true ]; then 
						has_requested_collaborative_depart_scan=true
						publish_cooperative_scan_message "depart" 
					fi 
				fi 

				#REPORT PRESENCE OF DEVICE
				publish_presence_message "$mqtt_publisher_identity/$known_addr" "$percent_confidence" "$expected_name" "$manufacturer" "KNOWN_MAC"

				#IF WE DO FIND A NAME LATER, WE SHOULD REPORT OUT 
				should_report="$should_report$known_addr"

			elif [ -z "$name" ] && [ "$previous_state" == "3" ]; then 

				#NEVER SEEN THIS DEVICE; NEED TO PUBLISH STATE MESSAGE
				publish_presence_message "$mqtt_publisher_identity/$known_addr" "0" "$expected_name" "$manufacturer" "KNOWN_MAC"

				#NREMOVE FROM THE SCAN LIST TO THE MAIN BECAUSE THIS IS A BOOT UP 
				devices_next=$(echo "$devices_next" | sed "s/$known_addr_stated//g;s/  */ /g")

				#PUBLISH A NOT PRESENT TO THE NAME PIPE
				echo "NAME$known_addr|" > main_pipe 

				#COOPERATIVE SCAN ON RESTART
				[ "$PREF_TRIGGER_MODE_REPORT_OUT" == true ] && publish_cooperative_scan_message "depart"

			elif [ -z "$name" ] && [ "$previous_state" == "0" ]; then 

				if [ "$PREF_REPORT_ALL_MODE" == true ] ; then 			
					#REPORT PRESENCE
					publish_presence_message "$mqtt_publisher_identity/$known_addr" "0" "$expected_name" "$manufacturer" "KNOWN_MAC"			
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
			local expected_name="$(determine_name "$known_addr")"
			[ -z "$expected_name" ] && "Unknown"
					#DETERMINE MANUFACTUERE
			manufacturer="$(determine_manufacturer "$known_addr")"
			[ -z "$manufacturer" ] && manufacturer="Unknown" 	

			#PUBLISH PRESENCE METHOD
			publish_presence_message "$mqtt_publisher_identity/$known_addr" "0" "$expected_name" "$manufacturer" "KNOWN_MAC"
		fi 

		echo "NAME$known_addr|" > main_pipe 
	done

	#GROUP SCAN FINISHED
	log "${GREEN}[CMD-INFO]	${GREEN}**** Completed $transition_type scan. **** ${NC}"

	#DELAY BEFORE CLEARNING THE MAIN PIPE
	sleep 2

	#PUBLISH END OF COOPERATIVE SCAN
	[ "$PREF_MQTT_REPORT_SCAN_MESSAGES" == true ] && publish_cooperative_scan_message "$transition_type/end"

	#SET DONE TO MAIN PIPE
	echo "DONE" > main_pipe
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
		#ONCE THE LIST IS ESTABLISHED, TRIGGER SCAN OF THESE DEVICES IN THE BACKGROUND
		perform_complete_scan "$depart_list" "$PREF_DEPART_SCAN_ATTEMPTS" "1" & 
		disown "$!"

		scan_pid=$!
		scan_type=1
	else 
		#HERE A DEPART SCAN IS ACTIVE; ENQUEUE ANOTHER DEPART SCAN AFTER 15-second delay 
		[ "$scan_type" == "0" ] && sleep 5 && echo "ENQUdepart" > main_pipe & 	
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
		#HERE A DEPART SCAN IS ACTIVE; ENQUEUE ANOTHER DEPART SCAN AFTER 15-second delay 
		[ "$scan_type" == "1" ] && sleep 5 && echo "ENQUarrive" > main_pipe & 
	fi 
}

# ----------------------------------------------------------------------------------------
# NAME DETERMINATIONS
# ----------------------------------------------------------------------------------------

determine_name () {

	#SET DATA 
	local address
	address="$1"
	
	#IF IS NEW AND IS PUBLIC, SHOULD CHECK FOR NAME
	local expected_name
	expected_name="${known_public_device_name[$address]}"
	
	#FIND PERMANENT DEVICE NAME OF PUBLIC DEVICE
	if [ -z "$expected_name" ]; then 

		#CHECK CACHE
		expected_name=$(grep "$address" < "$base_directory/.public_name_cache" | awk -F "\t" '{print $2}')

		#IF CACHE DOES NOT EXIST, TRY TO SCAN
		if [ -z "$expected_name" ]; then 

			#DOES SCAN PROCESS CURRENTLY EXIST? 
			kill -0 "$scan_pid" >/dev/null 2>&1 && scan_active=true || scan_active=false 

		 	#ONLY SCAN IF WE ARE NOT OTHERWISE SCANNING; NAME FOR THIS DEVICE IS NOT IMPORTANT
		 	if [ "$scan_active" == false ] && [ -n "$2" ] ; then 

				#FIND NAME OF THIS DEVICE
				expected_name=$(hcitool -i "$PREF_HCI_DEVICE" name "$address" 2>/dev/null)

				#IS THE EXPECTED NAME BLANK? 
				if [ -n "$expected_name" ]; then 

					#ADD TO SESSION ARRAY
					known_public_device_name[$address]="$expected_name"

					#ADD TO CACHE
					echo "$data	$expected_name" >> .public_name_cache
				fi 
			fi 
		else
			#WE HAVE A CACHED NAME, ADD IT BACK TO THE PUBLIC DEVICE ARRAY 
			known_public_device_name[$address]="$expected_name"
		fi
	fi 

	echo "$expected_name"
}

# ----------------------------------------------------------------------------------------
# BACKGROUND PROCESSES
# ----------------------------------------------------------------------------------------

#SET LOG
(2>&1 1>/dev/null rm .pids)

log_listener &
listener_pid="$!"
echo "> log listener pid = $listener_pid" >> .pids
disown "$listener_pid"

btle_scanner & 
btle_scan_pid="$!"
echo "> btle scan pid = $btle_scan_pid" >> .pids
disown "$btle_scan_pid"

btle_text_listener &
btle_text_pid="$!"
echo "> btle text pid = $btle_text_pid" >> .pids
disown "$btle_text_pid"

mqtt_listener &
mqtt_pid="$!"
echo "> mqtt listener pid = $mqtt_pid" >> .pids
disown "$mqtt_pid"

refresh_databases &
database_clock_pid="$!"
echo "> database clock pid = $database_clock_pid" >> .pids
disown "$database_clock_pid"

echo "================== BEGIN LOGGING =================="

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

		#FLAGS TO DETERMINE FRESHNESS OF DATA
		is_new=false
		rssi_updated=false
		did_change=false

		#CLEAR DATA IN NONLOCAL VARS
		manufacturer="Unknown"
		name=""
		expected_name=""
		mac=""
		rssi=""
		adv_data=""
		pdu_header=""
		power=""
		major=""
		minor=""
		uuid=""
		beacon_type="GENERIC_BEACON"

		#PROCEED BASED ON COMMAND TYPE
		if [ "$cmd" == "ENQU" ]; then 

			#WE HAVE AN ENQUEUED OPPOSITE SCAN; NEED TO TRIGGER THAT SCAN
			if [ "$data" == "arrive" ]; then 

				#LOG
				log "${GREEN}[ENQ-ARR]	${NC}Enqueued arrival scan triggered.${NC}" 

				#WAIT 5 SECONDS
				sleep 5
				
				#TRIGGER 
				perform_arrival_scan

			elif [ "$data" == "depart" ]; then 		
				#LOG
				log "${GREEN}[ENQ-DEP]	${NC}Enqueued depart scan triggered.${NC}" 

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

			data="$mac"

			#GET LAST RSSI
			rssi_latest="${rssi_log[$data]}"
			expected_name="${known_public_device_name[$mac]}"

			#IF WE HAVE A NAME; UNSEAT FROM RANDOM AND ADD TO STATIC
			#THIS IS A BIT OF A FUDGE, A RANDOM DEVICE WITH A LOCAL 
			#NAME IS TRACKABLE, SO IT'S UNLIKELY THAT ANY CONSUMER
			#ELECTRONIC DEVICE OR CELL PHONE IS ASSOCIATED WITH THIS 
			#ADDRESS. CONSIDER THE ADDRESS AS A STATIC ADDRESS

			#ALSO NEED TO CHECK WHETHER THE RANDOM BROADCAST
			#IS INCLUDED IN THE KNOWN DEVICES LOG...

			if [ -n "$name" ] || [ -n "$expected_name" ]; then 
				#RESET COMMAND
				cmd="PUBL"
				unset "random_device_log[$mac]"

				#BEACON TYPE
				beacon_type="GENERIC_BEACON_RANDOM"

				#SAVE THE NAME
				known_public_device_name[$mac]="$name"
				rssi_log[$mac]="$rssi"

				#IS THIS A NEW STATIC DEVICE?
				[ -z "${public_device_log[$mac]}" ] && is_new=true
				public_device_log[$mac]="$timestamp"

			else
				#IS THIS ALREADY IN THE STATIC LOG? 
				if [ -n  "${public_device_log[$mac]}" ]; then 
					#IS THIS A NEW STATIC DEVICE?
					public_device_log[$mac]="$timestamp"
					rssi_log[$mac]="$rssi"
					cmd="PUBL"

					#BEACON TYPE
					beacon_type="GENERIC_BEACON_RANDOM"

				else 

					#DATA IS RANDOM MAC Addr.; ADD TO LOG
					[ -z "${random_device_log[$mac]}" ] && is_new=true

					#CALCULATE INTERVAL
					last_appearance=${random_device_log[$mac]}
					rand_interval=$((timestamp - last_appearance))	

					#ONLY ADD THIS TO THE DEVICE LOG 
					random_device_log[$mac]="$timestamp"
					rssi_log[$mac]="$rssi"
				fi 
			fi

		elif [ "$cmd" == "SCAN" ]; then 

			#ADD TO THE SCAN LOG
			known_static_device_scan_log[$data]=$(date +%s)
			continue

		elif [ "$cmd" == "DONE" ]; then 

			#SCAN MODE IS COMPLETE
			scan_pid=""

			#SET LAST ARRIVAL OR DEPARTURE SCAN
			[ "$scan_type" == "0" ] && last_arrival_scan=$(date +%s)
			[ "$scan_type" == "1" ] && last_depart_scan=$(date +%s)

			scan_type=""
			continue

		elif [ "$cmd" == "MQTT" ]; then 
			#GET INSTRUCTION 
			topic_path_of_instruction=$(echo "$data"  | sed 's/ {.*//')
			data_of_instruction=$(echo "$data" | sed 's/.* {//;s/^/{/g')

			#IGNORE INSTRUCTION FROM SELF
			if [[ $data_of_instruction =~ .*$mqtt_publisher_identity.* ]]; then 
				continue
			fi 

			#GET THE TOPIC 
			mqtt_topic_branch=$(basename "$topic_path_of_instruction")

			#NORMALIZE TO UPPERCASE
			mqtt_topic_branch=${mqtt_topic_branch^^}

			if [[ $mqtt_topic_branch =~ .*ARRIVE.* ]]; then 

				log "${GREEN}[INSTRUCT] ${NC}mqtt trigger arrive ${NC}"
				perform_arrival_scan
				
			elif [[ $mqtt_topic_branch =~ .*DEPART.* ]]; then 
				log "${GREEN}[INSTRUCT] ${NC}mqtt trigger depart ${NC}"
				
				#DEPART SCAN
				perform_departure_scan		

			elif [[ $mqtt_topic_branch =~ .*RESTART.* ]]; then 
				log "${GREEN}[INSTRUCT] ${NC}mqtt restart  ${NC}"
				
				#RESTART SYSTEM
				systemctl restart monitor.service		

			elif [[ $mqtt_topic_branch =~ .*UPDATEBETA.* ]]; then 
				log "${GREEN}[INSTRUCT] ${NC}mqtt update beta branch ${NC}"
				
				#GIT FETCH
				git fetch
				
				#GIT FETCH
				git checkout beta				
				
				#GIT PULL
				git pull

				#RESTART SYSTEM
				systemctl restart monitor.service	
				
			elif [[ $mqtt_topic_branch =~ .*UPDATE.* ]]; then 
				log "${GREEN}[INSTRUCT] ${NC}mqtt update master branch ${NC}"
				
				#GIT FETCH
				git fetch
				
				#GIT FETCH
				git checkout master				
				
				#GIT PULL
				git pull

				#RESTART SYSTEM
				systemctl restart monitor.service				
			fi

		elif [ "$cmd" == "REFR" ]; then 

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
			
			#PURGE OLD KEYS FROM THE RANDOM DEVICE LOG
			for key in "${!random_device_log[@]}"; do

				is_beacon=false
				#IS THIS RANDOM ADDRESS ASSOCIATED WITH A BEACON
				for beacon_key in "${!beacon_private_address_log[@]}"; do
					if [ "$beacon_key" == "$key" ]; then 
						is_beacon=true
						continue 
					fi 
				done

				#IF THIS IS ASSOCIATED WITH A BEACON, WE SKIP IT. 
				[ "$is_beacon" == true ] && continue 

				#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
				last_seen=${random_device_log[$key]}
				difference=$((timestamp - last_seen))

				#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
				[ -z "$last_seen" ] && continue 

				#TIMEOUT AFTER 120 SECONDS
				if [ "$difference" -gt "$PREF_RANDOM_DEVICE_EXPIRATION_INTERVAL" ]; then 
					unset "random_device_log[$key]"
					[ -z "${blacklisted_devices[$key]}" ] && log "${BLUE}[DEL-RAND]	${NC}RAND $key expired after $difference seconds ${NC}"
			
					#AT LEAST ONE DEVICE EXPIRED
					should_scan=true 
				fi 
			done

			#RANDOM DEVICE EXPIRATION SHOULD TRIGGER DEPARTURE SCAN
			[ "$should_scan" == true ] && [ "$PREF_TRIGGER_MODE_DEPART" == false ] && perform_departure_scan

			#PURGE OLD KEYS FROM THE BEACON DEVICE LOG
			for key in "${!public_device_log[@]}"; do

				#DETERMINE THE LAST TIME THIS MAC WAS LOGGED
				last_seen=${public_device_log[$key]}
				difference=$((timestamp - last_seen))

				#CONTINUE IF DEVICE HAS NOT BEEN SEEN OR DATE IS CORRUPT
				[ -z "$last_seen" ] && continue 

				#GET EXPECTED NAME
				expected_name="$(determine_name "$key")"

				#determine manufacturer
				local_manufacturer="$(determine_manufacturer "$key")"

				#RSSI
				latest_rssi="${rssi_log[$key]}" 

				#TIMEOUT AFTER 120 SECONDS
				if [ "$difference" -gt "$PREF_BEACON_EXPIRATION" ]; then 

					unset "public_device_log[$key]"
					[ -z "${blacklisted_devices[$key]}" ] && log "${BLUE}[DEL-PUBL]	${NC}PUBL/BEAC $key expired after $difference seconds ${NC}"

					#REPORT PRESENCE OF DEVICE
					[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$key]}" ] && publish_presence_message "$mqtt_publisher_identity/$key" "0" "$expected_name" "$local_manufacturer" "$beacon_type" 

				else 
					#SHOULD REPORT A DROP IN CONFIDENCE? 
					percent_confidence=$(( 100 - difference * 100 / PREF_BEACON_EXPIRATION )) 

					if [ "$PREF_REPORT_ALL_MODE" == true ]; then						#REPORTING ALL 
						[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$key]}" ] && publish_presence_message "$mqtt_publisher_identity/$key" "$percent_confidence" "$expected_name" "$local_manufacturer" "$beacon_type" "$latest_rssi" "" "$adv_data"
					fi  

					#REPORT PRESENCE OF DEVICE ONLY IF IT IS ABOUT TO BE AWAY
					[ "$PREF_BEACON_MODE" == true ] && [ -z "${blacklisted_devices[$key]}" ] && [ "$percent_confidence" -lt "50" ] && publish_presence_message "$mqtt_publisher_identity/$key" "$percent_confidence" "$expected_name" "$local_manufacturer" "$beacon_type" "$latest_rssi" "" "$adv_data"
				fi 
			done

		elif [ "$cmd" == "PUBL" ]; then 
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

			data="$mac"
			beacon_type="GENERIC_BEACON_PUBLIC"

			#SET NAME 
			[ -n "$name" ] && known_public_device_name[$mac]="$name"
			[ -z "$name" ] &&  name="$(determine_name "$data")"

			#DATA IS PUBLIC MAC Addr.; ADD TO LOG
			[ -z "${public_device_log[$data]}" ] && is_new=true

			#GET LAST RSSI
			rssi_latest="${rssi_log[$data]}" 

			#IF NOT IN DATABASE, BUT FOUND HERE
			if [ -n "$name" ]; then 
				known_public_device_name[$data]="$name"

				#GET NAME FROM CACHE
				cached_name=$(grep "$data" < ".public_name_cache" | awk -F "\t" '{print $2}')

				#ECHO TO CACHE IF DOES NOT EXIST
				[ -z "$cached_name" ] && echo "$data	$name" >> .public_name_cache
			fi 

			#STATIC DEVICE DATABASE AND RSSI DATABASE
			public_device_log[$data]="$timestamp"
			rssi_log[$data]="$rssi"

			#MANUFACTURER
			[ -z "$manufacturer" ] && manufacturer="$(determine_manufacturer "$data")"

		elif [ "$cmd" == "NAME" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			name=$(echo "$data" | awk -F "|" '{print $2}')
			data="$mac"

			#PREVIOUS STATE; SET DEFAULT TO UNKNOWN
			previous_state="${known_public_device_log[$mac]}"
			[ -z "$previous_state" ] && previous_state=-1

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer "$data")"

			#IF NAME IS DISCOVERED, PRESUME HOME
			if [ -n "$name" ]; then 
				known_public_device_log[$mac]=1
				[ "$previous_state" != "1" ] && did_change=true
			else
				known_public_device_log[$mac]=0
				[ "$previous_state" != "0" ] && did_change=true
			fi 

		elif [ "$cmd" == "BEAC" ]; then 

			#DATA IS DELIMITED BY VERTICAL PIPE
			uuid=$(echo "$data" | awk -F "|" '{print $1}')
			major=$(echo "$data" | awk -F "|" '{print $2}')
			minor=$(echo "$data" | awk -F "|" '{print $3}')
			rssi=$(echo "$data" | awk -F "|" '{print $4}')
			power=$(echo "$data" | awk -F "|" '{print $5}')
			mac=$(echo "$data" | awk -F "|" '{print $6}')
			beacon_type="APPLE_IBEACON"

			#GET MAC AND PDU HEADER
			uuid_reference="$uuid-$major-$minor"
			pdu_header=$(echo "$data" | awk -F "|" '{print $7}')

			#UPDATE PRIVATE ADDRESS
			beacon_private_address_log["$uuid_reference"]="$mac"

			#KEY DEFINED AS UUID-MAJOR-MINOR
			data="$uuid_reference"

			#GET LAST RSSI
			rssi_latest="${rssi_log[$data]}" 
			[ -z "${public_device_log[$data]}" ] && is_new=true
			public_device_log[$data]="$timestamp"	
			rssi_log[$data]="$rssi"		
		fi

		#**********************************************************************
		#
		#
		#	THE FOLLOWING REPORTS RSSI CHANGES FOR PUBLIC OR RANDOM DEVICES 
		#	
		#
		#**********************************************************************

				#REPORT RSSI CHANGES
		if [ "$cmd" == "PUBL" ] || [ "$cmd" == "BEAC" ]; then 

			#SET RSSI LATEST IF NOT ALREADY SET 
			[ -z "$rssi_latest" ] && rssi_latest="-100"

			#IS RSSI THE SAME? 
			rssi_change=$((rssi - rssi_latest))
			abs_rssi_change=${rssi_change#-}

			#DO WE HAVE A NAME?
			expected_name="$(determine_name "$mac")"

			#DETERMINE MOTION DIRECTION
			motion_direction="Departing"
			[ "$rssi_change" == "$abs_rssi_change" ] && motion_direction="Approaching"

			#IF POSITIVE, APPROACHING IF NEGATIVE DEPARTING
			case "1" in
				$(( abs_rssi_change >= 50)) )
					change_type="fast $motion_direction"
					;;
				$(( abs_rssi_change >= 30)) )
					change_type="moderate $motion_direction"
					;;
				$(( abs_rssi_change >= 10)) )
					change_type="slow movement"
					;;			
				*)
					change_type="stationary"
					;;	
			esac

			#ONLY PRINT IF WE HAVE A CHANCE OF A CERTAIN MAGNITUDE
			[ -z "${blacklisted_devices[$mac]}" ] && [ "$abs_rssi_change" -gt "$PREF_RSSI_CHANGE_THRESHOLD" ] && log "${CYAN}[CMD-RSSI]	${NC}$data $expected_name ${GREEN}$cmd ${NC}RSSI: $rssi dBm ($change_type, changed $rssi_change) ${NC}" && rssi_updated=true
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
			expected_name="$(determine_name "$mac")"
			current_state="${known_public_device_log[$mac]}"

			#IF NAME IS NOT PREVIOUSLY SEEN, THEN WE SET THE STATIC DEVICE DATABASE NAME
			[ -z "$expected_name" ] && [ -n "$name" ] && known_public_device_name[$data]="$name" 
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
			[ "$did_change" == true ] && [ "$current_state" == "1" ] && [ "$PREF_TRIGGER_MODE_REPORT_OUT" == true ] && publish_cooperative_scan_message "arrive"

			#PRINT RAW COMMAND; DEBUGGING
			log "${CYAN}[CMD-$cmd]	${NC}$data ${GREEN}$debug_name ${NC} $manufacturer${NC}"
		
		elif [ "$cmd" == "BEAC" ] && [ "$PREF_BEACON_MODE" == true ] && [ "$rssi_updated" == true ]; then 
		
			#PROVIDE USEFUL LOGGING
			if [ -z "${blacklisted_devices[$data]}" ]; then 
				log "${GREEN}[CMD-$cmd]	${NC}$data ${GREEN}$uuid $major $minor ${NC}$expected_name${NC} $manufacturer${NC}"
				publish_presence_message "$mqtt_publisher_identity/$uuid-$major-$minor" "100" "$name" "$manufacturer" "$beacon_type" "$rssi" "$power" "$adv_data"
			fi 
		
		elif [ "$cmd" == "PUBL" ] && [ "$PREF_BEACON_MODE" == true ] && [ "$rssi_updated" == true ]; then 

			#PUBLISH PRESENCE MESSAGE FOR BEACON
			if [ -z "${blacklisted_devices[$data]}" ]; then 
				log "${PURPLE}[CMD-$cmd]${NC}	$data $pdu_header ${GREEN}$expected_name${NC} ${BLUE}$manufacturer${NC} $rssi dBm "
				publish_presence_message "$mqtt_publisher_identity/$mac" "100" "$name" "$manufacturer" "$beacon_type" "$rssi" "" "$adv_data"
			fi 

		elif [ "$cmd" == "RAND" ] && [ "$is_new" == true ] && [ "$PREF_TRIGGER_MODE_ARRIVE" == false ] && [ -z "${blacklisted_devices[$mac]}" ]; then 
			
			#PROVIDE USEFUL LOGGING
			log "${RED}[CMD-$cmd]${NC}	$data $pdu_header $rssi dBm [$manufacturer - $device_type ($flags, $oem_data)] (new device arrival trigger)"

			#SCAN ONLY IF WE ARE NOT IN TRIGGER MODE
			perform_arrival_scan 
		fi 

		#SHOUD WE PERFORM AN ARRIVAL SCAN AFTER THIS FIRST LOOP?
		if [ "$first_arrive_scan" == true ] ; then 

			perform_arrival_scan 
		fi 

	done < main_pipe
done
