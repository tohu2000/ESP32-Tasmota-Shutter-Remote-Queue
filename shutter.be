import string

class ShutterController : Driver
    var max_chan, current_chan, queue, working, remote_channels_total
    var pins, pin_power
    var r_up, r_down, r_left, r_right, r_stop, r_set
    var pulse_ms, delay_chan, delay_move
    var is_sleeping, last_act
    var status_text, command_twice, debug

    def init()
        import gpio
        # --- KONFIGURATION ---
        self.remote_channels_total = 16
        self.max_chan = 15
        self.pins = [17, 16, 27, 25, 26, 33] 
        self.pin_power = 18              
        
        # --- TIMING ---
        self.pulse_ms = 250      
        self.delay_chan = 200    
        self.delay_move = 800    
        
        self.status_text = "Idle"
        self.command_twice = false 
        self.debug = true 
        
        # GPIO Setup
        for p:self.pins
            gpio.pin_mode(p, gpio.OUTPUT_OPEN_DRAIN)
            gpio.digital_write(p, gpio.HIGH)
        end
        gpio.pin_mode(self.pin_power, gpio.OUTPUT)
        
        # Mapping & States
        self.r_up=0; self.r_down=1; self.r_left=2; self.r_right=3; self.r_stop=4; self.r_set=5
        self.last_act = tasmota.millis()
        self.queue = []
        self.working = false
        self.current_chan = 1
        self.is_sleeping = true

        # Tasmota Commands
        tasmota.add_cmd('shutter_chan',  / cmd, idx, payload -> self.add_to_queue("chan", payload))
        tasmota.add_cmd('shutter_go',    / cmd, idx, payload -> self.add_to_queue("move", payload))
        tasmota.add_cmd('shutter_reset', / -> self.remote_hard_reset())
        tasmota.add_cmd('shutter_full',  / cmd, idx, payload -> self.full_command(payload))
        
        # Short Commands
        tasmota.add_cmd('chan',      / cmd, idx, payload -> self.add_to_queue("chan", payload))
        tasmota.add_cmd('pairup',    / -> self.pair_sequence_up())
        tasmota.add_cmd('pairdown',  / -> self.pair_sequence_down())
        tasmota.add_cmd('learn',     / -> self.learn_sequence())
        tasmota.add_cmd('goup',      / -> self.add_to_queue("move", "up"))
        tasmota.add_cmd('godown',    / -> self.add_to_queue("move", "down"))
        tasmota.add_cmd('stop',      / -> self.add_to_queue("move", "stop"))
        tasmota.add_cmd('wifi',      / cmd, idx, payload -> self.toggle_wifi(payload))
        
        tasmota.add_driver(self)
        self.remote_hard_reset() 
        tasmota.set_timer(500, / -> self.monitor_loop())
        self.publish_status("Initialized")
    end

    def toggle_wifi(payload)
        import wifi
        var state = int(payload)
        if (state == 0) wifi.stop() else wifi.start() end
        tasmota.resp_cmnd_done()
    end

    def pair_sequence_up()
        if (self.working) return end
        self.working = true
        self.last_act = tasmota.millis()
        self.is_sleeping = false
        self.publish_status("Pairing")
        try
            self.pulse_raw(self.r_set)
            tasmota.delay(1000)
            self.pulse_raw(self.r_set)
            tasmota.delay(1000)
            self.pulse_raw(self.r_up)
            self.publish_status("Pair Done")
        except .. as e, msg
            self.safe_state()
        end
        self.working = false
        tasmota.resp_cmnd_done()
    end

    def pair_sequence_down()
        if (self.working) return end
        self.working = true
        self.last_act = tasmota.millis()
        self.is_sleeping = false
        self.publish_status("Pairing")
        try
            self.pulse_raw(self.r_set)
            tasmota.delay(1000)
            self.pulse_raw(self.r_set)
            tasmota.delay(1000)
            self.pulse_raw(self.r_down)
            self.publish_status("Pair Done")
        except .. as e, msg
            self.safe_state()
        end
        self.working = false
        tasmota.resp_cmnd_done()
    end

    def learn_sequence()
        if (self.working) return end
        self.working = true
        self.last_act = tasmota.millis()
        self.is_sleeping = false
        self.publish_status("Learning")
        try
            self.pulse_raw(self.r_set)
            tasmota.delay(800)
            self.pulse_raw(self.r_set)
            tasmota.delay(800)
            self.publish_status("Learning Done")
        except .. as e, msg
            self.safe_state()
        end
        self.working = false
        tasmota.resp_cmnd_done()
    end

    def safe_state()
        import gpio
        for p:self.pins
            gpio.digital_write(p, gpio.HIGH)
        end
    end

    def remote_hard_reset()
        import gpio
        gpio.digital_write(self.pin_power, 1)
        tasmota.delay(4000)
        gpio.digital_write(self.pin_power, 0)
        tasmota.delay(2000)
        self.current_chan = 1
        self.publish_status("Reset Done")
    end

    def move_to_channel(t)
        if (t < 0 || t > self.max_chan) return end
        if (self.is_sleeping) self.keep_awake() end
        self.working = true
        var m = self.remote_channels_total
        var df = (t - self.current_chan + m) % m
        var dr = (self.current_chan - t + m) % m
        var f = (df <= dr)
        var k = f ? df : dr
        var r = f ? self.r_right : self.r_left
        try
            for i:1..k
                self.pulse_raw(r)
                self.current_chan = (self.current_chan + (f ? 1 : -1) + m) % m
                self.last_act = tasmota.millis()
                if (i < k) tasmota.delay(self.delay_chan) end
            end
            self.safe_state()
        except .. as e, msg
            self.safe_state()
        end
    end

    def do_move(cmd_str)
        var c = string.tolower(cmd_str)
        self.last_act = tasmota.millis()
        self.is_sleeping = false 
        try
            if (c == "shade")
                import gpio
                gpio.digital_write(self.pins[self.r_stop], 0)
                tasmota.set_timer(5500, / -> self.safe_state())
                return 
            end
            var r = (c == "up") ? self.r_up : (c == "down" ? self.r_down : self.r_stop)
            self.pulse_raw(r)
            if (self.command_twice)
                tasmota.set_timer(550, / -> self.pulse_raw(r))
            end
        except .. as e, msg
            self.safe_state()
        end
    end

    def pulse_raw(idx)
        import gpio
        try
            gpio.digital_write(self.pins[idx], 0)
            tasmota.delay(self.pulse_ms)
            gpio.digital_write(self.pins[idx], 1)
        except .. as e, msg
            self.safe_state()
        end
    end

    def keep_awake()
        self.last_act = tasmota.millis()
        if (self.is_sleeping)
            self.pulse_raw(self.r_stop)
            tasmota.delay(200)
            self.is_sleeping = false
        end
    end

    def monitor_loop()
        var now = tasmota.millis()
        import gpio
        for p:self.pins
            if (gpio.digital_read(p) == 0 && now - self.last_act > 10000)
                self.safe_state()
                print(f"BRY: WATCHDOG - Pin {p} HIGH")
            end
        end
        if (!self.is_sleeping && now - self.last_act > 7000)
            self.is_sleeping = true
            self.publish_status("Sleep")
        end
        tasmota.set_timer(500, / -> self.monitor_loop())
    end

    def add_to_queue(q_type, payload)
        if (self.working) return end
        var val = payload
        if (q_type == "chan")
            val = int(payload)
            if (val < 0 || val > self.max_chan)
                tasmota.resp_cmnd_error()
                return 
            end
            if (val == self.current_chan) 
                tasmota.resp_cmnd_done()
                return 
            end
        end
        self.working = true
        self.queue.push([q_type, val])
        tasmota.set_timer(0, / -> self.process_queue())
        tasmota.resp_cmnd_done()
    end

    def process_queue()
        if (size(self.queue) == 0)
            self.working = false
            tasmota.set_timer(200, / -> self.publish_status(self.is_sleeping ? "Sleep" : "Idle"))
            return
        end
        var item = self.queue.pop(0)
        if (item[0] == "chan")
            self.publish_status("Stepping")
            self.move_to_channel(item[1])
            tasmota.set_timer(300, / -> self.process_queue())
        elif (item[0] == "move")
            self.publish_status("Moving")
            var wait = (item[1] == "shade") ? 6500 : self.delay_move 
            self.do_move(str(item[1]))
            tasmota.set_timer(wait, / -> self.process_queue())
        end
    end

    def full_command(payload)
        var args = string.split(payload, ",")
        if (size(args) >= 2)
            self.add_to_queue("chan", args[0])
            self.add_to_queue("move", args[1])
        end
        tasmota.resp_cmnd_done()
    end

    def publish_status(reason)
        var topic = tasmota.cmd("Topic")['Topic']
        if (topic != nil)
            self.status_text = str(reason)
            tasmota.publish("stat/" + topic + "/STATE", self.status_text, false)
            tasmota.publish("stat/" + topic + "/CHANNEL", str(self.current_chan), false)
            tasmota.publish("tele/" + topic + "/SENSOR", self.get_json_status(), false)
        end
    end

    def get_json_status()
        return "{\"Time\":\"" + tasmota.time_str(tasmota.rtc()['local']) + "\",\"Shutter\":{\"State\":\"" + self.status_text + "\",\"Channel\":" + str(self.current_chan) + "}}"
    end
end

var shutter = ShutterController()