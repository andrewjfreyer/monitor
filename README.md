monitor
=======
***TL;DR***: Bluetooth-based passive presence detection of beacons, cell phones, and any other bluetooth device. The system is useful for [mqtt-based](http://mqtt.org) home automation. Installation instructions [here.](#installation-instructions-raspbian-lite-stretch) Getting started instructions and description [here.](#getting-started)

____

### *Table Of Contents*

  * [**Highlights**](#highlights)
  
  * [**Summary**](#summary)
  
  * [**Background on BTLE**](#background-on-btle) 
    
    * [Connectable Devices](#connectable-devices) ***TL;DR***: Some bluetooth devices only advertise an ability to connect, but do not publicly advertise their identity. These devices need to be affirmatively scanned by a host to verify their identity. *Example: bluetooth-enabled phones*
    
    * [Beacon Devices](#beacon-devices) ***TL;DR***: Other bluetooth devices advertise both (1) an ability to connect and (2) a unique identifier that can be used to identify a specific device. *Example: BTLE beacons*

    * [Using Advertisements to Trigger "Name" Scans](#using-advertisements-to-trigger-name-scans) ***TL;DR***: We can use a random advertisement (from an unknown device) as a trigger for scanning for a known bluetooth device. Neat!

  * [**Example with Home Assistant**](#example-with-home-assistant) 

  * [**Installing on a Raspberry Pi Zero W**](#installation-instructions-raspbian-lite-stretch) 

  * [**Getting Started**](#getting-started) 
____

<h1>Highlights</h1>

* More granular, responsive, and reliable than device-reported GPS or arp/network-based presence detection 

* Cheaper, more reliable, more configurable, and less spammy than [Happy Bubbles](https://www.happybubbles.tech) (which, unfortunately, is no longer operating as of 2018 because of [tarrifs](https://www.happybubbles.tech/blog/post/2018-hiatus/)) or [room-assistant](https://github.com/mKeRix/room-assistant) 

* Does not require any app to be running or installed on any device 

* Does not require device pairing 

* Designed to run as service on a [Raspberry Pi Zero W](https://www.raspberrypi.org/products/raspberry-pi-zero-w/) on Raspbian  Lite Stretch.

<h1>Summary</h1>

A JSON-formatted MQTT message is reported to a specified broker whenever a specified bluetooth device responds to a **name** query. Optionally, a JSON-formatted MQTT message is reported to the broker whenever a public device or an iBeacon advertises its presence. A configuration file defines 'known_static_addresses'. These should be devices that do not advertise public addresses, such as cell phones, tablets, and cars. You do not need to add iBeacon mac addresses into this file, since iBeacons broadcast their own UUIDs consistently. 

___

<h1>Background on BTLE</h1>

The BTLE 4.0 spec was designed to make connecting bluetooth devices simpler for the user. No more pin codes, no more code verifications, no more “discovery mode” - for the most part. 

It was also designed to be much more private than previous bluetooth specs. But it’s hard to maintain privacy when you want to be able to connect to an unknown device without substantive user intervention, so a compromise was made. 

The following is oversimplified and not technically accurate in most cases, but should give the reader a gist of how `monitor` determines presence. 

<h2>Connectable Devices</h2>

BTLE devices that can exchange information with other devices advertise their availability to connect to other devices, but the “mac” address they use to refer to themselves will be random, and will periodically change. This prevents bad actors from tracking your phone via passive bluetooth monitoring. A bad actor could track the random mac that your phone broadcasts, but that mac will change every few moments to a completely different address, making the tracking data useless.

Also part of the BTLE spec (and pre-LE spec) is a feature called a `name` request. A device can request a human-readable name of a device without connecting to that device *but only if the requesting device affirmatively knows the hardware mac address of the target device.* To see an example of this, try to connect to a new bluetooth device using your Android Phone or iPhone - you'll see a human-readable name of devices around you, some of which are not under your control. All of these devices have responded to a `name` request sent by your phone (or, alternatively, they have included their name in an advertisement received by your phone).

<h2>Beacon Devices</h2>

The BTLE spec was used by Apple, Google, and others to create additional standards (e.g., iBeacon, Eddystone, and so on). These "beacon" standards didn't care that the MAC addresses that were periodically broadcast were random. Instead, these devices would encode additional information into the broadcast data. Importantly, most devices that conform to these protocols will consistenly broadcast a UUID that conforms to the 8-4-4-4-12 format defined by [IETC RFC4122](http://www.ietf.org/rfc/rfc4122.txt).

<h2>Using Advertisements to Trigger "Name" Scans</h2>

So, we now know a little bit more about ‘name’ requests which need a previously-known hardware mac address and ‘random advertisements’ which include ostensibly useless mac addresses that change every few moments.

To see these things in action, you can use hcitool and hcidump. For example, to see your phone respond to a ‘name’ request, you can type this command:

```hcitool name 00:00:00:00:00:00```

Of course, replace your hardware bluetooth mac address with the ```00:00…``` above.

To see your phone's random advertisements (along with other random advertisements), you will need to launch a bluetooth LE scan and, separately, monitor the output from your bluetooth radio using hcidump

```sudo hcitool lescan & ; sudo hcidump --raw```

This command will output the faw BTLE data that is received by your bluetooth hardware while the `hcidump` process is operating. Included in this data are **ADV_RAND** responses.

The `monitor` script, with default settings, will request a name from your owner device *after a new random advertisement is detected.* If there are no devices that randomly advertise, monitor will never scan for new devices, clearing 2.4GHz spectrum for Wi-Fi use. The `monitor` script will also detect and report the UUID of nearby iBeacons. Below is a simplified flowchart showing the operation of `monitor`, showing the flows for both detection of arrival and detection of departure:

<img src="https://user-images.githubusercontent.com/6710151/44170856-d9d53500-a095-11e8-9d21-7e5885397df5.png" alt="monitor_flowchart" width="750" align="middle">

Here's the `monitor` helpfile, as reference:

```
monitor.sh

Andrew J Freyer, 2018
GNU General Public License

----- Summary -----

This is a shell script and a set of helper scripts that passively 
monitor for specified bluetooth devices, iBeacons, and bluetooth 
devices that publicly advertise. Once a specified device, iBeacon, or 
publicly device is found, a report is made via MQTT to a specified 
MQTT broker. When a previously-found device expires or is not found, 
a report is made via MQTT to the broker that the device has departed. 

----- Background ----- 

By default, most BTLE devices repeatedly advertise their presence with a 
random mac address at a random interval. The randomness is to maintain 
privacy and to prevent device tracking by bad actors or advertisers. 

----- Description ----- 

By knowing the static bluetooth mac address of a specified 
bluetooth device before hand, a random advertisement can be used 
as a trigger to scan for the presence of that known device. This 
construction enables the script to rapidly detect the arrival of 
a specified bluetooth device, while reducing the number of times 
an affirmative scan operation is required (which may interfere 
with 2.4GHz Wi-Fi).


usage:

  monitor -h  show usage information
  monitor -R  redact private information from logs
  monitor -m  send heartbeat signal
  monitor -C  clean retained messages from MQTT broker
  monitor -e  report bluetooth environment periodically via mqtt at topic: \$mqtt_topicpath/environment 
  monitor -E  report scan status messages: \$mqtt_topicpath/scan/[arrive|depart]/[start|end]
  monitor -c  clean manufacturer cache and generic beacon cache
  monitor -v  print version number
  monitor -d  restore to default settings
  monitor -u  update 'monitor.service' to current command line settings
      (excluding -u and -d flags)

  monitor -r  repeatedly scan for arrival & departure of known devices
  monitor -f  format MQTT topics with only letters and numbers
  monitor -b  report iBeacon advertisements and data
  monitor -a  report all known device scan results, not just changes
  monitor -x  retain mqtt status messages
  monitor -g  report generic bluetooth advertisements
  monitor -t[adr] scan for known devices only on mqtt trigger messages:
        a \$mqtt_topicpath/scan/ARRIVE (defined in MQTT preferences file)
        d \$mqtt_topicpath/scan/DEPART (defined in MQTT preferences file)
        r send ARRIVE or DEPART messages to trigger other devices to scan 
  

```
___

<h1>Example with Home Assistant</h1>

I have three **raspberry pi zero w**s throughout the house. We spend most of our time on the first floor, so our main 'sensor' is the first floor. Our other 'sensors' on the second and third floor are set up to trigger only, with option ```-t```. 

The first floor constantly monitors for advertisements from generic bluetooth devices and ibeacons. The first floor also monitors for random advertisements from other bluetooth devices, which include our phones. When a "new" random device is seen (*i.e.,* an advertisement is received), the first floor pi then scans for the fixed address of our cell phones. These addresses are are stored in the **known_static_addresses** file. If one of those devices is seen, an mqtt message is sent to Home Assistant reporting that the scanned phone is "home" with a confidence of 100%. In addition, an mqtt message is sent to the second and third floor to trigger a scan on those floors as well. 

When we leave the house, we use either the front door or the garage door to trigger an mqtt trigger of ```[topic_path]/scan/depart``` after a ten second delay to trigger a departure scan of our devices. The ten second delay gives us a chance to get out of bluetooth range before a "departure" scan is triggered. Different houses/apartments will probably need different delays. 

[Home Assistant](https://www.home-assistant.io) receives mqtt messages and stores the values as input to a number of [mqtt sensors](https://www.home-assistant.io/components/sensor.mqtt/). Output from these sensors can be averaged to give an accurate numerical occupancy confidence.  

For example (note that 00:00:00:00:00:00 is an example address - this should be your phone's address):


```
- platform: mqtt
  state_topic: 'location/first floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'First Floor'

- platform: mqtt
  state_topic: 'location/second floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Second Floor'

- platform: mqtt
  state_topic: 'location/third floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Third Floor'

```

These sensors can be combined/averaged using a [min_max](https://www.home-assistant.io/components/sensor.min_max/):

```
- platform: min_max
  name: "Home Occupancy Confidence of 00:00:00:00:00:00"
  type: max
  round_digits: 0
  entity_ids:
    - sensor.third_floor
    - sensor.second_floor
    - sensor.first_floor
```

Then I use the entity **sensor.home_occupancy_confidence** in automations to control the state of an **input_boolean** that represents a very high confidence of a user being home or not. 

As an example:

```
- alias: Occupancy 
  hide_entity: true
  trigger:
    - platform: numeric_state
      entity_id: sensor.home_occupancy_confidence
      above: 10
  action:
    - service: homeassistant.turn_on
      data:
        entity_id: input_boolean.occupancy
```

___


<h1>Installation Instructions (Raspbian Lite Stretch):</h1>

<h2>Setup of SD Card</h2>

1. Download latest version of **rasbpian lite stretch** [here](https://downloads.raspberrypi.org/raspbian_lite_latest)

2. Download etcher from [etcher.io](https://etcher.io)

3. Image **raspbian lite stretch** to SD card. [Instructions here.](https://www.raspberrypi.org/magpi/pi-sd-etcher/)

4. Mount **boot** partition of imaged SD card (unplug it and plug it back in)

5. **[ENABLE SSH]** Create blank file, without any extension, in the root directory called **ssh**

6. **[SETUP WIFI]** Create **wpa_supplicant.conf** file in root directory and add Wi-Fi details for home Wi-Fi:

```
country=US
    ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
    update_config=1

network={
    ssid="Your Network Name"
    psk="Your Network Password"
    key_mgmt=WPA-PSK
}
```

 7. **[FIRST STARTUP]** Insert SD card and power on Raspberry Pi Zero W. On first boot, the newly-created **wpa_supplicant.conf** file and **ssh** will be moved to appropriate directories. Find the IP address of the Pi via your router. One method is scanning for open ssh ports (port 22) on your local network:
```
nmap 192.168.1.0/24 -p 22
```

<h2>Configuration and Setup of Raspberry Pi Zero W</h2>

1. SSH into the Raspberry Pi (password: raspberry):
```
ssh pi@theipaddress
```

2. Change the default password:
```
sudo passwd pi
```

3. **[PREPARATION]** Update and upgrade:

```
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get dist-upgrade -y
sudo apt-get install rpi-update
sudo rpi-update
sudo reboot
```

5. **[BLUETOOTH]** Install Bluetooth Firmware, if necessary:
```
#install bluetooth drivers for Pi Zero W
sudo apt-get install pi-bluetooth

```

6. **[REBOOT]**
```
sudo reboot
```

7. **[INSTALL MOSQUITTO]**
```

# get repo key
wget http://repo.mosquitto.org/debian/mosquitto-repo.gpg.key

#add repo
sudo apt-key add mosquitto-repo.gpg.key

#download appropriate lists file 
cd /etc/apt/sources.list.d/
sudo wget http://repo.mosquitto.org/debian/mosquitto-stretch.list

#update caches and install 
apt-cache search mosquitto
sudo apt-get update
sudo aptitude install libmosquitto-dev mosquitto mosquitto-clients
```

8. **[INSTALL MONITOR]**
```
#install git
cd ~
sudo apt-get install git

#clone this repo
git clone git://github.com/andrewjfreyer/monitor

#enter monitor directory
cd monitor/
```

9. **[INITIAL RUN]** run monitor:

```sudo bash monitor.sh```

Configuration files will be created with default preferences. Any executables that are not installed will be reported. All can be installed via ```apt-get intall ...```


10. **[CONFIGURE MQTT]** edit **mqtt_preferences**:
```
sudo nano mqtt_preferences
```

11. **[CONFIGURE MONITOR]** edit **known_static_addresses**: 

```
sudo nano known_static_addresses
```

12. **[READ HELPFILE]**:

```
sudo bash monitor.sh -h
```

That's it. Your broker should be receiving messages and the monitor service will restart each time the Raspberry Pi boots. As currently configured, you should run `sudo bash monitor.sh` a few times from your command line to get a sense of how the script works. 

____

### *Getting Started*

  * [**Cell Phone Tracking**](#cell-phone-or-laptop)

  * [**Smartwatch/Fitness Band**](#smart-watch--fitness-band--bluetooth-beacon)

  * [**Advanced Configuration**](#advanced-configurations)

Ok, here we go! Please note that this documentation is a work in progress - more content will be added later!

<h2>Cell Phone or Laptop</h2>

Tracking presence of cell phones is the original purpose of `monitor` and `presence`. It's a particularly good choice because most of us always have our phones and we don't have to replace batteries periodically like we do with beacon devices. 

First, we're going to need the Bluetooth Mac address from each phone that you want to track. This can be found in Settings on your phone. For example, on an iPhone look in Settings > General > About and scroll about halfway down. Make sure to copy the *Bluetooth* address and not the Wi-Fi address. 

Now, `ssh` to the pi that's running the script. 

```ssh username@ipaddress```

Stop the script while we're working with preferences and options: 

```
sudo systemctl stop monitor.service
```

Change directory into `monitor`:

`cd monitor`

And make sure that you're running the most recent version: 

`git pull`

Now, add that address to your `known_static_addresses` file created when you ran `monitor` the first time. To do this from the command line, you can use your favorite text editor. I prefer `nano`:

```
sudo nano known_static_addresses
```

Add the mac address that you copied for your phone at the end of the file. Next to the mac address, you can add a "nickname" or a hash-prepended comment if you like. For example: 

```
00:11:22:33:44:55 Andrew's iPhone #this is a comment and everything after the hashmark is ignored
```

Do this with all other cell phone/laptop devices that you'd like to track via mqtt messages posted/formatted like this:

```
topic:    location/first floor/00:11:22:33:44:55
message:  {
  retain: false
  version : 0.1.666
  address : 00:11:22:33:44:55
  confidence : 0
  name : Andrew's iPhone
  timestamp : Fri Sep 28 2018 22:41:11 GMT+0000 (UTC)
  manufacturer : Apple, Inc.
  type : KNOWN_MAC
}
```

In the above example, the confidence is 0, meaning that the device is not home. Phrased another way, the script is 0% confident that the device is home. When the phone arrives home, the message changes to: 


```
topic:    location/first floor/00:11:22:33:44:55
message:  {
  retain: false
  version : 0.1.666
  address : 00:11:22:33:44:55
  confidence : 100
  name : Andrew's iPhone
  timestamp : Fri Sep 28 2018 22:42:18 GMT+0000 (UTC)
  manufacturer : Apple, Inc.
  type : KNOWN_MAC
}
```

Got it? That's it. You're ready to scan for presence of those devices. With default settings, the script will affirmatively scan for the presence of these devices under three circumstances:

* Arrival scan (i.e., current status of a device is 'away') upon receiving an advertisement from a previously-unseen device

* Departure scan (i.e., current status of a device is 'home') after not hearing from a previously-seen device for a period of time 

* In response to an MQTT message posted to either of: `$mqtt_topicpath/scan/arrive` or `$mqtt_topicpath/scan/depart`

The MQTT messages can be sent from any other device connected to the MQTT broker you have set up. Lastly, be sure to check out [advanced configurations](#advanced-configurations) below. To finish everything up, restart the service, log-out, and forget that it's working for you!

```
sudo systemctl restart monitor.service
exit
```
<h2>Smart Watch / Fitness Band / Bluetooth Beacon</h2>

Generally, smartwatches, fitness bands, and bluetooth beacons advertise their presence without needing to know a mac address. However, unfortunately, all of these devices are a bit different and manufacturers change the way their devices advertise to promote their own proprietary hubs and applications. Some of these devices do not advertise publicly at all, which means that we'll need to to treat them like a cell phone, described above. Some of these devices ignore bluetooth LE advertising specifications and will be ignored as undetectable devices ... more on these devices later. 

Brass tacks, we have to do a bit of playing to detect beacons. The best thing to do for beacon detection is to use both the `-b` flag to detect iBeacons and the `-g` flag when running the script manually so that we can see the output. From there, we can figure out how to detect a specific beacon. 

First, stop the service: 

```
sudo systemctl stop monitor.service
```

Second, run the script manually with `-b -g` as options: 

```
sudo bash monitor.sh -b -g
```

Retreive your device that you want to track and bring it near. After a moment or two, you should see one of three things. First, you may see that your beacon is detected as an iBeacon with type APPLE_IBEACON. If this is the case, the `-b` flag is all you need to detect this beacon. Subscribe to the mqtt topic formatted as `$mqtt_topicpath/$mqtt_published/uuid-major-minor`. This will be printed in the logs, but may not in all cases be accompanied by a detected name:

```
topic:    location/first floor/00000000-0000-0000-0000-000000000000-4-12003 
message:  {
  retain: false
  version : 0.1.666
  address : 00000000-0000-0000-0000-000000000000-4-12003 
  confidence : 100
  name : Unresponsive Device
  timestamp : Fri Sep 28 2018 22:44:25 GMT+0000 (UTC)
  manufacturer : Unknown
  type : APPLE_IEACON
  rssi : -93 
  power: [if available]
  uuid: [if available]
  major: [if available]
  minor: [if available]
  adv_data :  [if available]
}
```

By subscribing to `location/first floor/00000000-0000-0000-0000-000000000000-4-12003`, presence of the iBeacon can be determined.


A second thing you may see that your beacon is detected a GENERIC_BEACON. If this is the case, the `-g` flag is all you need to detect this beacon. For example, you may see:

```
topic:    location/first floor/04:FE:00:00:00 
message:  {
  retain: false
  version : 0.1.666
  address : 04:FE:00:00:00 
  confidence : 100
  name : Unresponsive Device
  timestamp : Fri Sep 28 2018 22:44:25 GMT+0000 (UTC)
  manufacturer : Fihonest communication co.,Ltd
  type : GENERIC_BEACON
  rssi : -93 
  adv_data :  [if available]
}
```

By subscribing to `location/first floor/04:FE:00:00:00`, presence of the generic beacon can be determined.

If you cannot see your beacon in either of these, find the mac address of your beacon and add it to the `known_beacon_addresses` file. Then, use the `-g` flag. 

To update the service with these options, you can use the `-u` flag:

``` sudo bash monitor.sh -b -g -u```

Got it? That's it. You're ready to listen for presence of your beacon. With either or both the `-b` or `-g` flag, the script will passively monitor for the presence of these devices and if the device is not heard from for a certain time period, confidence will drop, eventually to zero. Lastly, be sure to check out [advanced configurations](#advanced-configurations) below. To finish everything up, restart the service, log-out, and forget that it's working for you!

```
sudo systemctl restart monitor.service
exit
```

<h2>Advanced Configurations</h2>

One of the benefits of `monitor` is configurability. In addition to the runtime options that are explained in the helpfile reproduced above, the `behavior_preferences` file is included to modify the behavior of `monitor`. What follows is a more detailed explaination of these options: 

```
#DELAY BETWEEN SCANS OF DEVICES
PREF_INTERSCAN_DELAY=3
```

This option is the delay in seconds between each affirmative name scan in a sequence of name scans. This applies only to scanning for cell phones/devices in the `known_static_addresses` file. The larger this number, the longer on average arrival detection will take but, also, the lower interference with 2.4GHz spectrum should be expected. 


```
#DETERMINE HOW OFTEN TO CHECK FOR A DEPARTED DEVICE OR AN ARRIVED DEVICE
PREF_CLOCK_INTERVAL=15
```
This is the interval, when scanning in periodic scanning mode, at which the script checks to see if an arrival scan or a deparature scan is necessary. 

```
#DEPART SCAN INTERVAL
PREF_DEPART_SCAN_INTERVAL=90
```

This is the interval, when running in periodic scanning mode, at which departure scans should be performed. 


```
#ARRIVE SCAN INTERVAL
PREF_ARRIVE_SCAN_INTERVAL=45
```


This is the interval, when running in periodic scanning mode, at which arrival scans should be performed. 

```
#MAX RETRY ATTEMPTS FOR ARRIVAL
PREF_ARRIVAL_SCAN_ATTEMPTS=3
```

This is the number of times a device should be scanned for an arrival each time an arrival scan operation is performed. This applies only to scanning for cell phones/devices in the `known_static_addresses` file. As soon as the device is detected, all other enqueued scans are discarded. 

```
#MAX RETRY ATTEMPTS FOR DEPART
PREF_DEPART_SCAN_ATTEMPTS=3
```

This is the number of times a device should be scanned for departure each time a departure scan operation is performed. This applies only to scanning for cell phones/devices in the `known_static_addresses` file. As soon as the device is detected as present, all other enqueued depart scans are discarded. 


```
#DETERMINE NOW OFTEN TO REFRESH DATABASES TO REMOVE EXPIRED DEVICES
PREF_DATABASE_REFRESH_INTERVAL=35
```

This is the interval at which the database of beacons and random devices that have been marked as "seen" by the script is checked for and cleared of expired device (i.e., devices that have not been seen for an interval).


```
#PERIOD AFTER WHICH A RANDOM BTLE ADVERTISEMENT IS CONSIDERED EXPIRED
PREF_RANDOM_DEVICE_EXPIRATION_INTERVAL=45
```
This is the interval after which a randomly-advertising device will be marked as expired. 

```
#AMOUNT AN RSSI MUST CHANGE (ABSOLUTE VALUE) TO REPORT BEACON AGAIN
PREF_RSSI_CHANGE_THRESHOLD=5
```

This is the threshold for reporting an rssi change in the logs. 


```
#BLUETOOTH ENVIRONMENTAL REPORT FREQUENCY
PREF_ENVIRONMENTAL_REPORT_INTERVAL=300
```

This is the average interval at which a bluetooth environment report is sent to the MQTT broker. 

```
#SECONDS UNTIL A BEACON IS CONSIDERED EXPIRED
PREF_BEACON_EXPIRATION=145
```

This is the interval after which a beacon device will be marked as expired. 


```
#SECONDS AFTER WHICH A DEPARTURE SCAN IS TRIGGERED
PREF_PERIODIC_FORCED_DEPARTURE_SCAN_INTERVAL=360
```
This is the interval at which a forced periodic departure scan is performed. 

```
#PREFERRED HCI DEVICE
PREF_HCI_DEVICE='hci0'
```

This is the preferred bluetooth device. 

```
#COOPERATIVE DEPARTURE SCAN TRIGGER THRESHOLD
PREF_COOPERATIVE_SCAN_THRESHOLD=25
```

This is the threshold at which a 'depart' message is sent to other `montior` instances. This applies only to scanning for cell phones/devices in the `known_static_addresses` file. For example, if a first node believes that a device has left (confidence is falling quickly to zero), then this device will trigger other `monitor` nodes by publishing to `$mqtt_topicpath/scan/depart` once confidence hits or falls below this level.  
