monitor (beta)
=======
***TL;DR***: Bluetooth-based passive presence detection of beacons, cell phones, and other bluetooth devices. The system is useful for [mqtt-based](http://mqtt.org) home automation, especially when installed on multiple devices. 

More specifically, a JSON-formatted MQTT message is reported to a specified broker whenever a specified bluetooth device responds to a `name` query. By default, `name` queries are initiated after receiving an anonymous advertisement from a previously-unknown address.  

In addition, optionally, a JSON-formatted MQTT message can be reported to the same broker whenever a publicly-advertising beacon device or an iBeacon device advertises. 
___


#### *Simplified Background on Bluetooth:*

The BTLE 4.0 spec was designed to make connecting bluetooth devices simpler for the user. No more pin codes, no more code verifications, no more “discovery mode” - for the most part. It was also designed to be much more private than previous bluetooth specs. But it’s hard to maintain privacy when you want to be able to connect to an unknown device without user intervention, so a compromise was made. The following is oversimplified and not technically accurate in most cases, but should give the reader a gist of how `monitor` determines presence. 

##### Name Requests

A part of the Blueooth spec is a special function called a `name` request that asks another Bluetooth device to send back a human-readable name of itself. In order to send a `name` request, we need to know a private (unchanging) address of the target device. 

Issuing a `name` request to the same private mac address every few seconds is a reliable - albeit rudamentary - way of detecting whether that device is "**present**" (it responds to the `name` request) or "**absent**" (no response to the `name` request is received). However, issuing `name` requests too frequently (*e.g.*, every few seconds) uses quite a bit of 2.4GHz spectrum, which can cause substantial interference with Wi-Fi or other wireless communications.

##### Connectable Devices

Blueooth devices that can exchange information with other devices (almost always) advertise a random/anonymous address that other devices can use to negotate a secure connection with that device's real, private, Bluetooth address. 

Using a random address when publicly advertising prevents baddies from tracking people via bluetooth monitoring. Monitoring for anonymous advertisement is not a reliable way to detect whether a device is **present** or **absent**. However, nearly all connectable devices respond to `name` requests if made to the device's private Bluetooth address.

##### Beacon Devices

The Bluetooth spec has been used by Apple, Google, and others to create additional standards (e.g., iBeacon, Eddystone, and so on). These devices generally don't care to conenct to other devices, so their random/anonymous addresses don't really matter. Instead, these devices encode additional information into each advertisement of an anonymous address. For example, iBeacon devices will broadcast a UUID that conforms to the 8-4-4-4-12 format defined by [IETC RFC4122](http://www.ietf.org/rfc/rfc4122.txt).

Beacons do not respond to `name` requests, even if made to the device's private Bluetooth address. So, issuing periodic `name` requests to beacons is not a reliable way to detect whether a beacon device is **present** or **absent**. However, monitoring for beacon advertisement is a reliable way to detect whether a beacon device is **present** or **absent**.

_____

#### *How `monitor` Works:*

This script combines `name` requests, anonymous advertisements, and beacon advertisements to logically determine (1) *when* to issue a `name` scan to determine whether a device is **present** and (2) *when* to issue a `name` scan to determine whether a device is **absent**. The script also listens for beacons. 

##### Known Static Addresses
More specifically, `monitor`, once installed, accesses private mac addresses that you have added to a file called `known_static_addresses`. These are the addresses for which `monitor` will issue `name` requests to determine whether or not these devices are **present** or **absent**. Once a determination of presence is made, the script posts to an mqtt topic path defined in a file called `mqtt_preferences` that includes a JSON-formatted message with a confidence value that corresponds to a confidence of presence. For example, a confidence of 100 means that `monitor` is 100% sure the device is present and present. Similarly, a confidence of 0 means that `monitor` is 0% sure the device is present (*i.e.*, the `monitor` is 100% sure the device is absent).

To minimize the number of times that `monitor` issues `name` requests (thereby reducing 2.4GHz interference), the script performs either an ***ARRIVAL*** scan or a ***DEPART*** scan, instead of scanning all devices listed in the `known_static_addresses` each time.  More specifically:

*  An ***ARRIVAL*** scan issues a `name` request *only* for devices from the `known_static_addresses` file **absent**. 

*  Similarly, a ***DEPART*** scan issues a `name` request *only* for devices from the `known_static_addresses` file that are **present**. 

So, for example, if there are two iPhone Bluetooth addresses listed in the `known_static_addresses` file, and both of those devices are **present**, an ***ARRIVAL*** scan will never occur. Similarly, if both of these addresses are **absent** then a ***DEPART*** scan will never occur. 

`monitor` listens for anonymous advertisements and, with default configuration, triggers an ***ARRIVAL*** scan for every *new* anonymous address. The script will also trigger an ***ARRIVE*** scan in response to an mqtt message posted to the topic of `monitor/scan/arrive`. Advertisement-triggered scanning can be disabled by using the trigger argument if `-ta`, which causes `monitor` to *only* trigger ***ARRIVAL*** scans in response to mqtt messages. 

If `monitor` has not heard from a particular anonymous address in a long time, `monitor` triggers a ***DEPART*** scan. The script will also trigger a ***DEPART*** scan in response to an mqtt message posted to the topic of `monitor/scan/depart`. Expiration-triggered scanning can be disabled by using the trigger argument if `-td`, which causes `monitor` to *only* trigger ***DEPART*** scans in response to mqtt messages. 

To reduce scanning even further, `monitor` can filter which types of anonymous advertisements are used for ***ARRIVE*** scans. These are called "filters" and are defined in a file called `behavior_preferences`. The filters are bash RegEx strings that either pass or reject anonymous advertisements that match the filter. There are two filter types: 

* **Manufacturer Filter** - filters based on data in an advertisement that is connected to a particular device manufacturer. This is almost always the OEM of the device that is transmitting the anonymous advertisment. By default, because of the prevalence of iPhones, Apple is the only manufacturer that triggers an ***ARRIVAL*** scan. Multiple manufacturers can be appended together by a pipe: `|`. An example filter for Apple and Samsung looks like: `Apple|Samsung`. To diable the manufacturer filter, use `.*`.

* **Flag Filter:** filters based on flags contained in an advertisement. This varies by device type. By default, because of the prevalence of iPhones, the flag of `0x1b` triggers an ***ARRIVAL*** scan. Like with the manufacturer filter, multiple flags can be appended together by a pipe: `|`. To diable the manufacturer filter, use `.*`.

##### Beacons & iBeacons
In addition, once installed and run with the `-b` beacon argument, `monitor` listens for beacon advertisements that report themselves as "public", meaning that their addresses will not change. The script can track these by default; these addresses do not have to be added anywhere - after all, `monitor` will obtain them just by listening. 

Since iBeacons include a UUID and a mac address, two presence messages are reported via mqtt. 

##### Known Beacon Addresses
In some cases, certain manufacturers try to get sneaky and cause their beacons to advertise as "anonymous" (or "random") devices, despite that their addresses do not change at all. By default, `monitor` ignores anonymous devices, so to force `monitor` to recognize these devices, we add the "random" address to a file called `known_static_beacons`. After restarting, `monitor` will know that these addresses should be treated like a normal beacon. 
___

### Example with Home Assistant

Personally, I have four **raspberry pi zero w**s throughout the house and garage. My family spends most of our time on the first floor, so our main `monitor` node or sensor is on the first floor. Our other 'nodes' on the second and third floor and garage are set up for triggered use only - these will scan for ***ARRIVAL*** and ***DEPART*** only in response to mqtt messages, with option ```-tad```. The first floor node is set up to send mqtt arrive/depart scan instructions to these nodes by including the `-tr` flag ("report" to other nodes when an arrival or depart scan is triggered). 

The first floor constantly monitors for beacons (`-b`) advertisements and anonymous advertisements, which may be sent by our phones listed in the `known_static_addresses` file. In response to a new anonymous advertisement, `monitor` will initate an ***ARRIVAL*** scan for whichever of our phones is not present.  If one of those devices is seen, an mqtt message is sent to Home Assistant reporting that the scanned phone is "home" with a confidence of 100%. In addition, an mqtt message is sent to the second and third floor and garage to trigger a scan on those floors as well. 

When we leave the house, we use either the front door or the garage door to trigger an mqtt trigger of ```monitor/scan/depart``` after a ten second delay to trigger a departure scan of our devices that were previously known to be present. The ten second delay gives us a chance to get out of bluetooth range before a "departure" scan is triggered. Different houses/apartments will probably need different delays. 

[Home Assistant](https://www.home-assistant.io) receives mqtt messages and stores the values as input to a number of [mqtt sensors](https://www.home-assistant.io/components/sensor.mqtt/). Output from these sensors is combined to give an accurate numerical occupancy confidence.  

For example (note that 00:00:00:00:00:00 is an example address - this should be your phone's private, static, bluetooth address):

```
- platform: mqtt
  state_topic: 'monitor/first floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'First Floor'

- platform: mqtt
  state_topic: 'monitor/second floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Second Floor'

- platform: mqtt
  state_topic: 'monitor/third floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Third Floor'

- platform: mqtt
  state_topic: 'monitor/garage/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Garage'
```

These sensors can be combined using a [min_max](https://www.home-assistant.io/components/sensor.min_max/):

```
- platform: min_max
  name: "Home Occupancy Confidence"
  type: max
  round_digits: 0
  entity_ids:
    - sensor.third_floor
    - sensor.second_floor
    - sensor.first_floor
    - sensor.garage
```

Thereafter, I use the entity **sensor.home_occupancy_confidence** in automations to control the state of an **input_boolean** that represents a very high confidence of a user being home or not. 

As an example:

```
- alias: Occupancy On
  hide_entity: true
  trigger:
    - platform: numeric_state
      entity_id: sensor.home_occupancy_confidence
      above: 10
  action:
    - service: homeassistant.turn_on
      data:
        entity_id: input_boolean.occupancy

- alias: Occupancy Off
  hide_entity: true
  trigger:
    - platform: numeric_state
      entity_id: sensor.home_occupancy_confidence
      below: 10
  action:
    - service: homeassistant.turn_off
      data:
        entity_id: input_boolean.occupancy
```

___
<h1>Installation Instructions for Raspberry Pi Zero W:</h1>

<h2>Setup of SD Card</h2>

1. Download latest version of **rasbpian** [here](https://downloads.raspberrypi.org/raspbian_lite_latest)

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

 7. **[FIRST STARTUP]** Insert SD card and power on Raspberry Pi Zero W. On first boot, the newly-created **wpa_supplicant.conf** file and **ssh** will be moved to appropriate directories. Find the IP address of the Pi via your router. 

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
sudo apt-get install libmosquitto-dev mosquitto mosquitto-clients
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

#switch to beta branch for latest updates
git checkout beta       

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