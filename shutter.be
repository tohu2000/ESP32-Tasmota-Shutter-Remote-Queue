import string

class ShutterController
    # Variable declarations
    var max_chan, current_chan, queue, working
    var pins, pin_power
    var r_up, r_down, r_left, r_right, r_stop
    var pulse_ms, delay_ms
    var is_sleeping, last_act
    var status_text, command_twice, debug

    def init()
        import gpio
        # Configuration
        self.max_chan = 6            
        self.pins = [17, 16, 27, 25, 26] # Up, Down, Left, Right, Stop
        self.pin_power = 18              # Power control for Hard Reset
        self.pulse_ms = 250
        self.delay_ms = 450
        self.status_text = "Idle"
        self.command_twice = true 
        self.debug = true 
        
        # Hardware Setup
        for p:self.pins
            gpio.pin_mode(p, gpio.OUTPUT_OPEN_DRAIN)
            gpio.digital_write(p, gpio.HIGH)
        end
        gpio.pin_mode(self.pin_power, gpio.OUTPUT)
        
        # Internal mapping
        self.r_up=0; self.r_down=1; self.r_left=2; self.r_right=3; self.r_stop=4
        self.last_act = tasmota.millis()
        self.queue = []
        self.working = false
        self.current_chan = 1
        self.is_sleeping = true

        # Commands
        tasmota.add_cmd('shutter_chan', / cmd, idx, payload -> self.add_to_queue("chan", payload))
        tasmota.add_cmd('shutter_go', / cmd, idx, payload -> self.add_to_queue("move", payload))
        tasmota.add_cmd('shutter_reset', / cmd, idx, payload -> self.remote_hard_reset())
        tasmota.add_cmd('shutter_full', / cmd, idx, payload -> self.full_command(payload))
        tasmota.add_cmd('shade', / cmd, idx, payload -> self.add_to_queue("move", "shade"))

        tasmota.add_driver(self)
        self.remote_hard_reset()
        
        if (self.debug) print("BRY: Shutter Controller Ready") end
        
        tasmota.add_rule("mqtt#connected", / -> self.publish_status("Sleep"))
        tasmota.set_timer(500, / -> self.monitor_loop())
    end

    def full_command(payload)
        var args = string.split(payload, ",")
        if (size(args) >= 2)
            self.add_to_queue("chan", args[0])
            self.add_to_queue("move", args[1])
        end
        tasmota.resp_cmnd_done()
    end

    def remote_hard_reset()
        import gpio
        if (self.debug) print("BRY: Hard Resetting Remote...") end
        gpio.digital_write(self.pin_power, 1)
        tasmota.delay(4000)
        gpio.digital_write(self.pin_power, 0)
        tasmota.delay(1500)
        self.current_chan = 1
        self.is_sleeping = true
        self.publish_status("Sleep")
    end

    def publish_status(reason)
        var topic = tasmota.cmd("Topic")['Topic']
        if (topic != nil)
            self.status_text = str(reason)
            tasmota.publish("stat/" + topic + "/STATE", self.status_text, true)
            tasmota.publish("stat/" + topic + "/CHANNEL", str(self.current_chan), true)
        end
    end

    def monitor_loop()
        var now = tasmota.millis()
        if (!self.is_sleeping && (now - self.last_act > 9950))
            self.is_sleeping = true
            self.publish_status("Sleep")
            if (self.debug) print("BRY: Auto-Sleep triggered") end
        end
        tasmota.set_timer(500, / -> self.monitor_loop())
    end

    def keep_awake()
        self.last_act = tasmota.millis()
        if (self.is_sleeping)
            if (self.debug) print("BRY: Wake-up pulse") end
            self.pulse_raw(self.r_stop)
            tasmota.delay(800)
            self.is_sleeping = false
        end
    end

    def add_to_queue(q_type, payload)
        self.queue.push([q_type, payload])
        if (!self.working)
            self.working = true
            tasmota.set_timer(0, / -> self.process_queue())
        end
        tasmota.resp_cmnd_done()
    end

    def process_queue()
        if (size(self.queue) == 0)
            self.working = false
            tasmota.set_timer(200, / -> self.publish_status(self.is_sleeping ? "Sleep" : "Idle"))
            return
        end

        var item = self.queue.pop(0)
        var q_type = item[0]
        var payload = item[1]
        
        if (q_type == "chan")
            if (self.debug) print("BRY: Target Chan " + str(payload)) end
            self.publish_status("Stepping")
            self.move_to_channel(int(payload))
            tasmota.set_timer(1000, / -> self.process_queue())
        end
        
        if (q_type == "move")
            var cmd = str(payload)
            if (self.debug) print("BRY: Command " + cmd) end
            self.publish_status("Moving")
            
            var wait = 500 
            if (cmd == "shade")
                wait = 6000 
            end
            if (cmd != "shade" && self.command_twice)
                wait = 1200
            end
            
            self.do_move(cmd)
            tasmota.set_timer(wait + 200, / -> self.process_queue())
        end
    end

    def move_to_channel(target)
        if (target < 1 || target > self.max_chan || target == self.current_chan) return end
        self.keep_awake()
        var diff = target - self.current_chan
        var relay = self.r_left
        if (diff > 0) relay = self.r_right end
        
        var steps = (diff > 0) ? diff : -diff
        for i:0..steps-1
            self.pulse_raw(relay)
            if (i < steps-1) tasmota.delay(self.delay_ms) end
        end
        self.current_chan = target
    end

    def do_move(cmd_str)
        self.keep_awake()
        var c = string.tolower(str(cmd_str))
        import gpio
        
        # Flat logic: handle 'shade' and exit
        if (c == "shade")
            if (self.debug) print("BRY: Shade hold start") end
            gpio.digital_write(self.pins[self.r_stop], 0)
            tasmota.set_timer(5500, / -> gpio.digital_write(self.pins[self.r_stop], 1))
            return 
        end
        
        # Handle standard movement
        var r = self.r_stop
        if (c == "up")   r = self.r_up   end
        if (c == "down") r = self.r_down end
        
        self.pulse_raw(r)
        
        if (self.command_twice)
            tasmota.set_timer(550, / -> self.pulse_raw(r))
        end
    end

    def pulse_raw(idx)
        import gpio
        gpio.digital_write(self.pins[idx], 0)
        tasmota.delay(self.pulse_ms)
        gpio.digital_write(self.pins[idx], 1)
    end
    
    def json_append()
        var msg = ",\"Shutter\":{\"State\":\"" + self.status_text + "\",\"Channel\":" + str(self.current_chan) + "}"
        tasmota.response_append(msg)
    end
end
var shutter = ShutterController()