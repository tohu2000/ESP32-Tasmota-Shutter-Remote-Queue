import string
import gpio

class ShutterController : Driver
    var max_chan, current_chan, queue, working, remote_channels_total
    var pins, pin_power, pin_led, pin_map
    var r_up, r_down, r_left, r_right, r_stop, r_set
    var pulse_ms, delay_chan, delay_move, delay_shade, wake_up, move_chan_ms
    var is_sleeping, last_act, status_text, last_published_s, last_published_chan
    var fail_safe_active, pulse_count, last_rate_check
    var press_start_time, active_pin, manual_interaction_time, needs_reset, user_intervention_time
    var boot_time
    var debounce_ms, desync_ms, poll_active, poll_idle
    var execute_auto_reset, fb_timeout
    var mqtt_topic
    var msg 

    def init()
        self.mqtt_topic = tasmota.cmd("Topic")['Topic']
        self.boot_time = tasmota.millis()
        self.debounce_ms = 5      
        self.desync_ms = 200      
        self.poll_active = 5      
        self.poll_idle = 200    
        self.fb_timeout = 7000
        self.user_intervention_time = 5000 #A DEPP is acting on the remote - no activity for this time thereafter

        self.pulse_ms = 250     #Standard pulse time
        self.move_chan_ms = 150 #Channel change pulse time
        self.delay_chan = 125   #Pause inbetween channel moves
        self.delay_move = 800   #Pause after chanel reached
        self.delay_shade = 4500 #Shade command
        self.wake_up = 300      #Wake up (stopp)
        
        
        self.msg = {
            "boot":    "Safe Boot",
            "sync":    "Weekly Hard Reset Done",
            "reset":   "Hard Reset",
            "stuck":   "FAILSAFE (Stuck Pin)",
            "user":    "FAILSAFE (User Intervention)",
            "standby": "Sleep",
            "manual":  "SYNC REQ: Manual Override",
            "ready":   "Idle",
            "excess":  "FAILSAFE (Excessive Pulsing)",
            "err_gpio": "GPIO Error: ",
            "err_move": "Movement Error",
            "unlocked": "Unlocked - Channel %02d",
            "chan_fmt": "Channel %02d",
            "active_fmt": "Active: Channel %02d",
            "step_fmt": "Stepping to %02d...",
            "exec_fmt": "Executing %s"
        }
        
        self.execute_auto_reset = false 
        self.remote_channels_total = 16 
        self.max_chan = 15
        self.pins = [17, 16, 27, 25, 26, 33] 
        self.pin_power = 18              
        self.pin_led = 2
        self.status_text = self.msg["boot"]
        self.fail_safe_active = false
        self.last_published_s = ""
        self.last_published_chan = -1

        tasmota.cmd("Sleep 50")
        
        for p:self.pins 
            gpio.pin_mode(p, gpio.OUTPUT_OPEN_DRAIN)
            gpio.digital_write(p, gpio.HIGH)
        end
        
        gpio.pin_mode(self.pin_power, gpio.OUTPUT)
        gpio.pin_mode(self.pin_led, gpio.OUTPUT)
        
        self.r_up=0; self.r_down=1; self.r_left=2; self.r_right=3; self.r_stop=4; self.r_set=5
        self.pin_map = {self.pins[self.r_up]:"move", self.pins[self.r_down]:"move", self.pins[self.r_left]:"chan", self.pins[self.r_right]:"chan", self.pins[self.r_stop]:"stop"}

        self.last_act = tasmota.millis(); self.queue = []; self.working = false
        self.current_chan = 1; self.is_sleeping = true; self.press_start_time = 0; self.manual_interaction_time = 0; self.needs_reset = false
        self.pulse_count = 0; self.last_rate_check = tasmota.millis()

        tasmota.add_cmd('chan', / cmd, idx, payload -> self.add_to_queue("chan", payload))
        tasmota.add_cmd('goup', / -> self.add_to_queue("move", "up"))
        tasmota.add_cmd('godown', / -> self.add_to_queue("move", "down"))
        tasmota.add_cmd('stop', / -> self.add_to_queue("move", "stop"))
        tasmota.add_cmd('goshade', / -> self.add_to_queue("move", "shade"))
        tasmota.add_cmd('hardreset', / -> self.remote_hard_reset())
        tasmota.add_cmd('move', / cmd, idx, payload -> self.unlock(payload))
        tasmota.add_cmd('unlock', / cmd, idx, payload -> self.unlock(payload))
        
        tasmota.add_cron("0 0 3 * * 0", / -> self.weekly_sync())
        
        tasmota.add_driver(self)
        self.remote_hard_reset()
        tasmota.set_timer(self.poll_idle, / -> self.monitor_loop()) #Understand the magic!
    end

    def weekly_sync()
        var saved_chan = self.current_chan
        self.publish_status(self.msg["sync"])
        self.remote_hard_reset()
        if (saved_chan != 1) 
            tasmota.set_timer(10000, / -> self.add_to_queue("chan", str(saved_chan))) 
        end
    end

    def remote_hard_reset()
        self.fail_safe_active = false
        self.pulse_count = 0
        self.working = false
        self.queue = []
        
        gpio.digital_write(self.pin_power, 1)
        gpio.digital_write(self.pin_led, 1)
        tasmota.delay(4000)
        gpio.digital_write(self.pin_power, 0)
        gpio.digital_write(self.pin_led, 0)
        
        self.current_chan = 1
        self.needs_reset = false
        self.manual_interaction_time = 0
        self.is_sleeping = false
        self.last_act = tasmota.millis()
        
        self.publish_status(self.msg["reset"])
        tasmota.resp_cmnd_done()
    end

    def monitor_loop()
        var now = tasmota.millis()
        
        # 1. Boot-Schutz
        if (now - self.boot_time < 10000) 
            tasmota.set_timer(100, / -> self.monitor_loop())
            return 
        end

        # 2. Tasten-Scanner (Nur wenn nicht gerade eine Automatik läuft)
        if (!self.working && !self.fail_safe_active)
            var any_pressed = -1
            for p:self.pins 
                if (gpio.digital_read(p) == 0) any_pressed = p; break end 
            end
            
            if (any_pressed != -1)
                # --- TASTE WIRD GEDRÜCKT ---
                if (self.press_start_time == 0) 
                    self.press_start_time = now
                    self.active_pin = any_pressed 
                end
                
                var cur_dur = now - self.press_start_time
                if (cur_dur > self.desync_ms && !self.needs_reset) self.needs_reset = true end
                
                if (cur_dur > 10000)
                    self.fail_safe_active = true
                    self.publish_status(self.msg["stuck"])
                end
            else
                # --- TASTE WURDE LOSGELASSEN ---
                if (self.press_start_time > 0)
                    var duration = now - self.press_start_time
                    var p_type = self.pin_map.find(self.active_pin)
                    
                    # Manuelle Interaktion registrieren
                    self.manual_interaction_time = now
                    self.last_act = now
                    self.queue = [] # Vernünftigerweise: Queue löschen bei Handbetrieb

                    if (p_type == "chan" && duration <= self.desync_ms) 
                        if (self.is_sleeping)
                            self.is_sleeping = false
                            tasmota.log("SHUTTER: Manuelles Aufwachen", 2)
                        else
                            var m = self.remote_channels_total
                            if (self.active_pin == self.pins[self.r_right]) 
                                self.current_chan = (self.current_chan + 1) % m
                            elif (self.active_pin == self.pins[self.r_left]) 
                                self.current_chan = (self.current_chan - 1 + m) % m 
                            end
                            tasmota.log("SHUTTER: Kanal händisch gewechselt", 2)
                        end
                    else
                        # Fahrbefehl oder Stop weckt auch auf
                        self.is_sleeping = false
                    end

                    self.press_start_time = 0
                    
                    # Status senden
                    if (self.needs_reset)
                        self.publish_status(self.msg["user"])
                    else
                        self.publish_status(string.format(self.msg["chan_fmt"], self.current_chan))
                    end
                end
            end
        end

        # 3. Zeit-Logik (Sleep & Sperre)
        # Check ob Remote schlafen gehen soll
        if (now - self.last_act > self.fb_timeout && !self.is_sleeping) 
            self.is_sleeping = true
            self.publish_status(self.msg["standby"]) 
        end

        # Check ob manuelle Sperre (5 Sek) abgelaufen ist
        if (self.manual_interaction_time > 0 && (now - self.manual_interaction_time > 5000))
            self.manual_interaction_time = 0 # Sperre aufheben
            if (self.needs_reset)
                if (self.execute_auto_reset) self.remote_hard_reset()
                else self.publish_status(self.msg["manual"]) end
            else
                self.publish_status(self.msg["ready"]) 
            end
        end

        # 4. LED-Feedback
        if (self.fail_safe_active || self.needs_reset) 
            var flash_rate = self.needs_reset ? 400 : 1500
            gpio.digital_write(self.pin_led, (now / flash_rate) % 2) 
        else 
            gpio.digital_write(self.pin_led, 0) 
        end
        
        # 5. Nächster Loop
        var next_p = self.is_sleeping ? self.poll_idle : self.poll_active
        tasmota.set_timer(next_p, / -> self.monitor_loop())
    end

    def pulse_raw(idx)
        self.pulse_raw_raw(idx, self.pulse_ms)
    end

    def pulse_raw_raw(idx, dur)
        if (self.fail_safe_active) return end
        var now = tasmota.millis()
        if (now - self.last_rate_check > 60000) 
            self.pulse_count = 0
            self.last_rate_check = now 
        end
        self.pulse_count += 1
        
        if (self.pulse_count > 80) 
            self.fail_safe_active = true
            self.publish_status(self.msg["excess"])
            return 
        end
        self.last_act = tasmota.millis()
        try 
            gpio.pin_mode(self.pins[idx], gpio.OUTPUT_OPEN_DRAIN)
            gpio.digital_write(self.pins[idx], 0)
            tasmota.delay(dur)
            gpio.digital_write(self.pins[idx], 1)
        except .. as e
            self.fail_safe_active = true
            self.publish_status(self.msg["err_gpio"] + str(e))
        end 
    end

    def move_to_channel(t)
        var target = int(t)
        if (target < 0 || target > self.max_chan) return end
        self.working = true

        if (target == self.current_chan) 
            self.publish_status(string.format(self.msg["active_fmt"], self.current_chan))
            return 
        end
        
        if (self.is_sleeping) 
            self.pulse_raw(self.r_stop)
            tasmota.delay(self.wake_up)
            self.is_sleeping = false
        end
        
        var m = self.remote_channels_total
        var df = (target - self.current_chan + m) % m
        var dr = (self.current_chan - target + m) % m
        var f = (df <= dr)
        var k = f ? df : dr
        var r = f ? self.r_right : self.r_left
        
        try
            for i: 1..k
                self.publish_status(string.format(self.msg["step_fmt"], target))
                self.pulse_raw_raw(r, self.move_chan_ms)
                self.current_chan = (self.current_chan + (f ? 1 : m - 1)) % m
                if (i < k) tasmota.delay(self.delay_chan) end
            end
            self.publish_status(string.format(self.msg["active_fmt"], self.current_chan))
        except .. as e
            self.working = false
            self.publish_status(self.msg["err_move"])
        end
    end

    def do_move(cmd_str)
        if (self.fail_safe_active) return end
        var c = string.tolower(str(cmd_str))
        if (self.is_sleeping) 
            self.pulse_raw(self.r_stop)
            tasmota.delay(self.wake_up)
            self.is_sleeping = false 
        end
        
        if (c == "shade")
            self.publish_status(string.format(self.msg["exec_fmt"], string.toupper(c)))
            self.pulse_raw_raw(self.r_stop, self.delay_shade)
        else
            var r = (c == "up") ? self.r_up : (c == "down" ? self.r_down : self.r_stop)
            self.publish_status(string.format(self.msg["exec_fmt"], string.toupper(c)))
            self.pulse_raw(r)
        end
    end

    def add_to_queue(q, p)
        if (self.fail_safe_active || self.manual_interaction_time > 0) 
            #tasmota.resp_cmnd_error()
            return 
        end
        self.queue.push([q, p])
        if (!self.working) self.process_queue() end
        tasmota.resp_cmnd_done()
    end

    def process_queue()
        if (size(self.queue) == 0) 
            self.working = false
            if (!self.is_sleeping) self.publish_status(self.msg["ready"]) end
            return 
        end
        self.working = true
        try
            var item = self.queue.pop(0)
            if (item[0] == "chan") 
                self.move_to_channel(item[1])
            elif (item[0] == "move") 
                self.do_move(item[1]) 
            end
            tasmota.set_timer(100, / -> self.process_queue())
        except .. as e
            self.working = false 
        end
    end

    def publish_status(s)
        var s_str = str(s)
        if (s_str == self.last_published_s && self.current_chan == self.last_published_chan) return end
        self.status_text = s_str
        self.last_published_s = s_str
        self.last_published_chan = self.current_chan
        if (self.mqtt_topic != nil) 
            tasmota.publish("tele/" + self.mqtt_topic + "/SENSOR", self.get_json_status(), false) 
        end
    end

    def get_json_status()
        var fs = self.fail_safe_active ? "true" : "false"
        return string.format("{\"Shutter\":{\"State\":\"%s\",\"Channel\":%d,\"Failsafe\":%s}}", self.status_text, self.current_chan, fs)
    end

    def unlock(chan)
        self.fail_safe_active = false
        self.needs_reset = false
        self.pulse_count = 0
        self.current_chan = int(chan)
        self.manual_interaction_time = 0
        self.publish_status(string.format(self.msg["unlocked"], self.current_chan))
        tasmota.resp_cmnd_done()
    end
end

var shutter = ShutterController()