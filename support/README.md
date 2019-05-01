# *Frequenty Asked Questions:*
[***Basics***](#monitor-basics)

[***Wi-Fi Interference & Performance***](#wi-fi-interference--performance-issues)

[***Debugging***](#monitor-logs--debugging)

[***Filters***](#filters)

[***Miscellaneous***](#other-questions)

____

## *Monitor Basics*

#### Will this be able to track my Apple Watch/Smart Watch?

Yes, with a caveat. Many users, including myself, have successfully added Apple Watch Bluetooth addresses to the `known_static_addresses` file. In my personal experience, an Apple Watch works just fine [once it has connected to at least one other Bluetooth device, apart from your iPhone](https://github.com/andrewjfreyer/monitor#my-phone-doesnt-seem-to-automatically-broadcast-an-anonymous-bluetooth-advertisement-what-can-i-do). Other users have reported that the Apple Watch will occasionally not respond to `monitor`. Your mileage using the Apple Watch and/or other low-power connectible Bluetooth devices may vary. I strongly recommend tracking phones. 

#### What special app do I need on my phone to get this to work? 

None, except in rare circumstances. The only requirement is that Bluetooth is left on. Works best with iPhones and Android phones that have peripheral mode enabled. 

#### Does `monitor` reduce battery life for my phone? 

Not noticeable in my several years of using techniques similar to this. 

#### How can I trigger an arrival scan? 

Post a message with blank content to `monitor/scan/arrive`

#### How can I trigger an depart scan? 

Post a message with blank content to `monitor/scan/depart`

#### How can I trigger an arrive/depart scan from an automation in Home Assistant?

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

#### How can I add a known device without manually entering an address? 

Post a message with the mac address separated from an alias (optional) by a space to: `monitor/setup/add known device`

#### How can I delete a known device without manually editing an address? 

Post a message with the mac address to: `monitor/setup/delete known device`

#### How can I upgrade to the latest version without using ssh? 

Post a message with blank content to `monitor/scan/update` or `monitor/scan/updatebeta` 

#### How can I restart a `monitor` node? 

Via command line: 

```bash
sudo systemctl restart monitor
```

Or, post a message with blank content to `monitor/scan/restart`

#### Why don't I see RSSI for my iPhone/Andriod/whatever phone? 

See the RSSI section of this FAQ. You'll have to connect your phone to `monitor` first.  

#### How do I force an RSSI update for a known device, like my phone? 

Post a message with blank content to `monitor/scan/rssi`

____

## *Wi-Fi Interference & Performance Issues*

#### I'm running 5GHz Wi-Fi, I don't use Bluetooth for anything else, and I don't care whether I interfere with my neighbor's devices. Can't I just issue a name scan every few seconds to get faster arrival and depart detection?

Yes, use periodic scanning mode with `-r`.

#### Can I use other Bluetooth services while `monitor` is running?

No. Monitor needs exclusive use of the Bluetooth radio to function properly. This is why it is designed to run on inexpensive hardware like the Raspberry Pi Zero W. 

#### Can `monitor` run on XYZ hardware or in XYZ container?

Probably. The script has been designed to minimize dependencies as much as possible. That said, I can't guarantee or provide support to all systems. 

#### Does `monitor` interfere with Wi-Fi, Zigbee, or Zwave? 

It can, if it scans too frequently, especially if you're running `monitor` from internal Raspberry Pi radios. Try to use all techniques for reducing `name` scans, including using trigger-only depart mode `-tdr`. When in this mode, `monitor` will never scan when all devices are home. Instead, `monitor` will wait until a `monitor/scan/depart` message is sent. Personally, I use my front door lock as a depart scan trigger.

#### How can I check if a `monitor` node is up and hasn't shut down for some reason?  

Post a message to `monitor/scan/echo`, and you'll receive a response at the topic `$mqtt_topicpath/$mqtt_publisher_identity/echo`

#### I *still* have interference and/or my ssh sessions to the raspberry pi are really slow and laggy. What gives? 

Cheap Wi-Fi chipsets and cheap Bluetooth chipsets can perform poorly together if operated at the same time, especially on Raspberry Pi devices. If you still experience interference in your network, switching to a Wi-Fi dongle can help. 

#### I use a Bluetooth dongle, and `monitor` seems to become non-responsive after a while - what's going on? 

Many Bluetooth dongles do not properly filter out duplicate advertisements, so `monitor` gets overwhelmed trying to filter out hundreds of reports, when it expects dozens. I'm working on a solution, but for now the best option is to switch to internal Bluetooth or, alternatively, you can try another Bluetooth dongle. 
___

## *Monitor Logs & Debugging*

#### I keep seeing that my Bluetooth hardware is "cycling" in the logs - what does that mean?

If more than one program or executable try to use the Bluetooth hardware at the same time, your Bluetooth hardware will report an error. To correct this error, the hardware needs to be taken offline, then brought back. 

#### I can't do **XYZ**, is `monitor` broken? 

Run via command line and post log output to github. Else, access `journalctl` to show the most recent logs: 

```bash
journalctl -u monitor -r
```

#### My Android phone doesn't seem to send any anonymous advertisements, no matter what I do. Is there any solution?  

Some phones, like the LG ThinQ G7 include an option in settings to enable file sharing via bluetooth. As resported by Home Assistant forum user @jusdwy, access this option via Settings >Connected Devices > File Sharing > File Sharing ON. For other android phones, an app like [Beacon Simulator](https://play.google.com/store/apps/details?id=net.alea.beaconsimulator&hl=en_US) may be a good option. You may also be able to see more information about Bluetooth on your phone using [nRF Connect](https://play.google.com/store/apps/details?id=no.nordicsemi.android.mcp&hl=en_US). 

Unfortunately, until Android OS includes at least one service that requires bluetooth peripheral mode to be enabled, Android devices will probably not advertise without an application running in the background. In short, as I understand it, Android/Google has been  slow to adopt BTLE peripheral mode as an option in addition to the default central mode. [Here is a decently comprehensive list of phones that support peripheral mode](https://altbeacon.github.io/android-beacon-library/beacon-transmitter-devices.html), should an application choose to leverage the appropriate API. It does not appear as though the native OS has an option (outside of the file sharing option mentioned above on LG phones) to enable this mode. 

Unfortunately, it seems to me that absent an application causing an advertisement to send, Android users will not be able to use monitor in the same way as iOS users or beacon users. 

#### My phone doesn't seem to automatically broadcast an anonymous Bluetooth advertisement ... what can I do? 

Many phones will only broadcast once they have already connected to *at least one* other Bluetooth device. Connect to a speaker, a car, a headset, or `monitor.sh -c [address]` and try again. 

#### I have connected my phone to Bluetooth devices before but my phone doesn't seem to automatically broadcast an anonymous Bluetooth advertisement ... what can I do? 

See above. 

#### Why does my MQTT broker show connection and disconnection so often? 

This is normal behavior for `mosquitto_pub` - nothing to worry about. 

#### I updated and `monitor` is no longer working ... what gives? 

Make sure you've updated `mosquitto` to v1.5 or higher. In order to support a wider userbase, backward compatibility for old versions of `mosquitto` was dropped. It is alos strongly recommended that you upgrade to bash 4.4+.

#### I keep seeing MQTT Broker Offline messages in the `monitor` log. What's going on? 

mosquitto fails to connect to a broker if your password has certain special characters such as: `@`, `:`,`/` - if this is the case, the easiest solution is to create a new user for `monitor` with a different password. 

#### Can I use a certfile for mosquitto instead of my password? 

Yes, specify a path for `mqtt_certificate_path` in mqtt_preferences.

____

## *Filters*

#### What filters do you personally use? 

```bash 

#ARRIVE TRIGGER FILTER(S)
PREF_PASS_FILTER_ADV_FLAGS_ARRIVE=\"0x1a|0x1b\"
PREF_PASS_FILTER_MANUFACTURER_ARRIVE=\"Apple\"

#ARRIVE TRIGGER NEGATIVE FILTER(S)
PREF_FAIL_FILTER_MANUFACTURER_ARRIVE=\"Google|Samsung\"
PREF_FAIL_FILTER_MANUFACTURER_ARRIVE=\"NONE\"
```

#### What are the default filters for the PDU filter option? 

```ADV_IND|ADV_SCAN_IND|ADV_NONCONN_IND|SCAN_RSP```

#### How do I use this as a device_tracker, in addition to the standard confidence messages? 

Set the option `PREF_DEVICE_TRACKER_REPORT` in your `behavior_preferences` file to true. If it's not there, add a line like this: 

```bash
PREF_DEVICE_TRACKER_REPORT=true
```

Then, an additional mqtt message will be posted to the topic branch ending in  `/device_tracker`

So, as an example for a `monitor` node named "first floor", a device tracker configuration for Home Assistant can look like: 

```yaml

device_tracker:
  - platform: mqtt
    devices:
      andrew_first_floor: 'monitor/first floor/[device address or alias]/device_tracker'
```

The standard confidence report will also send. 

#### How do I determine what values to set for filters?  

Try using the verbose logging option `-V` to see what `monitor` sees when a new bluetooth device advertisement is seen. Then, power cycle the bluetooth radio on the device you'd like to track - you'll probably see a pattern develop with flags or manufacturers. Use these values to create your arrival filters!

Similarly, to set exclude filters, you can observe bluetooth traffic for a period of time to see what devices you simply do not care about seeing. 

____

## *Other Questions*

#### It's annoying to have to keep track of mac addresses. Can't I just use a nickname for the mac addresses for MQTT topics? 

Yes, this is now default behavior. All you have to do is provide a name next to the address in the `known_static_addresses` file. For example, if you have a known device with the mac address of 00:11:22:33:44:55 that you would like to call "Andrew's Phone":

```bash
00:11:22:33:44:55 Andrew's iPhone
```

Then restart the `monitor` service. The script will now use "andrew_s_iphone" as the final mqtt topic path component. 

***Important:***

* any entry will be made **lowercase**

* any non-digit or non-decimal character will be replaced with an underscore

The same is true for beacons in the `known_beacon_addresses` file as well:

```bash 
09876543-3333-2222-1111-000000000000-9-10000 Dog
```

To disable this feature, set `PREF_ALIAS_MODE=false` in your `behavior_preferences` file. 

#### I don't care about a few devices that are reporting. Can I block them? 

Yes. Create a file called `address_blacklist` in your configuration directory and add the mac addresses you'd like to block (or uuid-major-minor for iBeacons) one at a time. 

#### I can't use the `device_tracker` platform with the default status strings of `home` and `not_home` with my home automation software. What can I do? 

Set these options in `behavior_preferences`: 

```bash
PREF_DEVICE_TRACKER_HOME_STRING='home status string' 
PREF_DEVICE_TRACKER_AWAY_STRING='away status string'
PREF_DEVICE_TRACKER_TOPIC_BRANCH='topic path for device tracker/presence tracker'
```

Examples:

Home Assistant (default): 

```bash
PREF_DEVICE_TRACKER_HOME_STRING='home' 
PREF_DEVICE_TRACKER_AWAY_STRING='not_home'
PREF_DEVICE_TRACKER_TOPIC_BRANCH='device_tracker'
```

SmartThings: 

```bash
PREF_DEVICE_TRACKER_HOME_STRING='present' 
PREF_DEVICE_TRACKER_AWAY_STRING='not present'
PREF_DEVICE_TRACKER_TOPIC_BRANCH='presence'
```

Generic: 

```bash
PREF_DEVICE_TRACKER_HOME_STRING='home' 
PREF_DEVICE_TRACKER_AWAY_STRING='away'
PREF_DEVICE_TRACKER_TOPIC_BRANCH='anything you like'
```