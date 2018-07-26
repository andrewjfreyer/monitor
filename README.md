monitor
=======

***TL;DR***: Bluetooth-based passive presence detection of beacons, cell phones, and any other bluetooth device. The system is useful for [mqtt-based](http://mqtt.org) home automation. 

More granular, responsive, and reliable than device-reported GPS. Cheaper, more reliable, more configurable, and less spammy than Happy Bubbles. Does not require any app to be running or installed. Does not require device pairing. 

Designed to run as service on a [Raspberry Pi Zero W](https://www.raspberrypi.org/products/raspberry-pi-zero-w/) on Raspbian Jessie Lite Stretch.

<h1>Summary</h1>

A JSON-formatted MQTT message is reported to a specified broker whenever a specified bluetooth device responds to a **name** query. If the device responds, the JSON message includes lots of information, including the name of the device and a **confidence** of 100. 

Optionally, a JSON-formatted MQTT message can be reported to the broker whenever a public device or an iBeacon advertises its presence. 

A configuration file defines 'known_static_devices'. These should be devices that do not advertise public addresses, such as cell phones, tablets, and cars. 

___

<h1>Background</h1>

The BTLE 4.0 spec was designed to make connecting bluetooth devices simpler for the user. No more pin codes, no more code verifications, no more “discovery mode” - for the most part. 

It was also designed to be much more private than previous bluetooth specs. But it’s hard to maintain privacy when you want to be able to connect to an unknown device without substantive user intervention (think about pairing new AirPods to an iPhone), so a compromise was made. 

BTLE devices advertise their availability to connect to other devices, but the “mac” address they use to refer to themselves will be random, and will periodically change. This prevents bad actors from tracking your phone via passive bluetooth monitoring. A bad actor could track the random mac that your phone broadcasts, but that mac will change every few moments to a completely different address, making the tracking data useless.

Also part of the BTLE spec (and pre-LE spec) is a feature called a “name” request. A device can request a human-readable name of a device without connecting to that device *but only if the requesting device affirmatively knows the hardware mac address of the target device.* Again, think about connecting your iPhone to a new pair of AirPods. The name you see on the popup isn’t “00:11:22:33:44” or similar, it’s “Andrew’s AirPods” or “New AirPods.”

So, we now know a little bit more about ‘name’ requests which need a previously-known hardware mac address and ‘random advertisements’ which include ostensibly useless mac addresses that change every few moments.

To see these things in action, you can use hcitool and hcidump. For example, to see your phone respond to a ‘name’ request, you can type this command:

```hcitool name 00:00:00:00:00:00```

Of course, replace your hardware bluetooth mac address with the ```00:00…``` above.

To see your phone's random advertisements (along with other random advertisements), you will need to launch a bluetooth LE scan and, separately, monitor the output from your bluetooth radio using hcidump

```sudo hcitool lescan & ; sudo hcidump --duplicates```

This command will output the BTLE data that is received by your bluetooth hardware. Included in this data are **ADV_RAND** responses.

Knowing this, we can jump to the differences between [presence](http://github.com/andrewjfreyer/presence) and monitor.

The [presence script](http://github.com/andrewjfreyer/presence), with default settings, requests a name from your owner devices at regular intervals. You can adjust those intervals, but your pi will be regularly ‘pinging’ for each owner device. The longer your intervals, the slower the system will be to respond. The shorter the intervals, the more quickly the system will respond, but the more 2.4GHz bandwidth is used. Now, as @eboon originally pointed out, the more often presence scans, the more likely it is that presence will interfere with 2.4GHz Wi-Fi. If you add two or more pi’s in your house, its clear that 2.4GHz spectrum being used very frequently to scan for presence of bluetooth devices. For many users, this meant that 2.4GHz Wi-Fi became unusable or unresponsive. Many users never noticed this (including myself) because we use 5GHz Wi-Fi or have a router/access point able to handle the extra bandwidth used by the [presence script](http://github.com/andrewjfreyer/presence).

On the other hand, the monitor script, with default settings, will only request a name from your owner device after a new random advertisement is detected. If there are no devices that randomly advertise, monitor will never scan for new devices, clearing 2.4GHz spectrum. For example, if you live in a house with no other bluetooth devices and no nearby neighbors, when you come home, a random advertisement (that probably came from your phone) will be detected almost immediately by monitor. Thereafter, a name request is submitted to the phone.

Here's the helpfile, as reference:

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

	monitor -h 	show usage information
	monitor -R 	redact private information from logs
	monitor -C 	clean retained messages from MQTT broker
	monitor -v	print version number
	monitor -d	restore to default settings
	monitor -u	update 'monitor.service' to current command line settings
			(excluding -u and -d flags)

	monitor -r	repeatedly scan for arrival & departure of known devices
	monitor -b	scan for & report BTLE beacon advertisements
	monitor -a	report all scan results, not just presence changes
	monitor -x	retain mqtt status messages
	monitor -P	scan for & report public address advertisements
	monitor -t	scan only on mqtt trigger messages:
				[topic path]/scan/ARRIVE
				[topic path]/scan/DEPART

```

___

<h1>An Example Use with Home Assistant</h1>

The monitor script can be used as an input to a number of [mqtt sensors](https://www.home-assistant.io/components/sensor.mqtt/) in [Home Assistant.](https://www.home-assistant.io). Output from these sensors can be averaged to give an accurate numerical occupancy confidence. 

In order to detect presence in a home that has three floors and a garage, we might inclue one Raspberry Pi per floor. For average houses, a single well-placed sensor can probably work, but for more reliability at the edges of the house, more sensors are better. 


```
- platform: mqtt
  state_topic: 'location/owner/first floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'First Floor'

- platform: mqtt
  state_topic: 'location/owner/second floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Second Floor'

- platform: mqtt
  state_topic: 'location/owner/third floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Third Floor'

```

These sensors can be combined/averaged using a [min_max](https://www.home-assistant.io/components/sensor.min_max/):

```
- platform: min_max
  name: "Home Occupancy Confidence"
  type: mean
  round_digits: 0
  entity_ids:
    - sensor.third_floor
    - sensor.second_floor
    - sensor.first_floor
```

As a result of this average, we use the entity **sensor.home_occupancy_confidence** in automations to control the state of an **input_boolean** that represents a very high confidence of a user being home or not. 

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


<h1>Installation Instructions (Raspbian Jessie Lite Stretch):</h1>

<h2>Setup of SD Card</h2>

1. Download latest version of **jessie lite stretch** [here](https://downloads.raspberrypi.org/raspbian_lite_latest)

2. Download etcher from [etcher.io](https://etcher.io)

3. Image **jessie lite stretch** to SD card. [Instructions here.](https://www.raspberrypi.org/magpi/pi-sd-etcher/)

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

11. **[CONFIGURE MONITOR]** edit **known_static_devices**: 

```
nano known_static_devices
```

12. **[READ HELPFILE]**:

```
sudo bash monitor.sh -h
```

That's it. Your broker should be receiving messages and the monitor service will restart each time the Raspberry Pi boots.  

