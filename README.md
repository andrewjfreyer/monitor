`monitor`
=======
***TL;DR***: Passive Bluetooth presence detection of beacons, cell phones, and other Bluetooth devices. Useful for [mqtt-based](http://mqtt.org) home automation, especially when the script runs on multiple devices, distributed throughout a property. 

![version](https://img.shields.io/badge/version-0.2-green.svg?maxAge=2592000) ![mosquitto](https://img.shields.io/badge/mosquitto-1.5+-blue.svg?maxAge=2592000)

[**Frequently Asked Questions**](https://github.com/andrewjfreyer/monitor/blob/master/support/README.md)

<details><summary><b>Installation Instructions</b></summary>

<br>

<details><summary><i>Set Up Raspberry Pi From Scratch</i></summary>


# Installation Instructions for Raspberry Pi Zero W

## Setup of SD Card

1. Download latest version of **raspbian** [here](https://downloads.raspberrypi.org/raspbian_lite_latest)

2. Download etcher from [etcher.io](https://etcher.io)

3. Image **raspbian lite buster** to SD card. [Instructions here.](https://www.raspberrypi.org/magpi/pi-sd-etcher/)

4. Mount **boot** partition of imaged SD card (unplug it and plug it back in)

5. **To enable ssh,** create blank file, without any extension, in the root directory called **ssh**

6. **To setup Wi-Fi**, create **wpa_supplicant.conf** file in root directory and add Wi-Fi details for home Wi-Fi:

```bash
country=US
    ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
    update_config=1

network={
    ssid="Your Network Name"
    psk="Your Network Password"
    key_mgmt=WPA-PSK
}
```

 7. **On the first startup,** insert SD card and power on Raspberry Pi Zero W. On first boot, the newly-created **wpa_supplicant.conf** file and **ssh** will be moved to appropriate directories. Find the IP address of the Pi via your router. 

## Configuration and Setup

1. SSH into the Raspberry Pi (default password: raspberry):
```bash
ssh pi@theipaddress
```

2. Change the default password:
```bash 
sudo passwd pi
```

3. Update and upgrade:

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get dist-upgrade -y
sudo reboot
```

5. Install Bluetooth Firmware, if necessary:
```bash
#install Bluetooth drivers for Pi Zero W
sudo apt-get install pi-bluetooth

```

6. Reboot:
```bash
sudo reboot
```

7. Install Mosquitto 1.5+ **(important step!)**:
```bash

# get repo key
wget http://repo.mosquitto.org/debian/mosquitto-repo.gpg.key

#add repo
sudo apt-key add mosquitto-repo.gpg.key

#download appropriate lists file 
cd /etc/apt/sources.list.d/
sudo wget http://repo.mosquitto.org/debian/mosquitto-buster.list

#update caches and install 
apt-cache search mosquitto
sudo apt-get update
sudo apt-get install -f libmosquitto-dev mosquitto mosquitto-clients libmosquitto1
```
</details>

<details><summary><i>Monitor Setup</i></summary>

## Setup `monitor`

1. Clone `monitor` git:
```bash
#install git
cd ~
sudo apt-get install git

#clone this repo
git clone git://github.com/andrewjfreyer/monitor

#enter `monitor` directory
cd monitor/

#(optional) switch to beta branch for latest updates and features (may be unstable)
git checkout beta       

```

2. Initial run:

Configuration files will be created with default preferences. Any executables that are not installed will be reported. All can be installed via `apt-get install ...`

```bash 
sudo bash monitor.sh
```


3. Edit **mqtt_preferences** file:

```bash
sudo nano mqtt_preferences
```

4. Edit **known_static_addresses** (phones, laptops, some smart watches): 

```bash
sudo nano known_static_addresses
```

Alternatively, send an mqtt message to `monitor/setup/ADD STATIC DEVICE` with a message including a mac address and an alias separated by a space:


**topic:** `monitor/setup/ADD STATIC DEVICE` 
**message:** 00:11:22:33:44:55 alias


Use, `monitor/setup/DELETE STATIC DEVICE` with a message containing a mac address to remove a device from all `monitor` nodes.

5. Read helpfile:

```bash
sudo bash monitor.sh -h
```

Now the basic setup is complete. Your broker should be receiving messages and the `monitor` service will restart each time the Raspberry Pi boots. As currently configured, you should run `sudo bash monitor.sh` a few times from your command line to get a sense of how the script works. 

</details>

___

</details>

<details><summary><b>Background & Technical Details</b></summary>

# *Highlights*

`monitor` sends a JSON-formatted MQTT message including a confidence value from 0 to 100 to a specified broker when a specified Bluetooth device responds to a `name` query. By default, `name` queries are triggered after receiving an anonymous advertisement from a previously-unseen device (e.g., a device in peripheral mode advertising an ability to connect). 

Example JSON package:
```
topic: monitor/{{name of monitor install}}/{{mac address}}
message: {
    "id":"{{mac address}}",
    "confidence":"{{ranging from 0-100}}",
    "name":"{{if available}}",
    "manufacturer":{{if available}}",
    "type":"KNOWN_MAC",
    "retained":"{{message retained?}}",
    "timestamp":"{{formatted date at which message is sent}}",
    "version":"{{monitor version}}"
 }
```

In addition, optionally, a JSON-formatted MQTT message can be reported to the same broker whenever a publicly-advertising beacon device or an iBeacon device advertises. 

Example JSON package:
```
topic: monitor/{{name of monitor install}}/{{mac address or ibeacon uuid}}
message: {
    "id":"{{mac address or ibeacon uuid}}",
    "report_delay":"{{delay from first detection to this message in seconds}}",
    "flags":"{{GAP flags}}",
    "movement":"stationary",
    "confidence":"{{ranging from 0-100}}",
    "name":"{{if available}}",
    "power":"{{if available}}",
    "rssi":"{{if available}}",
    "mac":"{{if ibeacon, the current mac address associated with the uuid}}",
    "manufacturer":{{if available}}",
    "type":"{{GENERIC_BEACON_PUBLIC or APPLE_IBEACON}},
    "retained":"{{message retained?}}",
    "timestamp":"{{formatted date at which message is sent}}",
    "version":"{{monitor version}}"
 }
 ```
___

# *Oversimplified Analogy of the Bluetooth Presence Problem*

Imagine you're blindfolded in a large room with other people. We want to find out who of your friends **is** present and who of your friends **isn't** present:

![First Picture](https://i.imgur.com/FOubz6T.png)

Some of the people in the room periodically make sounds (e.g., eating a chip, sneeze, cough, etc.), others sit quietly and don’t make a sound unless you specifically ask for them by name, and still others periodically announce their own name out loud at regular intervals whether or not you want them to do that:

![Second Picture](https://i.imgur.com/UwPJIMM.png)

Here's the problem. You can’t just shout “WHO’S HERE” because then everyone would say their name at the same time and you couldn’t tell anything apart. Similarly, for obvious reasons, you can't simply ask "WHO ISN'T HERE?" 

So, you take attendance like in a classroom. Everyone in the room responds **only** when their own name is shouted. 

![Third Picture](https://i.imgur.com/VCW8AmH.png)

So, one way to take attendance is to shout for each friend on a list by name, one at a time, repeatedly. Ask for someone, get a response, wait for a moment, and ask again. 

Once a friend stops responding (for some period of time), you presume that he or she has left: 

![Simple Loop](https://i.imgur.com/ijGw2qb.png)

This technique should work just fine, but there's a minor problem. You're constantly shouting into the room, which means that it's difficult for you to hear quiet responses and it's difficult for other people to carry on conversations. What else can we do? Can we use those random sounds for anything? 

Yes! A smarter approach is to wait for an anonymous sound, *then* start asking whether a friend *you know isn't present* has just arrived:

![Complex Loop](https://i.imgur.com/9Ugn27i.png)

This way, you're not constantly asking the room for all of your friends. Efficient!

This technique is a very simplified description of how `montior` works for devices like cell phones (friends on a list) and beacons (announce a name out loud). This also gives an idea of how `monitor` uses anonymous sounds to reduce the number of times that it has to send inquiries into the Bluetooth environment. 

___

# *Oversimplified Technical Background*

The Bluetooth Low Energy spec was designed to make connecting Bluetooth devices simpler for the user. No more pin codes, no more code verifications, no more “discovery mode” - for the most part. It was also designed to be more private than previous Bluetooth implementations. That said, it’s hard to maintain privacy when you want to be able to connect to an unknown device without intervention. 

## Name Requests

A part of the Blueooth spec is a special function called a `name` request that asks another Bluetooth device to send back a human-readable name of itself. In order to send a `name` request, however, we need to know a private (unchanging) address of the target device. 

Issuing a `name` request to the same private mac address every few seconds is a reliable - albeit rudimentary - way of detecting whether that device is "**present**" (it responds to the `name` request) or "**absent**" (no response to the `name` request is received). However, issuing `name` requests too frequently (*e.g.*, every few seconds) uses quite a bit of 2.4GHz spectrum, which can cause interference with Wi-Fi or other wireless communications.

Not all devices respond to `name` requests, however. For example, beacon devices do not respond. 

## Connectible Devices

Blueooth devices that can exchange information with other devices (almost always) advertise a random/anonymous address that other devices can use to negotiate a secure connection and receive the first device's real, private, Bluetooth address. Using a random address in this way when publicly advertising prevents bad actors from tracking via passive Bluetooth monitoring. 

## Beacon/Advertising Devices

The Bluetooth spec has been used by Apple, Google, and others to create additional standards (e.g., iBeacon, Eddystone, and so on). These devices generally don't care to connect to other devices, so use of random/anonymous addresses doesn't really matter. Instead, these devices encode additional information into each advertisement of an anonymous address. For example, iBeacon devices will broadcast a UUID that conforms to the 8-4-4-4-12 format defined by [IETC RFC4122](http://www.ietf.org/rfc/rfc4122.txt).

As noted above, most beacons do not respond to `name` requests, even if made to the device's private Bluetooth address. So, issuing periodic `name` requests to beacons is not a good way to detect whether a beacon device is **present** or **absent**. However, monitoring for beacon advertisement is a reliable way to detect whether a beacon device is **present** or **absent**.

_____

# *How `monitor` Works*

This script combines `name` requests, anonymous advertisements, and beacon advertisements to logically determine (1) *when* to issue a `name` request to determine whether a device is **present** and (2) *when* to issue a `name` request to determine whether a device is **absent**. The script also listens for beacons. 

##### Known Static Addresses
`monitor` uses unchanging/static mac addresses for your devices that you have added to a file called `known_static_addresses`. These are the addresses for which `monitor` will issue `name` requests to determine whether or not these devices are **present** or **absent**. 

Once a determination of presence is made, the script posts to an mqtt topic path defined in a file called `mqtt_preferences` that includes a JSON-formatted message with a confidence value that corresponds to a confidence of presence. For example, a confidence of 100 means that `monitor` is 100% sure the device is present. Similarly, a confidence of 0 means that `monitor` is 0% sure the device is present (*i.e.*, the `monitor` is 100% sure the device is absent).

To minimize the number of times that `monitor` issues `name` requests (thereby reducing 2.4GHz interference), the script performs either an ***ARRIVAL*** scan or a ***DEPART*** scan, instead of scanning all devices listed in the `known_static_addresses` each time.  

More specifically:

*  An ***ARRIVAL*** scan issues a `name` request, sequentially, for each device listed in the `known_static_addresses` file that is known to be **absent**. 

*  Similarly, a ***DEPART*** scan issues a `name` request, sequentially, for each device listed in the `known_static_addresses` file that is known to be **present**. 

For example, if there are two phone addresses listed in the `known_static_addresses` file, and both of those devices are **present**, an ***ARRIVAL*** scan will never occur. Similarly, if both of these addresses are **absent** then a ***DEPART*** scan will never occur. If only one device is present, an **ARRIVAL** scan will only scan for the device that is currently away. 

To reduce the number of `name` requests that occur, `monitor` listens for anonymous advertisements and triggers an ***ARRIVAL*** scan for every *new* anonymous address. 

The script will also trigger an ***ARRIVE*** scan in response to an mqtt message posted to the topic of `monitor/scan/arrive`. Advertisement-triggered scanning can be disabled by using the trigger argument if `-ta`, which causes `monitor` to *only* trigger ***ARRIVAL*** scans in response to mqtt messages. 

If `monitor` has not heard from a particular anonymous address in a long time, `monitor` triggers a ***DEPART*** scan. The script will also trigger a ***DEPART*** scan in response to an mqtt message posted to the topic of `monitor/scan/depart`. Expiration-triggered scanning can be disabled by using the trigger argument if `-td`, which causes `monitor` to *only* trigger ***DEPART*** scans in response to mqtt messages. 

To reduce scanning even further, `monitor` can filter which types of anonymous advertisements are used for ***ARRIVE*** scans. These are called "filters" and are defined in a file called `behavior_preferences`. The filters are bash RegEx strings that either pass or reject anonymous advertisements that match the filter. 

There are two filter types: 

* **Manufacturer Filter** - filters based on data in an advertisement that is connected to a particular device manufacturer. This is almost always the OEM of the device that is transmitting the anonymous advertisement. By default, because of the prevalence of iPhones, Apple is the only manufacturer that triggers an ***ARRIVAL*** scan. Multiple manufacturers can be appended together by a pipe: `|`. An example filter for Apple and Samsung looks like: `Apple|Samsung`. To disable the manufacturer filter, use `.*`.

* **Flag Filter:** filters based on flags contained in an advertisement. This varies by device type. By default, because of the prevalence of iPhones, the flag of `0x1b` triggers an ***ARRIVAL*** scan. Like with the manufacturer filter, multiple flags can be appended together by a pipe: `|`. To disable the manufacturer filter, use `.*`.

##### Beacons & iBeacons
In addition, when run with the `-b` beacon argument, `monitor` listens for beacon advertisements that report themselves as "public", meaning that their addresses will not change. The script can track these by default; these addresses do not have to be added anywhere - after all, `monitor` will obtain them just by listening. 

Since iBeacons include a UUID and a mac address, two presence messages are reported via mqtt. 

## Known Beacon Addresses
In some cases, manufacturers try to get sneaky and cause their beacons to advertise as "anonymous" (or "random") devices, despite that their addresses do not change at all. By default, `monitor` does not report presence of anonymous advertisement devices, so to force `monitor` to recognize these devices, we add the "random" address to a file called `known_static_beacons`. After restarting, `monitor` will know that these addresses should be treated like a normal beacon. 
___

</details>

<details><summary><b>Home Assistant Example</b></summary>

# Example with Home Assistant

Personally, I have four **raspberry pi zero w**s throughout the house and garage. My family spends most of our time on the first floor, so our main `monitor` node or sensor is on the first floor. Our other 'nodes' on the second and third floor and garage are set up for triggered use only - these will scan for ***ARRIVAL*** and ***DEPART*** only in response to mqtt messages, with option ```-tad```. The first floor node is set up to send mqtt arrive/depart scan instructions to these nodes by including the `-tr` flag ("report" to other nodes when an arrival or depart scan is triggered). 

The first floor constantly monitors for beacons (`-b`) advertisements and anonymous advertisements, which may be sent by our phones listed in the `known_static_addresses` file. In response to a new anonymous advertisement, `monitor` will initiate an ***ARRIVAL*** scan for whichever of our phones is not present.  If one of those devices is seen, an mqtt message is sent to Home Assistant reporting that the scanned phone is "home" with a confidence of 100%. In addition, an mqtt message is sent to the second and third floor and garage to trigger a scan on those floors as well. As a result of this configuration, when we leave the house, we use either the front door or the garage door to trigger an mqtt trigger of ```monitor/scan/depart``` after a ten second delay to trigger a departure scan of our devices that were previously known to be present. The ten second delay gives us a chance to get out of Bluetooth range before a "departure" scan is triggered. Different houses/apartments will probably need different delays. 

More specifically, each of these `monitor` nodes uses the same name for each device so that states can be tracked easily by Home Assistant. For example, on each node, my `known_static_addresses` file looks like this (note that 00:00:00:00:00:00 is an example address - this should be your phone's private, static, Bluetooth address): 

```bash
00:00:00:00:00:00 alias #comment that is ignored
```

The address I want to track is separated by a space from the *alias* that I want to use to refer to this device in Home Assistant. If you prefer to use the address instead of an alias, set the value `PREF_ALIAS_MODE=false` in your `behavior_preferences` file.

In this manner, [Home Assistant](https://www.home-assistant.io) receives mqtt messages and stores the values as input to a number of [mqtt sensors](https://www.home-assistant.io/components/sensor.mqtt/). Output from these sensors is combined to give an accurate numerical occupancy confidence:

```
- platform: mqtt
  state_topic: 'monitor/first floor/alias'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'First Floor'

- platform: mqtt
  state_topic: 'monitor/second floor/alias'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Second Floor'

- platform: mqtt
  state_topic: 'monitor/third floor/alias'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Third Floor'

- platform: mqtt
  state_topic: 'monitor/garage/alias'
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
    - service: input_boolean.turn_on
      data:
        entity_id: input_boolean.occupancy

- alias: Occupancy Off
  hide_entity: true
  trigger:
    - platform: numeric_state
      entity_id: sensor.home_occupancy_confidence
      below: 10
  action:
    - service: input_boolean.turn_off
      data:
        entity_id: input_boolean.occupancy
```

If you prefer to use the `device_tracker` platform in Home Assistant, a unique solution is to use the undocumented `device_tracker.see` service:

As an example:

```
- alias: Andrew Occupancy On
  hide_entity: true
  trigger:
    - platform: numeric_state
      entity_id: sensor.andrew_occupancy_confidence
      above: 10
  action:
    - service: device_tracker.see
      data:
        dev_id: andrew
        location_name: home
        source_type: bluetooth

- alias: Andrew Occupancy Off
  hide_entity: true
  trigger:
    - platform: numeric_state
      entity_id: sensor.andrew_occupancy_confidence
      below: 10
  action:
    - service: device_tracker.see
      data:
        dev_id: andrew
        location_name: not_home
        source_type: bluetooth

```

For more information, see [here](https://community.home-assistant.io/t/device-tracker-from-script/97295/7) and [here](https://github.com/andrewjfreyer/monitor/issues/138).

If you only have one node, an [add-on](https://github.com/Limych/hassio-addons) by @limych may be an excellent choice for you!

</details>

<details><summary><b>Advanced Configuration Options & Fine Tuning</b></summary>


## Fine Tuning


1. Observe output from `monitor` to tune filters:

```bash
sudo bash monitor.sh 
```

Observe the output of the script for debug log [CMD-RAND] lines including [failed filter] or [passed filter]. These lines show what anonymous advertisement `monitor` sees and how `monitor` filters those advertisements. In particular, cycle the Bluetooth power on your phone or another device and look at the `flags` value, the `pdu` value, and the `man` (manufacturer) value that appears after you turn Bluetooth power back on. Remember, the address you see in the log will be an anonymous address - ignore it, we're only focused on the values referenced above. 

```
0.1.xxx 03:25:39 pm [CMD-RAND]  [passed filter] data: 00:11:22:33:44:55 pdu: ADV_NONCONN_IND rssi: -73 dBm flags: 0x1b man: Apple, Inc. delay: 4
```

If you repeatedly see the same values in one or more of these fields, consider adding a PASS filter condition to the `behavior_preferences` file. This will cause `monitor` to *only* scan in response to an anonymous advertisement that passes the filter condition that you define. For example, if you notice that Apple always shows up as the manufacturer when you cycle the power on you phone, you can create an Apple filter:

```bash
PREF_PASS_FILTER_MANUFACTURER_ARRIVE="Apple"
```

If you have two phones, and one is **Apple** and the other is **Google**, create a `bash` or statement in the filter like this: 

```bash
PREF_PASS_FILTER_MANUFACTURER_ARRIVE="Apple|Google"
```

If your phone shows as **Unknown**, then it is best to disable the filter entirely - some phones will report a blank manufacturer, others will report a null value... it's much easier to try and filter with another value:

```bash
PREF_PASS_FILTER_MANUFACTURER_ARRIVE=".*"
```

Similarly, we can create a negative filter. If you or your neighbors use Google Home, it is likely that you'll see at least some devices manufactured by **Google**. Create a fail filter condition to ignore these advertisements: 

```bash
PREF_FAIL_FILTER_MANUFACTURER_ARRIVE="Google"
```

Filters are a great way to minimize the frequency of `name` requestning, which causes 2.4GHz interference and can, if your values are too aggressive, dramatically interfere with Wi-Fi and other services. 

2. **Standard configuration options:**

When `monitor` is first run, default preferences are created in the `behavior_preferences` file. These preferences can be changed, and in many cases should be changed depending on your Bluetooth environment (how many devices you have around you at any given time). A table below describes what these default variables are:  

| **Option** | **Default Value** | **Description** |
|-|-|-|
| PREF_ARRIVAL_SCAN_ATTEMPTS | 1 | This is the number of times that `monitor` will send a name request before deciding that a device has not yet arrived. The higher the number, the fewer errors on arrival detection but also the longer it may take to recognize all devices are home in a multi-device installation. |
| PREF_DEPART_SCAN_ATTEMPTS | 2 | This is the number of times that `monitor` will send a name request before deciding that a device has not yet departed. The higher the number, the fewer errors on departure detection but also the longer it may take to recognize all devices are away in a multi-device installation. |
| PREF_BEACON_EXPIRATION | 180 | This is the number of seconds without observing an advertisement before a beacon is considered expired. |
| PREF_MINIMUM_TIME_BETWEEN_SCANS | 15 | This is the minimum number of seconds required between "arrival" scans or between "departure" scans. Increasing the value will decrease interference, but will also increase arrival and departure detection time. |
| PREF_PASS_FILTER_ADV_FLAGS_ARRIVE | .* | See above. |
| PREF_PASS_FILTER_MANUFACTURER_ARRIVE | .* | See above. |
| PREF_FAIL_FILTER_ADV_FLAGS_ARRIVE | NONE | See above. |
| PREF_FAIL_FILTER_MANUFACTURER_ARRIVE | NONE | See above. |
| PREF_ALIAS_MODE | true | Disable or enable alias mode; if disabled, MQTT messages are sent using a device's mac address. |

3. **Advanced configuration options:**

In addition to the options described above, there are a number of advanced options that can be set by the user. To modify any of these options, add a line to the `behavior_preferences` file. 


| **Option** | **Default Value** | **Description** |
|-|-|-|
PREF_INTERSCAN_DELAY|3|This is a fixed delay between `name` requests. Increasing the value will decrease interference, but will decrease responsiveness. Decreasing the value will risk a Bluetooth hardware fault.|
PREF_RANDOM_DEVICE_EXPIRATION_INTERVAL|75|This is the interval after which an anonymous advertisement mac address is considered expired. Increasing this value will reduce arrival scan frequency, but will also increase memory footprint (minimal) and will decrease the frequency of depart scans.|
PREF_RSSI_CHANGE_THRESHOLD|-20|If a beacon's rssi changes by at least this value, then the beacon will be reported again via mqtt.|
PREF_RSSI_IGNORE_BELOW|-75|If an anonymous advertisement is "farther" away (lower RSSI), ignore the advertisement
PREF_HCI_DEVICE|hci0|Select which hci device should be used by `monitor`|
PREF_COOPERATIVE_SCAN_THRESHOLD|60|Once confidence of a known device falls below this value, send an mqtt message to other `monitor` nodes to begin an arrival scan or a departure scan.|
PREF_MQTT_REPORT_SCAN_MESSAGES|false|This value is either true or false and determines whether `monitor` publishes when a scan begins and when a scan ends|
PREF_PERCENT_CONFIDENCE_REPORT_THRESHOLD|59|This value defines when a beacon begins reporting a decline in confidence|
PREF_PASS_FILTER_PDU_TYPE|*Various. See FAQ.*|These are the PDU types that should be noticed by `monitor`|
PREF_DEVICE_TRACKER_REPORT|false|If true, this value will cause `monitor` to report a 'home' or 'not_home' message to `... /device_tracker` conforming to device_tracker mqtt protocol. 
PREF_DEVICE_TRACKER_HOME_STRING|home|If `PREF_DEVICE_TRACKER_REPORT` is true, this is the string that is reported to the device_tracker when the device is home.
PREF_DEVICE_TRACKER_AWAY_STRING|not_home|If `PREF_DEVICE_TRACKER_REPORT` is true, this is the string that is reported to the device_tracker when the device is not home.
PREF_DEVICE_TRACKER_TOPIC_BRANCH|device_tracker|If `PREF_DEVICE_TRACKER_REPORT` is true, this is last path element of the mqtt topic path that will be used to publish the device tracker message.
PREF_ADVERTISEMENT_OBSERVED_INTERVAL_STEP|15|This is the minimum interval (in seconds) used to estimate advertisement intervals reported in the MQTT message.
PREF_DEPART_SCAN_INTERVAL|30|If using periodic scanning mode, this is the minimum interval (in seconds) at which depart scans are triggered automatically. 
PREF_ARRIVE_SCAN_INTERVAL|15|If using periodic scanning mode, this is the minimum interval (in seconds) at which arrive scans are triggered automatically. 


## RSSI Tracking

This script can also track RSSI changes throughout the day. This can be used for very rudimentary room- or floor-level tracking. Only devices in `known_static_addresses` that have been paired to a `monitor` node can have their RSSI tracked. Here's how to pair: 

1. Stop `monitor` service:

```bash
sudo systemctl stop monitor
```

2. Run `monitor` with `-c` flag, followed by the mac address of the known_device to connect:

```bash
sudo bash monitor.sh -c 00:11:22:33:44:55
```

After this, follow the prompts given by `monitor` and your device will be connected. That's it. After you restart monitor will periodically (once every ~1.5 minutes) connect to your phone and take three RSSI samples, average the samples, and report a string message to the same path as a confidence report, with the additional path component of */rssi*. So, if a `monitor` node is named 'first floor', an rssi message is reported to:

```bash 
topic: monitor/first floor/00:11:22:33:44:55/rssi
message: -99 through 0
```

If an rssi measurement cannot be obtained, the value of -99 is sent. 

## Report known states

It is also possible tell monitor to report all currently known device states by sending an MQTT message to something like `monitor/first floor/KNOWN DEVICE STATES`. monitor.sh will then iterate over all known static addresses and report the current confidence level. This may be useful in home assistant to get the current state after a home assistant restart.

</details>

Anything else? Post a [question.](https://github.com/andrewjfreyer/monitor/issues/new)
