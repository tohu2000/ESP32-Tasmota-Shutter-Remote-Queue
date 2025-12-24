import string

class ShutterController
    var max_chan, current_chan, queue, working, remote_channels_total
    var pins, pin_power
    var r_up, r_down, r_left, r_right, r_stop, r_set
    var pulse_ms, delay_chan, delay_move
    var is_sleeping, last_act
    var status_text, command_twice, debug

    def init()
        import gpio
        # --- KONFIGURATION ---
        self.remote_channels_total = 16 #00-15
        self.max_chan = 15 #00 will be ignored           
        # NEU: GPIO 33 als 6. Pin für die SET-Taste hinzugefügt
        self.pins = [17, 16, 27, 25, 26, 33] 
        self.pin_power = 18              
        
        # --- TIMING ---
        self.pulse_ms = 120      
        self.delay_chan = 150    
        self.delay_move = 800    
        
        self.status_text = "Idle"
        self.command_twice = false 
        self.debug = true 
        
        for p:self.pins
            gpio.pin_mode(p, gpio.OUTPUT_OPEN_DRAIN)
            gpio.digital_write(p, gpio.HIGH)
        end
        gpio.pin_mode(self.pin_power, gpio.OUTPUT)
        
        # NEU: r_set Mapping auf Index 5
        self.r_up=0; self.r_down=1; self.r_left=2; self.r_right=3; self.r_stop=4; self.r_set=5
        self.last_act = tasmota.millis()
        self.queue = []
        self.working = false
        self.current_chan = 1
        self.is_sleeping = true

        # NEU: Pairing Befehl registriert
        tasmota.add_cmd('shutter_chan', / cmd, idx, payload -> self.add_to_queue("chan", payload))
        tasmota.add_cmd('shutter_go', / cmd, idx, payload -> self.add_to_queue("move", payload))
        tasmota.add_cmd('shutter_reset', / -> self.remote_hard_reset())
        tasmota.add_cmd('shutter_pair', / -> self.pair_sequence())
        tasmota.add_cmd('shutter_full', / cmd, idx, payload -> self.full_command(payload))
        
        tasmota.add_driver(self)
        self.remote_hard_reset() 
        tasmota.set_timer(500, / -> self.monitor_loop())
    end

    # --- NEU: DIE PAIRING LOGIK ---
    def pair_sequence()
        if (self.debug) print("BRY: Pairing Sequence Start (SET-SET-DOWN)") end
        self.last_act = tasmota.millis()
        self.is_sleeping = false
        self.publish_status("Pairing")
        
        try
            # 1. SET Impuls (P-Taste)
            self.pulse_raw(self.r_set)
            tasmota.delay(800) # Pause damit FB senden kann
            
            # 2. SET Impuls (P-Taste)
            self.pulse_raw(self.r_set)
            tasmota.delay(800)
            
            # 3. DOWN Impuls (Abschluss)
            self.pulse_raw(self.r_down)
            
            if (self.debug) print("BRY: Pairing Sequence Done") end
            self.publish_status("Pair Done")
        except .. as e, m
            self.safe_state()
            print("BRY Error in Pair: ", m)
        end
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
        if (self.debug) print("BRY: Hard Reset - Sync to CH 1") end
        gpio.digital_write(self.pin_power, 1)
        tasmota.delay(4000)
        gpio.digital_write(self.pin_power, 0)
        tasmota.delay(2000)
        self.safe_state()
        self.current_chan = 1
        self.is_sleeping = true
        self.publish_status("Reset/Sleep")
    end

    def move_to_channel(target)
        if (target < 0 || target > self.max_chan) return end
        if (self.is_sleeping) self.keep_awake() end
        
        # Die Hardware-Basis für den Kreis (z.B. 16)
        var mod = self.remote_channels_total 
        
        try
            while (self.current_chan != target)
                # Differenz im Hardware-Kreis berechnen
                var diff = (target - self.current_chan + mod) % mod
                
                # Kürzester Weg: Wenn diff > halber Kreis, dann linksrum
                var go_forward = (diff <= mod / 2)

                var relay = go_forward ? self.r_right : self.r_left
                self.pulse_raw(relay)

                # Zähler-Update mit echtem Hardware-Rollover
                if (go_forward)
                    self.current_chan = (self.current_chan + 1) % mod
                else
                    self.current_chan = (self.current_chan - 1 + mod) % mod
                end

                self.last_act = tasmota.millis()
                if (self.current_chan != target) 
                    tasmota.delay(self.delay_chan) 
                end
            end
            self.safe_state()
        except .. as e, m
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
        except .. as e, m
            self.safe_state()
        end
    end

    def pulse_raw(idx)
        import gpio
        try
            gpio.digital_write(self.pins[idx], 0)
            tasmota.delay(self.pulse_ms)
            gpio.digital_write(self.pins[idx], 1)
        except .. as e, m
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
            if (gpio.digital_read(p) == 0)
                if (now - self.last_act > 10000)
                    self.safe_state()
                    print(f"BRY: WATCHDOG TRIPPED - Pin {p} HIGH")
                end
            end
        end
        if (!self.is_sleeping && (now - self.last_act > 8500))
            self.is_sleeping = true
            self.publish_status("Sleep")
        end
        tasmota.set_timer(500, / -> self.monitor_loop())
    end

def add_to_queue(q_type, payload)
        # VERRIEGELUNG: Wenn das Script gerade klickt oder fährt, 
        # wird absolut jeder neue Befehl ignoriert.
        if (self.working)
            if (self.debug) print("BRY: Ignoriere Befehl - System BUSY") end
            return 
        end

        var val = payload
        if (q_type == "chan")
            val = int(payload)
            # Wenn wir schon auf dem Kanal sind, gar nicht erst anfangen
            if (val == self.current_chan) 
                tasmota.resp_cmnd_done()
                return 
            end
        end

        # Jetzt sperren und ausführen
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
        end
    end

    def json_append()
        var msg = ",\"Shutter\":{\"State\":\"" + self.status_text + "\",\"Channel\":" + str(self.current_chan) + "}"
        tasmota.response_append(msg)
    end
end
var shutter = ShutterController()