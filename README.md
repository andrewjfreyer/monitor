`monitor`
=======
***TL;DR***: Passive Bluetooth presence detection of beacons, cell phones, and other Bluetooth devices. Useful for [mqtt-based](http://mqtt.org) home automation, especially when the script runs on multiple devices, distrubted throughout a property. 

____

### *Table of Contents*

  * [**Highlights**](#highlights)
  
  * [**Oversimplified Analogy of the Bluetooth Presence Problem**](#oversimplified-analogy-of-the-Bluetooth-presence-problem)

  * [**Oversimplified Technical Description**](#oversimplified-technical-description)

  * [**How `monitor` Works**](#how-monitor-works)

  * [**Example with Home Assistant**](#example-with-home-assistant) 

  * [**Installing on a Raspberry Pi Zero W**](#installation-instructions-for-raspberry-pi-zero-w) 

  * [**FAQs**](#faqs) 
____

# *Highlights*

`monitor` sends a JSON-formatted MQTT message including a confidence value from 0 to 100 to a specified broker when a specified Bluetooth device responds to a `name` query. By default, `name` queries are triggered after receiving an anonymous advertisement from a previously-unseen device. 

Example:
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

Example:

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

Imagine you’re blindfolded in a large room with other people. We want to find out who of our friends is there and who of our friends isn't there:

![First Picture](https://i.imgur.com/FOubz6T.png)

Some of the people in the room periodically make anonymous sounds (e.g., eating a chip, sneeze, cough, etc.), others sit quietly and don’t make a sound unless you specifically ask for them by name, and still others periodically announce their own name out loud at regular intervals whether or not you want them to do that:

![Second Picture](https://i.imgur.com/UwPJIMM.png)

You can’t just shout “WHO’S HERE” because then everyone would say their name at the same time and you couldn’t tell anything apart. Obviously, we also can ask "WHO ISN'T HERE." So, everyone has agreed to respond only when their own name is shouted, like taking attendance in a large classroom. 

Also, you have to shout these names loudly because, quite frankly, we don't want our friends to not hear their name being called, and also becaonse don't know how big the room is - asking quietly simply won't do:

![Third Picture](https://i.imgur.com/VCW8AmH.png)

Ok, now how can you figure out if your friends are in the room? If your friends say their name out loud it’s easy to know if they’re present or absent - all you have to do is listen for them. 

For most of your friends though, you need to shout name by name one at a time. This is because the other sounds you hear are totally anonymous ... you have no idea who made what sound.

One way to check to see whether your friends are in the room is to shout for each friend by name, one at a time, repeatedly. 

Shout, get a response, wait for a moment, and ask again. 

Once a friend stops responding for some period of time, you presume that he or she has left: 

![Simple Loop](https://i.imgur.com/ijGw2qb.png)

This technique should work just fine, but there's a problem. You're constantly shouting into the room, which means that it's difficult for you to hear quiet responses and it's difficult for other people to carry on conversations. A smarter approach is to wait for an anonymous sound, *then* start asking whether your friend is there:

![Complex Loop](https://i.imgur.com/9Ugn27i.png)

This technique is a very simplified description of how `montior` works for devices like cell phones (friends) and beacons (strangers who announce their name out loud). This also gives an idea of how `monitor` uses anonymous sounds to reduce the number of times that it has to send inquiries into the Bluetooth environment. 


___

# *Oversimplified Technical Description*

The Bluetooth Low Energy 4.0 spec was designed to make connecting Bluetooth devices simpler for the user. No more pin codes, no more code verifications, no more “discovery mode” - for the most part. It was also designed to be much more private than previous Bluetooth specs. But it’s hard to maintain privacy when you want to be able to connect to an unknown device without user intervention, so a compromise was made. The following is oversimplified and not technically accurate in most cases, but should give the reader a gist of how `monitor` determines presence. 

## Name Requests

A part of the Blueooth spec is a special function called a `name` request that asks another Bluetooth device to send back a human-readable name of itself. In order to send a `name` request, we need to know a private (unchanging) address of the target device. 

Issuing a `name` request to the same private mac address every few seconds is a reliable - albeit rudamentary - way of detecting whether that device is "**present**" (it responds to the `name` request) or "**absent**" (no response to the `name` request is received). However, issuing `name` requests too frequently (*e.g.*, every few seconds) uses quite a bit of 2.4GHz spectrum, which can cause substantial interference with Wi-Fi or other wireless communications.

## Connectable Devices

Blueooth devices that can exchange information with other devices (almost always) advertise a random/anonymous address that other devices can use to negotate a secure connection with that device's real, private, Bluetooth address. 

Using a random address when publicly advertising prevents baddies from tracking people via Bluetooth `monitor`ing. `monitor`ing for anonymous advertisement is not a reliable way to detect whether a device is **present** or **absent**. However, nearly all connectable devices respond to `name` requests if made to the device's private Bluetooth address.

## Beacon Devices

The Bluetooth spec has been used by Apple, Google, and others to create additional standards (e.g., iBeacon, Eddystone, and so on). These devices generally don't care to conenct to other devices, so their random/anonymous addresses don't really matter. Instead, these devices encode additional information into each advertisement of an anonymous address. For example, iBeacon devices will broadcast a UUID that conforms to the 8-4-4-4-12 format defined by [IETC RFC4122](http://www.ietf.org/rfc/rfc4122.txt).

Beacons do not respond to `name` requests, even if made to the device's private Bluetooth address. So, issuing periodic `name` requests to beacons is not a reliable way to detect whether a beacon device is **present** or **absent**. However, `monitor`ing for beacon advertisement is a reliable way to detect whether a beacon device is **present** or **absent**.

_____

# *How `monitor` Works*

This script combines `name` requests, anonymous advertisements, and beacon advertisements to logically determine (1) *when* to issue a `name` scan to determine whether a device is **present** and (2) *when* to issue a `name` scan to determine whether a device is **absent**. The script also listens for beacons. 

##### Known Static Addresses
More specifically, `monitor` accesses private mac addresses that you have added to a file called `known_static_addresses`. These are the addresses for which `monitor` will issue `name` requests to determine whether or not these devices are **present** or **absent**. 

Once a determination of presence is made, the script posts to an mqtt topic path defined in a file called `mqtt_preferences` that includes a JSON-formatted message with a confidence value that corresponds to a confidence of presence. For example, a confidence of 100 means that `monitor` is 100% sure the device is present and present. Similarly, a confidence of 0 means that `monitor` is 0% sure the device is present (*i.e.*, the `monitor` is 100% sure the device is absent).

To minimize the number of times that `monitor` issues `name` requests (thereby reducing 2.4GHz interference), the script performs either an ***ARRIVAL*** scan or a ***DEPART*** scan, instead of scanning all devices listed in the `known_static_addresses` each time.  More specifically:

*  An ***ARRIVAL*** scan issues a `name` request *only* for devices from the `known_static_addresses` file that are known to be **absent**. 

*  Similarly, a ***DEPART*** scan issues a `name` request *only* for devices from the `known_static_addresses` file that are known to be **present**. 

For example, if there are two phone addresses listed in the `known_static_addresses` file, and both of those devices are **present**, an ***ARRIVAL*** scan will never occur. Similarly, if both of these addresses are **absent** then a ***DEPART*** scan will never occur. If only one device is present, an **ARRIVAL** scan will only scan for the device that is currently away. 

To reduce the number of `name` scans that occur, `monitor` listens for anonymous advertisements and triggers an ***ARRIVAL*** scan for every *new* anonymous address. 

The script will also trigger an ***ARRIVE*** scan in response to an mqtt message posted to the topic of ``monitor`/scan/arrive`. Advertisement-triggered scanning can be disabled by using the trigger argument if `-ta`, which causes `monitor` to *only* trigger ***ARRIVAL*** scans in response to mqtt messages. 

If `monitor` has not heard from a particular anonymous address in a long time, `monitor` triggers a ***DEPART*** scan. The script will also trigger a ***DEPART*** scan in response to an mqtt message posted to the topic of ``monitor`/scan/depart`. Expiration-triggered scanning can be disabled by using the trigger argument if `-td`, which causes `monitor` to *only* trigger ***DEPART*** scans in response to mqtt messages. 

To reduce scanning even further, `monitor` can filter which types of anonymous advertisements are used for ***ARRIVE*** scans. These are called "filters" and are defined in a file called `behavior_preferences`. The filters are bash RegEx strings that either pass or reject anonymous advertisements that match the filter. There are two filter types: 

* **Manufacturer Filter** - filters based on data in an advertisement that is connected to a particular device manufacturer. This is almost always the OEM of the device that is transmitting the anonymous advertisment. By default, because of the prevalence of iPhones, Apple is the only manufacturer that triggers an ***ARRIVAL*** scan. Multiple manufacturers can be appended together by a pipe: `|`. An example filter for Apple and Samsung looks like: `Apple|Samsung`. To diable the manufacturer filter, use `.*`.

* **Flag Filter:** filters based on flags contained in an advertisement. This varies by device type. By default, because of the prevalence of iPhones, the flag of `0x1b` triggers an ***ARRIVAL*** scan. Like with the manufacturer filter, multiple flags can be appended together by a pipe: `|`. To diable the manufacturer filter, use `.*`.

##### Beacons & iBeacons
In addition, once installed and run with the `-b` beacon argument, `monitor` listens for beacon advertisements that report themselves as "public", meaning that their addresses will not change. The script can track these by default; these addresses do not have to be added anywhere - after all, `monitor` will obtain them just by listening. 

Since iBeacons include a UUID and a mac address, two presence messages are reported via mqtt. 

## Known Beacon Addresses
In some cases, certain manufacturers try to get sneaky and cause their beacons to advertise as "anonymous" (or "random") devices, despite that their addresses do not change at all. By default, `monitor` ignores anonymous devices, so to force `monitor` to recognize these devices, we add the "random" address to a file called `known_static_beacons`. After restarting, `monitor` will know that these addresses should be treated like a normal beacon. 
___

# Example with Home Assistant

Personally, I have four **raspberry pi zero w**s throughout the house and garage. My family spends most of our time on the first floor, so our main `monitor` node or sensor is on the first floor. Our other 'nodes' on the second and third floor and garage are set up for triggered use only - these will scan for ***ARRIVAL*** and ***DEPART*** only in response to mqtt messages, with option ```-tad```. The first floor node is set up to send mqtt arrive/depart scan instructions to these nodes by including the `-tr` flag ("report" to other nodes when an arrival or depart scan is triggered). 

The first floor constantly `monitor`s for beacons (`-b`) advertisements and anonymous advertisements, which may be sent by our phones listed in the `known_static_addresses` file. In response to a new anonymous advertisement, `monitor` will initate an ***ARRIVAL*** scan for whichever of our phones is not present.  If one of those devices is seen, an mqtt message is sent to Home Assistant reporting that the scanned phone is "home" with a confidence of 100%. In addition, an mqtt message is sent to the second and third floor and garage to trigger a scan on those floors as well. 

When we leave the house, we use either the front door or the garage door to trigger an mqtt trigger of ````monitor`/scan/depart``` after a ten second delay to trigger a departure scan of our devices that were previously known to be present. The ten second delay gives us a chance to get out of Bluetooth range before a "departure" scan is triggered. Different houses/apartments will probably need different delays. 

[Home Assistant](https://www.home-assistant.io) receives mqtt messages and stores the values as input to a number of [mqtt sensors](https://www.home-assistant.io/components/sensor.mqtt/). Output from these sensors is combined to give an accurate numerical occupancy confidence.  

For example (note that 00:00:00:00:00:00 is an example address - this should be your phone's private, static, Bluetooth address):

```
- platform: mqtt
  state_topic: '`monitor`/first floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'First Floor'

- platform: mqtt
  state_topic: '`monitor`/second floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Second Floor'

- platform: mqtt
  state_topic: '`monitor`/third floor/00:00:00:00:00:00'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Third Floor'

- platform: mqtt
  state_topic: '`monitor`/garage/00:00:00:00:00:00'
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

# Installation Instructions for Raspberry Pi Zero W

## Setup of SD Card

1. Download latest version of **rasbpian** [here](https://downloads.raspberrypi.org/raspbian_lite_latest)

2. Download etcher from [etcher.io](https://etcher.io)

3. Image **raspbian lite stretch** to SD card. [Instructions here.](https://www.raspberrypi.org/magpi/pi-sd-etcher/)

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
sudo apt-get install rpi-update
sudo rpi-update
sudo reboot
```

5. Install Bluetooth Firmware, if necessary:
```bash
#install Bluetooth drivers for Pi Zero W
sudo apt-get install pi-Bluetooth

```

6. Reboot:
```bash
sudo reboot
```

7. Install Mosquitto:
```bash

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

8. Clone `monitor` git:
```bash
#install git
cd ~
sudo apt-get install git

#clone this repo
git clone git://github.com/andrewjfreyer/monitor

#enter `monitor` directory
cd monitor/

#switch to beta branch for latest updates and features (may be instable)
git checkout beta       

```

9. Initial run:

Configuration files will be created with default preferences. Any executables that are not installed will be reported. All can be installed via `apt-get intall ...`

```bash 
sudo bash monitor.sh
```


10. Edit **mqtt_preferences** file:

```bash
sudo nano mqtt_preferences
```

11. Edit **known_static_addresses** (phones, laptops, some smartwatches): 

```bash
sudo nano known_static_addresses
```

12. Read helpfile:

```bash
sudo bash monitor.sh -h
```

Now the basic setup is complete. Your broker should be receiving messages and the `monitor` service will restart each time the Raspberry Pi boots. As currently configured, you should run `sudo bash monitor.sh` a few times from your command line to get a sense of how the script works. 


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

Filters are a great way to minimize the frequency of `name` scanning, which causes 2.4GHz interference and can, if your values are too agressive, dramatically interfere with Wi-Fi and other services. 

2. **Standard configuration options:**

When `monitor` is first run, default preferences are created in the `behavior_preferences` file. These preferences can be changed, and in many cases should be changed depending on your Bluetooth environment (how many devices you have around you at any given time). A table below describes what these default variables are:  

| **Option** | **Default Value** | **Description** |
|-|-|-|
| PREF_ARRIVAL_SCAN_ATTEMPTS | 1 | This is the number of times that `monitor` will send a name request before deciding that a device has not yet arrived. The higher the number, the fewer errors on arrival detection but also the longer it may take to recognize all devices are home in a multi-device installation. |
| PREF_DEPART_SCAN_ATTEMPTS | 2 | This is the number of timesthat `monitor` will send a name request before deciding that a device has not yet departed. The higher the number, the fewer errors on departure detection but also the longer it may take to recognize all devices are awy in a multi-device installation. |
| PREF_BEACON_EXPIRATION | 180 | This is the number of seconds without observing an advertisement before a beacon is considered expired. |
| PREF_MINIMUM_TIME_BETWEEN_SCANS | 15 | This is the minimum number of seconds required between "arrival" scans or between "departure" scans. Increasing the value will decrease interference, but will also increase arrival and departure detection time. |
| PREF_PASS_FILTER_ADV_FLAGS_ARRIVE | .* | See above. |
| PREF_PASS_FILTER_MANUFACTURER_ARRIVE | .* | See above. |
| PREF_FAIL_FILTER_ADV_FLAGS_ARRIVE | NONE | See above. |
| PREF_FAIL_FILTER_MANUFACTURER_ARRIVE | NONE | See above. |

3. **Advanced configuration options:**

In addition to the options described above, there are a number of advanced options that can be set by the user. To modify any of these options, add a line to the `behavior_preferences` file. 


| **Option** | **Default Value** | **Description** |
|-|-|-|
PREF_INTERSCAN_DELAY|3|This is a fixed delay between `name` scans. Increasing the value will decrease inteference, but will decrease responsiveness. Decreasing the value will risk a Bluetooth hardware fault.|
PREF_RANDOM_DEVICE_EXPIRATION_INTERVAL|75|This is the interval after which an anonymous advertisement mac address is considered expired. Increasing this value will reduce arrival scan frequency, but will also increase memory footprint (minimal) and will decrease the frequency of depart scans.|
PREF_RSSI_CHANGE_THRESHOLD|-20|If a beacon's rssi changes by at least this value, then the beacon will be reported again via mqtt.|
PREF_RSSI_IGNORE_BELOW|-75|If an anonymous advertisement is "farther" away (lower RSSI), ignore the advertisement|
PREF_HCI_DEVICE|hci0|Select which hci device should be used by `monitor`|
PREF_COOPERATIVE_SCAN_THRESHOLD|60|Once confidence of a known device falls below this value, send an mqtt message to other `monitor` nodes to begin an arrival scan or a departure scan.|
PREF_MQTT_REPORT_SCAN_MESSAGES|false|This value is either true or false and determines whether `monitor` publishes when a scan begins and when a scan ends|
PREF_PERCENT_CONFIDENCE_REPORT_THRESHOLD|59|This value defines when a beacon begins reporting a decline in confidence|
PREF_PASS_FILTER_PDU_TYPE|ADV_IND|ADV_SCAN_IND|ADV_NONCONN_IND|SCAN_RSP|These are the PDU types that should be noticed by `monitor`|
PREF_MQTT_TOPIC_ALIAS|false|This value is either true or false and determines whether `monitor` publishes an alias (true) or a mac address (false)

## RSSI Tracking

This script can also track RSSI changes throughout the day. This can be useful for very rudamentary room-level tracking. Only devices in `known_static_addresses` that have been paired to a `monitor` node can have their RSSI tracked. Here's how to pair: 

1. Stop `monitor` service:

```bash
sudo systemctl stop `monitor`
```

2. Run `monitor` with `-c` flag, followed by the mac address of the known_device to connect:

```bash
sudo bash monitor.sh -c 00:11:22:33:44:55
```

After this, follow the prompts given by `monitor` and your device will be connected. That's it. After you restart `monitor` will periodicly (once every ~1.5 minutes) connect to your phone and take three RSSI samples, average the samples, and report a string message to the same path as a confidence report, with the additional path component of */rssi*. So, if a `monitor` node is named 'first floor', an rssi message is reported to:

```bash 
topic: `monitor`/first floor/00:11:22:33:44:55/rssi
message: -99 through 0
```

If an rssi measurement cannot be obtained, the value of -99 is sent. 

3. Using the rssi data for something:

I strongly recommend using a filter to smooth the rssi data. An example for Home Assistant follows:


```yaml
sensor:

  - platform: mqtt
    state_topic: 'location/first floor/34:08:BC:15:24:F7/rssi'
    name: 'Andrew First Floor RSSI raw'
    unit_of_measurement: 'dBm'

  - platform: filter
    name: "Andrew First Floor RSSI"
    entity_id: sensor.andrew_first_floor_rssi_raw
    filters:
      - filter: outlier
        window_size: 2
        radius: 1.0
      - filter: lowpass
        time_constant: 2
      - filter: time_simple_moving_average
        window_size: 00:01
        precision: 1
```

___

# *FAQs*

### I'm running 5GHz Wi-Fi, I don't use Bluetooth for anything else, and I don't care whether I interfere with my neighbor's devices. Can't I just issue a name scan every few seconds to get faster arrival and depart detection? 

Not anymore. Periodic scanning has been removed from `monitor`. If you would like to scan every few seconds anyway, despite that you may be causing interference for others, you can use the `presence` project in my repository available [here](https://github.com/andrewjfreyer/presence). This feature will not be added back into `monitor` in the foreseeable future. 

### I keep seeing that my Bluetooth hardware is "cycling" in the logs - what does that mean? 

If more than one program or executable try to use the Bluetooth hardware at the same time, your Bluetooth hardware will report an error. To correct this error, the hardware needs to be taken offline, then brought back. 

### Can I use other Bluetooth services while `monitor` is running? 

No. Monitor needs exclusive use of the Bluetooth radio to function properly. This is why it is designed to run on inexpensive hardware like the Raspberry Pi Zero W. 

### Can `monitor` run on XYZ hardware or in XYZ container? 

Probably. The script has been designed to minimize dependencies as much as possible. That said, I can't guarantee or provide support to all systems. 

### Does this work to track my iPhone?

Yes. `monitor` was specifically designed to work with iPhones, but also works with most of all Android phones as well. 
____

### Will this be able to track my Apple Watch/Smart Watch?

Yes, with a caveat. Many users, including myself, have successfully added Apple Watch Bluetooth addresses to the `known_static_addresses` file. In my personal experience, an Apple Watch works just fine. 

Other users have reported that the Apple Watch will occasionally not respond to `monitor`. Your mileage using the Apple Watch and/or other low-power connectable Bluetooth devices may vary. 

I strongly recommend tracking phones. 

____

### What special app do I need on my phone to get this to work? 

None, except in very rare circumstances. The only requirement is that Bluetooth is left on. 

____

### Does `monitor` reduce battery life for my phone? 

Not noticable in my several years of using techniques similar to this. 


____
### Does `monitor` interfere with Wi-Fi, Zigbee, or Zwave? 

It can, if it scans too frequently. Try to use all techniques for reducing `name` scans, including using trigger-only depart mode `-tdr`. When in this mode, `monitor` will never scan when all devices are home. Instead, `monitor` will wait until a ``monitor`/scan/depart` message is sent. 

Personally, I use my front door lock as a depart scan trigger.


____
### How can I trigger an arrival scan? 

Post a message with blank content to ``monitor`/scan/arrive`


____
### How can I trigger an depart scan? 

Post a message with blank content to ``monitor`/scan/depart`


____
### How can I trigger an arrive/depart scan from an automation in Home Assistant?

For an automation or script (or other service trigger), use: 

```yaml
  service: 'mqtt.publish'
  data: 
    topic: location/scan/arrive
```

```yaml
  service: 'mqtt.publish'
  data: 
    topic: location/scan/depart
```

____
### How can I upgrade to the latest version without using ssh? 

Post a message with blank content to ``monitor`/scan/update` or ``monitor`/scan/updatebeta` 



____
### How can I restart a `monitor` node? 

Via command line: 

```bash
sudo systemctl restart `monitor`
```

Or, post a message with blank content to ``monitor`/scan/restart`



____
### Why don't I see RSSI for my iPhone/Andriod/whatever phone? 

See the RSSI section above. You'll have to connect your phone to `monitor` first.  


____
### How do I force an RSSI update for a known device, like my phone? 

Post a message with blank content to ``monitor`/scan/rssi`


____
### I can't do **XYZ**, is `monitor` broken? 

Run via command line and post log output to github. Else, access `journalctl` to show the most recent logs: 

```bash
journalctl -u `monitor` -r
```

____
### My phone doesn't seem to automatically broadcast an anonymous Bluetooth advertisement... what can I do? 

Many phones will only broadcast once they have already connected to *at least one* other Bluetooth device. Connect to a speaker, a car, a headset, or `monitor` and try again. 

____
### I have connected to Bluetooth devices but my phone doesn't seem to automatically broadcast an anonymous Bluetooth advertisement... what can I do? 

Some android phones just don't seem to advertise... and that's a bummer. There are a number of beacon apps that can be used from the Play Store.

____
### My Android phone doesn't seem to send any anonymous advertisements, no matter what I do. Is there any solution?  

Some phones, like the LG ThinQ G7 include an option in settings to enable file sharing via bluetooth. As resported by Home Assistant forum user @jusdwy, access this option via Settings >Connected Devices > File Sharing > File Sharing ON.

For other android phones, an app like [Beacon Simulator](https://play.google.com/store/apps/details?id=net.alea.beaconsimulator&hl=en_US) may be a good option. You may also be able to see more information about bluetooth on your phone using [nRF Connect](https://play.google.com/store/apps/details?id=no.nordicsemi.android.mcp&hl=en_US).

____
### It's annoying to have to keep track of mac addresses. Can't I just use an alias for the mac addresses for MQTT topics? 

Yes! Create a file called `mqtt_aliases` in the configuration directory, and then add a line for each mac address of a known device that you'd like to create a alias. Comments starting with a pound/hash sign will be ignored. 

So, if you have a known device with the mac address of 00:11:22:33:44:55 that you would like to call "Andrew's Phone", add one line to the `mqtt_aliases`:

```bash
00:11:22:33:44:55 Andrew's iPhone
```

You also have to add PREF_MQTT_TOPIC_ALIAS=true to the `behavior_preferences` file. 

Then restart the `monitor` service. The script will now use "andrew_s_iphone" as the final mqtt topic path component. Important: 

* any entry will be made **lowercase**

* any non-digit or non-decimal character will be replaced with an underscore

The same is true for beacons as well. 

That's it!


Anything else? Post a [question.](https://github.com/andrewjfreyer/`monitor`/issues)
