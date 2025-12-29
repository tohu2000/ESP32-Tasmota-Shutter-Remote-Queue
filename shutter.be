import string

class ShutterController
    var max_chan, current_chan, queue, working
    var pins, pin_power
    var r_up, r_down, r_left, r_right, r_stop
    var pulse_ms, delay_ms
    var is_sleeping, last_act
    var status_text

    def init()
        import gpio
        self.max_chan = 6            
        self.pins = [17, 16, 27, 25, 26] 
        self.pin_power = 18
        self.pulse_ms = 250
        self.delay_ms = 450
        self.status_text = "Idle"
        
        for p:self.pins
            gpio.pin_mode(p, gpio.OUTPUT_OPEN_DRAIN)
            gpio.digital_write(p, gpio.HIGH)
        end
        gpio.pin_mode(self.pin_power, gpio.OUTPUT)
        
        self.r_up=0; self.r_down=1; self.r_left=2; self.r_right=3; self.r_stop=4
        self.last_act = tasmota.millis()
        self.queue = []
        self.working = false
        self.current_chan = 1
        self.is_sleeping = true

        tasmota.add_cmd('shutter_chan', / cmd, idx, payload -> self.add_to_queue("chan", payload))
        tasmota.add_cmd('shutter_go', / cmd, idx, payload -> self.add_to_queue("move", payload))
        tasmota.add_cmd('shutter_reset', / cmd, idx, payload -> self.remote_hard_reset())
        tasmota.add_cmd('shutter_full', / cmd, idx, payload -> self.full_command(payload))

        tasmota.add_driver(self)
        self.remote_hard_reset()
        
        tasmota.add_rule("mqtt#connected", / -> self.publish_status("Sleep"))
        tasmota.set_timer(500, / -> self.monitor_loop())
    end

    def full_command(payload)
        var args = string.split(payload, ",")
        if size(args) >= 2
            self.add_to_queue("chan", args[0])
            self.add_to_queue("move", args[1])
        end
        tasmota.resp_cmnd_done()
    end

    def remote_hard_reset()
        import gpio
        gpio.digital_write(self.pin_power, gpio.HIGH); tasmota.delay(4000)
        gpio.digital_write(self.pin_power, gpio.LOW); tasmota.delay(1500)
        self.current_chan = 1
        self.is_sleeping = true
        self.status_text = "Sleep"
        self.publish_status("Sleep")
    end

    def publish_status(reason)
        var topic = tasmota.cmd("Topic")['Topic']
        if topic != nil
            self.status_text = str(reason)
            # Nur die flachen Topics, kein JSON-Objekt
            tasmota.publish("stat/" + topic + "/STATE", self.status_text, true)
            tasmota.publish("stat/" + topic + "/CHANNEL", str(self.current_chan), true)
        end
    end

    def monitor_loop()
        var now = tasmota.millis()
        if !self.is_sleeping && (now - self.last_act > 9950)
            self.is_sleeping = true
            self.publish_status("Sleep")
        end
        tasmota.set_timer(500, / -> self.monitor_loop())
    end

    def keep_awake()
        self.last_act = tasmota.millis()
        if self.is_sleeping
            self.pulse_raw(self.r_stop); tasmota.delay(800)
            self.is_sleeping = false
        end
    end

    def add_to_queue(q_type, payload)
        self.queue.push([q_type, payload])
        if !self.working
            self.working = true
            tasmota.set_timer(0, / -> self.process_queue())
        end
        tasmota.resp_cmnd_done()
    end

    def process_queue()
        if size(self.queue) == 0
            self.working = false
            self.publish_status(self.is_sleeping ? "Sleep" : "Idle")
            return
        end
        var item = self.queue.pop(0)
        if item[0] == "chan"
            self.publish_status("Stepping")
            self.move_to_channel(int(item[1]))
            tasmota.set_timer(800, / -> self.process_queue())
        else
            self.publish_status("Moving")
            self.do_move(str(item[1]))
            tasmota.set_timer(500, / -> self.process_queue())
        end
    end

    def move_to_channel(target)
        if target < 1 || target > self.max_chan || target == self.current_chan return end
        self.keep_awake()
        var diff = target - self.current_chan
        var relay = (diff > 0) ? self.r_right : self.r_left
        var steps = (diff > 0) ? diff : -diff
        for i:0..steps-1
            self.pulse_raw(relay)
            if i < steps-1 tasmota.delay(self.delay_ms) end
        end
        self.current_chan = target
        self.publish_status("Stepping")
    end

    def do_move(cmd_str)
        self.keep_awake()
        var r_idx = self.r_stop
        var c = string.tolower(str(cmd_str))
        if c == "up" r_idx = self.r_up
        elif c == "down" r_idx = self.r_down
        end
        self.pulse_raw(r_idx)
    end

    def pulse_raw(idx)
        import gpio
        gpio.digital_write(self.pins[idx], gpio.LOW)
        tasmota.delay(self.pulse_ms)
        gpio.digital_write(self.pins[idx], gpio.HIGH)
    end
    
    def json_append()
        var msg = ",\"Shutter\":{\"State\":\"" + self.status_text + "\",\"Channel\":" + str(self.current_chan) + "}"
        tasmota.response_append(msg)
    end
end
var shutter = ShutterController()