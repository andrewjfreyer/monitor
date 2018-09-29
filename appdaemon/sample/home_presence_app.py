import appdaemon.plugins.mqtt.mqttapi as mqtt
import json
import shelve
import os, sys
dirname, filename = os.path.split(os.path.abspath(sys.argv[0]))

class HomePresenceApp(mqtt.Mqtt):
    def initialize(self):
        self.set_namespace('mqtt')
        self.hass_namespace = self.args.get('hass_namespace', 'default')
        self.presence_topic = self.args.get('presence_topic', 'presence')
        self.db_file = os.path.join(os.path.dirname(__file__),'home_presence_database')
        self.listen_event(self.presence_message, 'MQTT')
        self.not_home_timers = dict()
        self.timeout = self.args.get('not_home_timeout', 120) #time interval before declaring not home
        self.minimum_conf = self.args.get('minimum_confidence', 90)
        self.depart_check_time = self.args.get('depart_check_time', 30)
        self.home_state_entities = dict() #used to store or map different confidence sensors based on location to devices 
        self.all_users_sensors = self.args['users_sensors'] #used to determine if anyone at home or not
        known_beacons = self.args.get('known_beacons', {})
        self.known_beacons = {}

        if known_beacons != {}:
            for k, v in known_beacons.items():
                self.known_beacons[k.replace('_', ':')] = v

        self.report_only_known_beacons = self.args.get('report_only_known_beacons', True)

        self.monitor_entity = '{}.monitor_state'.format(self.presence_topic) #used to check if the network monitor is busy 
        if not self.entity_exists(self.monitor_entity):
            self.set_app_state(self.monitor_entity, state = 'idle', attributes = {'location': []}) #set it to idle initially

        self.monitor_handlers = dict() #used to store different handlers
        self.monitor_handlers[self.monitor_entity] = None

        everyone_not_home_state = 'binary_sensor.everyone_not_home_state'
        everyone_home_state = 'binary_sensor.everyone_home_state'
        self.gateway_timer = None #run only a single timer at a time, to avoid sending multiple messages to the monitor

        if not self.entity_exists(everyone_not_home_state, namespace = self.hass_namespace): #check if the sensor exist and if not create it
            self.log('Creating Binary Sensor for Everyone Not Home State', level='INFO')
            topic =  'homeassistant/binary_sensor/everyone_not_home_state/config'
            payload = {"name": "Everyone Not Home State", "device_class" : "presence", 
                        "state_topic": "homeassistant/binary_sensor/everyone_not_home_state/state"}
            self.mqtt_send(topic, json.dumps(payload)) #send to homeassistant to create binary sensor sensor for home state

        if not self.entity_exists(everyone_home_state, namespace = self.hass_namespace): #check if the sensor exist and if not create it
            self.log('Creating Binary Sensor for Everyone Home State', level='INFO')
            topic =  'homeassistant/binary_sensor/everyone_home_state/config'
            payload = {"name": "Everyone Home State", "device_class" : "presence", 
                        "state_topic": "homeassistant/binary_sensor/everyone_home_state/state"}
            self.mqtt_send(topic, json.dumps(payload)) #send to homeassistant to create binary sensor sensor for home state

        with shelve.open(self.db_file) as db: #check sensors and beacons
            remove_sensors = []
            '''load up the sensors'''
            try:
                sensors = db[self.presence_topic]
            except:
                sensors = {}

            if isinstance(sensors, str):
                sensors = json.loads(db[self.presence_topic])

            for conf_ha_sensor, user_state_entity in sensors.items():
                '''confirm the entity still in HA if not remove it'''
                if self.entity_exists(conf_ha_sensor, namespace = self.hass_namespace):
                    self.listen_state(self.confidence_updated, conf_ha_sensor, user_state_entity = user_state_entity, namespace = self.hass_namespace)
                else:
                    remove_sensors.append(conf_ha_sensor)

                if user_state_entity  not in self.home_state_entities:
                    self.home_state_entities[user_state_entity ] = list()

                if conf_ha_sensor not in remove_sensors and self.get_state(conf_ha_sensor, namespace = self.hass_namespace) != 'unknown': #meaning its not been scheduled to be removed
                    self.home_state_entities[user_state_entity].append(conf_ha_sensor)

            if remove_sensors != []:
                for sensor in remove_sensors:
                    sensors.pop(sensor)
                    
            db[self.presence_topic] = json.dumps(sensors) #reload new sensor data

            '''load up the beacons as its used to keep track of beacon names'''
            try:
                self.reported_beacons = db['known_beacons']
            except:
                self.reported_beacons= {}

        '''setup home gateway sensors'''
        for gateway_sensor in self.args['home_gateway_sensors']:
            '''it is assumed when the sensor is "on" it is opened and "off" is closed'''
            self.listen_state(self.gateway_opened, gateway_sensor, namespace = self.hass_namespace) #when the door is either opened or closed
        
    def presence_message(self, event_name, data, kwargs):
        topic = data['topic']
        payload = data['payload']  
        if topic.split('/')[0] != self.presence_topic or payload == "": #only interested in the presence topics and payload with json data
            return 

        if topic.split('/')[-1] == 'status': #meaning its a message on the presence system
            location = topic.split('/')[1].replace('_',' ').title()
            self.log('The Presence System in the {} is {}'.format(location, payload.title()))
            return
        
        payload = json.loads(payload)

        if topic.split('/')[-1] == 'start': #meaning a scan is starting
            location = payload['identity']
            if self.get_state(self.monitor_entity) != 'scanning':
                '''since its idle, just set it to scanning and put in the location of the scan'''
                self.set_app_state(self.monitor_entity, state = 'scanning', attributes = {'scan_type' : topic.split('/')[2], 'locations': [location], location : 'scanning'})
            else: #meaning it was already set to 'scanning' already, so just update the location
                locations_attr = self.get_state(self.monitor_entity, attribute = 'locations')
                if location not in locations_attr: #meaning it hadn't started the scan before
                    locations_attr.append(location)
                    self.set_app_state(self.monitor_entity, attributes = {'locations': locations_attr, location : 'scanning'}) #update the location in the event of different scan systems in place
                
        elif topic.split('/')[-1] == 'end': #meaning a scan in a location just ended
            location = payload['identity']
            locations_attr = self.get_state(self.monitor_entity, attribute = 'locations')
            if location in locations_attr: #meaning it had started the scan before
                locations_attr.remove(location)
            
                if locations_attr == []: #meaning no more locations scanning
                    self.set_app_state(self.monitor_entity, state = 'idle', attributes = {'scan_type' : topic.split('/')[2], 'locations': [], location : 'idle'}) #set the monitor state to idle 
                else:
                    self.set_app_state(self.monitor_entity, attributes = {'locations': locations_attr, location : 'idle'}) #update the location in the event of different scan systems in place

        device_name = None
        location = topic.split('/')[1].replace('_',' ').title()
        
        if payload.get('type', None) == 'KNOWN_MAC':
            mac_address = topic.split('/')[2]
            device_name = payload['name']

        elif payload.get('type', None) == 'GENERIC_BEACON':
            mac_address = topic.split('/')[2]

            if mac_address in self.known_beacons or (mac_address not in self.known_beacons and not self.report_only_known_beacons): 
                #if the beacon in the list, or its not on the list, but its not only scanning for known ones
                if mac_address in self.known_beacons:#if it was decalred, use that name
                    device_name = self.known_beacons[mac_address]

                    if mac_address in self.reported_beacons: #if it had generated a name for it before
                        self.reported_beacons.pop(mac_address)

                        with shelve.open(self.db_file) as db: #reload database
                            db['known_beacons'] = self.reported_beacons

                elif payload['name'] != 'Unknown':
                    ''' first check if this same MAC address has been given a name before '''
                    if mac_address in self.reported_beacons: #check if the MAC address has been given a name before
                        device_name = self.reported_beacons[mac_address] #used previously declared name

                    else: #first time its getting this name for a beacon
                        if payload['name'] not in list(self.reported_beacons.values()): #meaning this name not been used before
                            device_name = payload['name']
                        else: #the name has been used before, like beacons from same manufacturer giving same name, so has to generate one
                            for i in range(1, 100):
                                device_name = '{}_{}'.format(payload['name'], i)
                                if device_name not in list(self.reported_beacons.values()): #meaning a name been generated not used before
                                    break

                        self.log('Using Device Name {!r} for MAC Address {!r}'.format(device_name, mac_address))
                        self.reported_beacons[mac_address] = device_name
                        with shelve.open(self.db_file) as db: #load into database
                            db['known_beacons'] = self.reported_beacons

                else: #if after the above, just use the mac address of the device. This will repeat each time it is reported by the monitor system
                    if mac_address in self.reported_beacons: #check if the MAC address has been given a name before in case it didn't broadcast it again
                        device_name = self.reported_beacons[mac_address] #used previously declared name
                    #else:
                    #    self.log("Using MAC Address of Beacon Device, try specfing a name in App Config under 'known_beacons'", level = 'WARNING')
                    #    device_name = mac_address
        else:
            return

        if device_name != None: #process data
            if device_name in self.args['maps']:
                device_name = self.args['maps'][device_name]

            user_name = device_name.lower().replace('’', '').replace(' ', '_').replace("'", "").replace(':', '_')

            location_Id = location.replace(' ', '_').lower()
            confidence = int(payload['confidence'])
            user_conf_entity = '{}_{}'.format(user_name, location_Id)
            conf_ha_sensor = 'sensor.{}'.format(user_conf_entity)
            user_state_entity = '{}_home_state'.format(user_name)
            user_sensor = 'binary_sensor.{}'.format(user_state_entity)
            if user_state_entity not in self.not_home_timers: 
                self.not_home_timers[user_state_entity] = None #used to store the handle for the timer

            appdaemon_entity = '{}.{}'.format(self.presence_topic, user_state_entity)

            if not self.entity_exists(conf_ha_sensor, namespace = self.hass_namespace): #meaning it doesn't exist
                self.log('Creating sensor {!r} for Confidence'.format(conf_ha_sensor), level='INFO')
                topic =  'homeassistant/sensor/{}/{}/config'.format(self.presence_topic, user_conf_entity)
                state_topic = "homeassistant/sensor/{}/{}/state".format(self.presence_topic, user_conf_entity)
                payload = {"name": "{} {}".format(device_name, location), "state_topic": state_topic}
                self.mqtt_send(topic, json.dumps(payload)) #send to homeassistant to create sensor for confidence

                '''create user home state sensor'''
                if not self.entity_exists(user_sensor, namespace = self.hass_namespace): #meaning it doesn't exist.
                                                                                        # it could be assumed it doesn't exist anyway
                    self.log('Creating sensor {!r} for Home State'.format(user_sensor), level='INFO')
                    topic =  'homeassistant/binary_sensor/{}/config'.format(user_state_entity)
                    payload = {"name": "{} Home State".format(device_name), "device_class" : "presence", 
                                "state_topic": "homeassistant/binary_sensor/{}/state".format(user_state_entity)}
                    self.mqtt_send(topic, json.dumps(payload)) #send to homeassistant to create binary sensor sensor for home state

                    '''create app states for mapping user sensors to confidence to store and can be picked up by other apps if needed'''
                    if not self.entity_exists(appdaemon_entity):
                        self.set_app_state(appdaemon_entity, state = 'Initializing', attributes = {'Confidence' : confidence})

                else:
                    if not self.entity_exists(appdaemon_entity): #in the event AppD restarts and not HA
                        self.set_app_state(appdaemon_entity, state = 'Initializing', attributes = {'Confidence' : confidence})
                    user_attributes = self.get_state(appdaemon_entity, attribute = 'all')['attributes']
                    user_attributes['Confidence'] = confidence
                    self.set_app_state(appdaemon_entity, state = 'Updated', attributes = user_attributes)

                self.listen_state(self.confidence_updated, conf_ha_sensor, user_state_entity = user_state_entity, namespace = self.hass_namespace)

                if user_state_entity not in self.home_state_entities:
                    self.home_state_entities[user_state_entity] = list()

                if conf_ha_sensor not in self.home_state_entities[user_state_entity]: #not really needed, but noting wrong in being extra careful
                    self.home_state_entities[user_state_entity].append(conf_ha_sensor)

                self.run_in(self.send_mqtt_message, 1, topic = state_topic, payload = confidence) #use delay so HA has time to setup sensor first before updating

                with shelve.open(self.db_file) as db: #store sensors
                    try:
                        sensors = json.loads(db[self.presence_topic])
                    except:
                        sensors = {}
                    sensors[conf_ha_sensor] = user_state_entity
                    db[self.presence_topic] = json.dumps(sensors)

            else:
                if user_state_entity not in self.home_state_entities:
                    self.home_state_entities[user_state_entity] = list()

                if conf_ha_sensor not in self.home_state_entities[user_state_entity]:
                    self.home_state_entities[user_state_entity].append(conf_ha_sensor)
                    self.listen_state(self.confidence_updated, conf_ha_sensor, user_state_entity = user_state_entity, namespace = self.hass_namespace)
                    with shelve.open(self.db_file) as db: #store sensors
                        try:
                            sensors = json.loads(db[self.presence_topic])
                        except:
                            sensors = {}
                        sensors[conf_ha_sensor] = user_state_entity
                        db[self.presence_topic] = json.dumps(sensors)
                    
                sensor_reading = self.get_state(conf_ha_sensor, namespace = self.hass_namespace)
                if sensor_reading == 'unknown': #this will happen if HA was to restart
                    sensor_reading = 0
                if int(sensor_reading) != confidence: 
                    topic = "homeassistant/sensor/{}/{}/state".format(self.presence_topic, user_conf_entity)
                    payload = confidence
                    self.mqtt_send(topic, payload) #send to homeassistant to update sensor for confidence

                    if not self.entity_exists(appdaemon_entity): #in the event AppD restarts and not HA
                        self.set_app_state(appdaemon_entity, state = 'Initializing', attributes = {'Confidence' : confidence})
                    user_attributes = self.get_state(appdaemon_entity, attribute = 'all')['attributes']
                    user_attributes['Confidence'] = confidence
                    self.set_app_state(appdaemon_entity, state = 'Updated', attributes = user_attributes)

    def confidence_updated(self, entity, attribute, old, new, kwargs):
        user_state_entity = kwargs['user_state_entity']
        user_sensor = 'binary_sensor.' + user_state_entity
        appdaemon_entity = '{}.{}'.format(self.presence_topic, user_state_entity)
        user_conf_sensors = self.home_state_entities.get(user_state_entity, None)
        if user_conf_sensors != None:
            sensor_res = list(map(lambda x: self.get_state(x, namespace = self.hass_namespace), user_conf_sensors))
            sensor_res = [i for i in sensor_res if i != 'unknown'] # remove unknown vales from list
            sensor_res = [i for i in sensor_res if i != None] # remove None values from list
            if  sensor_res != [] and any(list(map(lambda x: int(x) >= self.minimum_conf, sensor_res))): #meaning at least one of them states is greater than the minimum so device definitely home
                if self.not_home_timers[user_state_entity] != None: #cancel timer if running
                    self.cancel_timer(self.not_home_timers[user_state_entity])
                    self.not_home_timers[user_state_entity] = None

                topic = "homeassistant/binary_sensor/{}/state".format(user_state_entity)
                payload = 'ON'
                self.mqtt_send(topic, payload) #send to homeassistant to update sensor that user home
                self.set_app_state(appdaemon_entity, state = 'Home') #not needed but one may as well for other apps

                if user_sensor in self.all_users_sensors: #check if everyone home
                    '''since at least someone home, set to off the everyone not home state'''
                    appdaemon_entity = '{}.everyone_not_home_state'.format(self.presence_topic)
                    topic = "homeassistant/binary_sensor/everyone_not_home_state/state"
                    payload = 'OFF'
                    self.mqtt_send(topic, payload) #send to homeassistant to update sensor that user home
                    self.set_app_state(appdaemon_entity, state = False) #not needed but one may as well for other apps

                    self.run_in(self.check_home_state, 2, check_state = 'is_home')

            else:
                if new == 'unknown':
                    new = 0
                if self.not_home_timers[user_state_entity] == None and self.get_state(user_sensor, namespace = self.hass_namespace) != 'off' and int(new) == 0: #run the timer
                    self.run_arrive_scan() #run so it does another scan before declaring the user away as extra check within the timeout time
                    self.not_home_timers[user_state_entity] = self.run_in(self.not_home_func, self.timeout, user_state_entity = user_state_entity)

    def not_home_func(self, kwargs):
        user_state_entity = kwargs['user_state_entity']
        user_sensor = 'binary_sensor.' + user_state_entity
        appdaemon_entity = '{}.{}'.format(self.presence_topic, user_state_entity)
        user_conf_sensors = self.home_state_entities[user_state_entity]
        sensor_res = list(map(lambda x: self.get_state(x, namespace = self.hass_namespace), user_conf_sensors))
        sensor_res = [i for i in sensor_res if i != 'unknown'] # remove unknown vales from list
        if  all(list(map(lambda x: int(x) < self.minimum_conf, sensor_res))): #still confirm for the last time
            topic = "homeassistant/binary_sensor/{}/state".format(user_state_entity)
            payload = 'OFF'
            self.mqtt_send(topic, payload) #send to homeassistant to update sensor that user home
            self.set_app_state(appdaemon_entity, state = 'Not Home') #not needed but one may as well for other apps

            if user_sensor in self.all_users_sensors: #check if everyone not home
                '''since at least someone not home, set to off the everyone home state'''
                appdaemon_entity = '{}.everyone_home_state'.format(self.presence_topic)
                topic = "homeassistant/binary_sensor/everyone_home_state/state"
                payload = 'OFF'
                self.mqtt_send(topic, payload) #send to homeassistant to update sensor that user home
                self.set_app_state(appdaemon_entity, state = False) #not needed but one may as well for other apps

                self.run_in(self.check_home_state, 2, check_state = 'not_home')

    def send_mqtt_message(self, kwargs):
        topic = kwargs['topic']
        payload = kwargs['payload']
        if not kwargs.get('scan', False): #meaning its not for scanning, but for like sensor updating 
            self.mqtt_send(topic, payload) #send to broker
        else:
            self.gateway_timer = None #meaning no more gateway based timer is running

            if self.get_state(self.monitor_entity) == 'idle': #meaning its not busy
                self.mqtt_send(topic, payload) #send to scan for departure of anyone
            else: #meaning it is busy so re-run timer for it to get idle before sending the message to start scan
                self.gateway_timer = self.run_in(self.send_mqtt_message, 10, topic = topic, payload = payload, scan = True)

    def gateway_opened(self, entity, attribute, old, new, kwargs):
        '''one of the gateways was opened and so needs to check what happened'''
        everyone_not_home_state = 'binary_sensor.everyone_not_home_state'
        everyone_home_state = 'binary_sensor.everyone_home_state'

        if self.gateway_timer != None: #meaning a timer is running already
            self.cancel_timer(self.gateway_timer)
            self.gateway_timer = None

        if self.get_state(everyone_not_home_state, namespace = self.hass_namespace) == 'on': #meaning no one at home
            self.run_arrive_scan()

        elif self.get_state(everyone_home_state, namespace = self.hass_namespace) == 'on': #meaning everyone at home
            self.run_depart_scan()

        else:
            self.run_arrive_scan()
            self.run_depart_scan()

    def check_home_state(self, kwargs):
        check_state = kwargs['check_state']
        if check_state == 'is_home':
            ''' now run to check if everyone is home since a user is home'''
            user_res = list(map(lambda x: self.get_state(x, namespace = self.hass_namespace), self.all_users_sensors))
            user_res = [i for i in user_res if i != 'unknown'] # remove unknown vales from list
            user_res = [i for i in user_res if i != None] # remove None vales from list

            if all(list(map(lambda x: x == 'on', user_res))): #meaning every one is home
                appdaemon_entity = '{}.everyone_home_state'.format(self.presence_topic)
                topic = "homeassistant/binary_sensor/everyone_home_state/state"
                payload = 'ON'
                self.mqtt_send(topic, payload) #send to homeassistant to update sensor that user home
                self.set_app_state(appdaemon_entity, state = True) #not needed but one may as well for other apps
                
        elif check_state == 'not_home':
            ''' now run to check if everyone is not home since a user is not home'''
            user_res = list(map(lambda x: self.get_state(x, namespace = self.hass_namespace), self.all_users_sensors))
            user_res = [i for i in user_res if i != 'unknown'] # remove unknown vales from list
            user_res = [i for i in user_res if i != None] # remove None vales from list

            if all(list(map(lambda x: x == 'off', user_res))): #meaning no one is home
                appdaemon_entity = '{}.everyone_not_home_state'.format(self.presence_topic)
                topic = "homeassistant/binary_sensor/everyone_not_home_state/state"
                payload = 'ON'
                self.mqtt_send(topic, payload) #send to homeassistant to update sensor that user home
                self.set_app_state(appdaemon_entity, state = True) #not needed but one may as well for other apps

    def monitor_changed_state(self, entity, attribute, old, new, kwargs):
        scan = kwargs['scan']
        topic = kwargs['topic']
        payload = kwargs['payload']
        self.mqtt_send(topic, payload) #send to broker
        self.cancel_listen_state(self.monitor_handlers[scan])
        self.monitor_handlers[scan] = None

    def run_arrive_scan(self, location = None):
        topic = '{}/scan/Arrive'.format(self.presence_topic)
        payload = ''

        '''used to listen for when the monitor is free, and then send the message'''
        if self.get_state(self.monitor_entity) == 'idle': #meaning its not busy
            self.mqtt_send(topic, payload) #send to scan for arrival of anyone
        else:
            '''meaning it is busy so wait for it to get idle before sending the message'''
            if self.monitor_handlers.get('Arrive Scan', None) == None: #meaning its not listening already
                self.monitor_handlers['Arrive Scan'] = self.listen_state(self.monitor_changed_state, self.monitor_entity, 
                            new = 'idle', old = 'scanning', scan = 'Arrive Scan', topic = topic, payload = payload)
        return

    def run_depart_scan(self, location = None):
        topic ='{}/scan/Depart'.format(self.presence_topic)
        payload = ''
        self.gateway_timer = self.run_in(self.send_mqtt_message, self.depart_check_time, topic = topic, payload = payload, scan = True) #send to scan for departure of anyone
        return
