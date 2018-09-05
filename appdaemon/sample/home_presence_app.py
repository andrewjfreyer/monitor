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

        self.monitor_entity = '{}.monitor_state'.format(self.presence_topic) #used to check if the network monitor is busy 
        if not self.entity_exists(self.monitor_entity):
            self.set_app_state(self.monitor_entity, state = 'idle', attributes = {}) #set it to idle initially

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

        with shelve.open(self.db_file) as db: #check sensors
            remove_sensors = []
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
                    
            db[self.presence_topic] = json.dumps(sensors) #reload new data

        '''setup home gateway sensors'''
        for gateway_sensor in self.args['home_gateway_sensors']:
            '''it is assumed when the sensor is "on" it is opened'''
            self.listen_state(self.gateway_opened, gateway_sensor, new = 'on', namespace = self.hass_namespace)
        
    def presence_message(self, event_name, data, kwargs):
        topic = data['topic']
        if topic.split('/')[0] != self.presence_topic: #only interested in the presence topics
            return 

        if topic.split('/')[-1] == 'start': #meaning a scan is starting 
            if self.get_state(self.monitor_entity) != 'scanning':
                '''since it idle, just set it to scanning to the scan number to 1 being the first'''
                self.set_app_state(self.monitor_entity, state = 'scanning', attributes = {'scan_type' : topic.split('/')[2], 'scan_num': 1})
            else: #meaing it was already set to 'scanning' already, so just update the number
                scan_num = self.get_state(self.monitor_entity, attribute = 'scan_num')
                if scan_num == None: #happens if AppD was to restart
                    scan_num = 0
                scan_num = scan_num + 1
                self.set_app_state(self.monitor_entity, attributes = {'scan_num': scan_num}) #update the scan number in the event of different scan systems in place

            #self.log('__function__, __line__, Scan Number is {} and Monitor State is {}'.format(self.get_state(self.monitor_entity, attribute = 'scan_num'), self.get_state(self.monitor_entity)))
                
        elif topic.split('/')[-1] == 'end': #meaning a scan just ended
            scan_num = self.get_state(self.monitor_entity, attribute = 'scan_num')
            if scan_num == None: #happens if AppD was to restart
                scan_num = 0
            scan_num = scan_num - 1
            if scan_num <= 0: # a <0 will happen if there is a restart and a message is missed in the process
                self.set_app_state(self.monitor_entity, state = 'idle', attributes = {'scan_type' : topic.split('/')[2], 'scan_num': 0}) #set the monitor state to idle since no messages being sent
            else:
                self.set_app_state(self.monitor_entity, attributes = {'scan_num': scan_num}) #update the scan number in the event of different scan systems are in place

            #self.log('__function__, __line__, Scan Number is {} and Monitor State is {}'.format(self.get_state(self.monitor_entity, attribute = 'scan_num'), self.get_state(self.monitor_entity)))

        if topic.split('/')[1] != 'owner':
            return

        payload = json.loads(data['payload'])

        if payload.get('status', None) != None: #meaning its a message on the presence system
            location = topic.split('/')[2].replace('_',' ').title()
            self.log('The Presence System in the {} is {}'.format(location, payload.get('status').title()))

        if payload.get('type', None) != 'KNOWN_MAC' or payload.get('name', None) == 'Unknown Name': #confirm its for a known MAC address
            return

        location = topic.split('/')[2].replace('_',' ').title()
        location_Id = location.replace(' ', '_').lower()
        device_name = payload['name']
        user_name = payload['name'].lower().replace('’', '').replace(' ', '_').replace("'", "")
        mac_address = topic.split('/')[3]
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
                if self.not_home_timers[user_state_entity] == None and self.get_state(user_sensor, namespace = self.hass_namespace) != 'off': #run the timer
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
                self.gateway_timer = self.run_in(self.send_mqtt_message, self.depart_check_time, topic = topic, payload = payload, scan = True) 

    def gateway_opened(self, entity, attribute, old, new, kwargs):
        '''one of the gateways was opened and so needs to check what happened'''
        everyone_not_home_state = 'binary_sensor.everyone_not_home_state'
        everyone_home_state = 'binary_sensor.everyone_home_state'

        if self.gateway_timer != None: #meaning a timer is running already
            self.cancel_timer(self.gateway_timer)
            self.gateway_timer = None

        if self.get_state(everyone_not_home_state, namespace = self.hass_namespace) == 'on': #meaning no one at home
            topic = '{}/scan/Arrive'.format(self.presence_topic)
            payload = ''
            '''used to listen for when the monitor is free, and then send the message'''

            if self.get_state(self.monitor_entity) == 'idle': #meaning its not busy
                self.mqtt_send(topic, payload) #send to scan for arrival of anyone
            else:
                '''meaning it is busy so wait for it to get idle before sending the message'''
                if self.monitor_handlers.get('Arrive Scan', None) == None: #meaning its not listening already
                    self.monitor_handlers['Arrive Scan'] = self.listen_state(self.monitor_changed_state, self.monitor_entity, 
                                new = 'idle', scan = 'Arrive Scan', topic = topic, payload = payload)

        elif self.get_state(everyone_home_state, namespace = self.hass_namespace) == 'on': #meaning everyone at home
            topic ='{}/scan/Depart'.format(self.presence_topic)
            payload = ''
            self.gateway_timer = self.run_in(self.send_mqtt_message, self.depart_check_time, topic = topic, payload = payload, scan = True) #send to scan for departure of anyone
        else:
            topic = '{}/scan/Arrive'.format(self.presence_topic)
            payload = ''
            if self.get_state(self.monitor_entity) == 'idle': #meaning its not busy
                self.mqtt_send(topic, payload) #send to scan for arrival of anyone
            else:
                '''used to listen for when the monitor is free, and then send the message'''
                if self.monitor_handlers.get('Arrive Scan', None) == None: #meaning its not listening already
                    self.monitor_handlers['Arrive Scan'] = self.listen_state(self.monitor_changed_state, self.monitor_entity, 
                                new = 'idle', scan = 'Arrive Scan', topic = topic, payload = payload)

            topic ='{}/scan/Depart'.format(self.presence_topic)
            payload = ''
            self.gateway_timer = self.run_in(self.send_mqtt_message, self.depart_check_time, topic = topic, payload = payload, scan = True) #send to scan for departure of anyone

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
        topic = kwargs['topic']
        payload = kwargs['payload']
        scan = kwargs['scan']
        self.mqtt_send(topic, payload) #send to broker
        self.cancel_listen_state(self.monitor_handlers[scan])
        self.monitor_handlers[scan] = None
