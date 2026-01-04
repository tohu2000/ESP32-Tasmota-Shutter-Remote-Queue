import string
import gpio

# =============================================================================
# ShutterController Class
# A Tasmota Berry driver to control multi-channel RF shutter remotes 
# via GPIO (Open Drain) and maintain channel synchronization.
#
# Written by tohu2000 and gemini in Dec 2025
# Visit: https://github.com/tohu2000/ESP32-Tasmota-Shutter-Remote-Queue
#
#                                       Release 1.0 / 4th JAN 2026
#
# =============================================================================
class ShutterController : Driver
    # Internal state and configuration variables
    var max_chan, current_chan, queue, working, remote_channels_total
    var pins, pin_power, pin_led, pin_map
    var r_up, r_down, r_left, r_right, r_stop, r_set
    var pulse_high_ms, pulse_low_ms, chan_low_ms, post_delay, delay_shade, wake_up, chan_high_ms
    var is_sleeping, last_act, status_text, last_published_s, last_published_chan
    var fail_safe_active, pulse_count, last_rate_check
    var press_start_time, active_pin, manual_interaction_time, needs_reset
    var boot_time
    var debounce_ms, desync_ms, poll_active, poll_idle
    var execute_auto_reset, fb_timeout
    var mqtt_topic
    var msg 
    var ignore_echo
    var attention
    var publish
    var log

    # -------------------------------------------------------------------------
    # Driver Initialization
    # -------------------------------------------------------------------------
    def init()
        self.mqtt_topic = tasmota.cmd("Topic")['Topic']
        self.boot_time = tasmota.millis()
        self.ignore_echo = false

        # Polling of user activities (consider 330 Ohm resistors to protect GPIOs)
        self.debounce_ms = 5        # Debouncing / Entprellungszeit
        self.desync_ms = 400        # Threshold to detect manual channel cycling on remote
        self.poll_active = 10       # Fast polling interval when active (Sleep 0)
        self.poll_idle = 100        # Slow polling interval when idle (Sleep 50)
        self.fb_timeout = 7000      # Time before remote enters standby
 
        # Script timings acting on the remote hardware
        self.pulse_high_ms = 350    # Standard pulse duration (High)
        self.pulse_low_ms = 150     # Standard pulse duration (Low)
        self.chan_high_ms = 150     # Channel step pulse duration (High)
        self.chan_low_ms = 100      # Delay between channel steps
        self.post_delay = 300       # Pause after command execution
        self.delay_shade = 4500     # Duration for "Shade" (long press)
        self.wake_up = 300          # Duration for wake-up pulse
        self.attention = false      # CPU/Power management flag

        # Debugging flags
        self.publish = true         # Enable/Disable MQTT status updates
        self.log = true             # Enable/Disable console debugging
        
        # Localized status and error messages
        self.msg = {
            "boot":    "Safe Boot",
            "sync":    "Weekly Hard Reset Done",
            "reset":   "Hard Reset",
            "stuck":   "FAILSAFE (Stuck Pin)",
            "user":    "FAILSAFE (User Intervention)",
            "standby": "Standby",
            "manual":  "SYNC REQ: Manual Override",
            "ready":   "Idle",
            "excess":  "FAILSAFE (Excessive Pulsing)",
            "err_gpio": "GPIO Error: ",
            "err_move": "Movement Error",
            "unlocked": "Unlocked - Channel %02d",
            "chan_fmt": "Channel %02d",
            "active_fmt": "Active: Channel %02d",
            "step_fmt": "Stepping to %02d...",
            "exec_fmt": "Executing %s",
            "err_queue": "Emergency Queue Clear - Too many commands!"
        }
        
        # Hardware Configuration (review your remote details)
        self.execute_auto_reset = false         # In case of failsafe conditions detected, if true hardreset
        self.remote_channels_total = 16         # total number of remote states (00 - 15)
        self.max_chan = 15                      # You can limit number of channels if not used eg (00 - 06)
        self.pins = [17, 16, 27, 25, 26, 33]    # Up, Down, Left, Right, Stop, Set
        self.pin_power = 18                     # Remote battery/power supply control
        self.pin_led = 2                        # Status LED
        self.status_text = self.msg["boot"]
        self.fail_safe_active = false
        self.last_published_s = ""
        self.last_published_chan = -1

        tasmota.cmd("Sleep 50") # Default energy saving mode
        
        # Configure GPIOs as Open Drain to simulate button presses
        for p:self.pins 
            gpio.pin_mode(p, gpio.OUTPUT_OPEN_DRAIN)
            gpio.digital_write(p, gpio.HIGH)
        end
        
        gpio.pin_mode(self.pin_power, gpio.OUTPUT)
        gpio.pin_mode(self.pin_led, gpio.OUTPUT)
        
        # Mapping indices to functions
        self.r_up=0; self.r_down=1; self.r_left=2; self.r_right=3; self.r_stop=4; self.r_set=5
        self.pin_map = {self.pins[self.r_up]:"move", self.pins[self.r_down]:"move", self.pins[self.r_left]:"chan", self.pins[self.r_right]:"chan", self.pins[self.r_stop]:"stop"}

        self.last_act = tasmota.millis(); self.queue = []; self.working = false
        self.current_chan = 1; self.is_sleeping = true; self.press_start_time = 0; self.manual_interaction_time = 0; self.needs_reset = false
        self.pulse_count = 0; self.last_rate_check = tasmota.millis()

        # Registering Tasmota Commands
        tasmota.add_cmd('chan', / cmd, idx, payload -> self.add_to_queue("chan", payload))
        tasmota.add_cmd('goup', / -> self.add_to_queue("move", "up"))
        tasmota.add_cmd('godown', / -> self.add_to_queue("move", "down"))
        tasmota.add_cmd('stop', / -> self.add_to_queue("move", "stop"))
        tasmota.add_cmd('goshade', / -> self.add_to_queue("move", "shade"))
        tasmota.add_cmd('hardreset', / -> self.remote_hard_reset())
        tasmota.add_cmd('chanandgo', / cmd, idx, payload -> self.full_command(payload))
        tasmota.add_cmd('unlock', / cmd, idx, payload -> self.unlock(payload))
        
        # Weekly maintenance sync to prevent drift
        tasmota.add_cron("0 0 3 * * 0", / -> self.weekly_sync())
        
        tasmota.add_driver(self)
        self.remote_hard_reset()
        tasmota.set_timer(self.poll_idle, / -> self.monitor_loop()) # Main monitoring loop
    end

    # Scheduled reset to channel 1
    def weekly_sync()
        var saved_chan = self.current_chan
        self.publish_status(self.msg["sync"])
        self.remote_hard_reset()
        if (saved_chan != 1) 
            tasmota.set_timer(10000, / -> self.add_to_queue("chan", str(saved_chan))) 
        end
    end

    # Power cycle the remote and reset software state
    def remote_hard_reset()
        self.fail_safe_active = false
        self.pulse_count = 0
        self.working = false
        self.queue = []
        
        gpio.digital_write(self.pin_power, 1) # Cut power (assuming PNP or P-MOSFET)
        gpio.digital_write(self.pin_led, 1)
        tasmota.delay(1000)
        gpio.digital_write(self.pin_power, 0) # Restore power
        tasmota.delay(200)
        gpio.digital_write(self.pin_led, 0)

        self.current_chan = 1
        self.needs_reset = false
        self.manual_interaction_time = 0
        self.is_sleeping = false
        self.last_act = tasmota.millis()
        
        self.publish_status(self.msg["reset"])
        tasmota.resp_cmnd_done()
    end

    # Main monitoring loop for manual button presses and state management
    def monitor_loop()
        var now = tasmota.millis()
        
        # Wait for system stability after boot
        if (now - self.boot_time < 10000) 
            tasmota.set_timer(100, / -> self.monitor_loop())
            return 
        end

        # Monitor GPIOs for manual user interaction with the remote
        if (!self.working && !self.fail_safe_active)
            var any_pressed = -1
            for p:self.pins 
                if (gpio.digital_read(p) == 0) any_pressed = p; break end 
            end
            
            if (any_pressed != -1)
                # User is pressing a button
                if !(self.attention)
                    tasmota.cmd("Sleep 0") 
                    if (self.log)
                        tasmota.log("POWER!!", 2)
                    end                  
                    self.attention = true
                end

                self.last_act = tasmota.millis()
                gpio.digital_write(self.pin_led, 1)
                if (self.log)
                    tasmota.log("KEYPRESS", 2)
                end                    
                
                if (self.press_start_time == 0) 
                    self.press_start_time = now
                    self.active_pin = any_pressed 
                end
                
                var cur_dur = now - self.press_start_time
                # Detect if user is cycling channels manually
                if (cur_dur > self.desync_ms && !self.needs_reset) 
                    self.needs_reset = true
                    if (self.log) 
                        tasmota.log("CHAN DESYNC", 2) 
                    end
                end
                
                # Stuck button failsafe
                if (cur_dur > 10000)
                    self.fail_safe_active = true
                    self.publish_status(self.msg["stuck"])
                end
            else
                # --- BUTTON RELEASED ---
                if (self.press_start_time > 0)
                    var duration = now - self.press_start_time
                    var p_type = self.pin_map.find(self.active_pin)
                    
                    self.queue = [] # Clear queue on manual intervention
                    if (self.is_sleeping)
                        if (self.log) tasmota.log(string.format("KEYPRESSED %s - WOKE UP", p_type), 2) end 
                    else
                        if (self.log) tasmota.log(string.format("KEYPRESSED %s ", p_type), 2) end 
                    end

                    # Update internal channel counter if manual press was short
                    if (p_type == "chan" && duration <= self.desync_ms) 
                        if (self.is_sleeping)
                            if (self.log)  tasmota.log("CHAN WOKE UP", 2)   end                        
                        else
                            var m = self.remote_channels_total
                            var i = self.current_chan
                            if (self.active_pin == self.pins[self.r_right]) 
                                self.current_chan = (self.current_chan + 1) % m
                            elif (self.active_pin == self.pins[self.r_left]) 
                                self.current_chan = (self.current_chan - 1 + m) % m 
                            end
                            if (self.log)  tasmota.log( string.format("CHANKEY from %02d to %02d EXECUTED", i, self.current_chan), 2) end
                        end
                    end
                    
                    self.is_sleeping = false
                    self.press_start_time = 0
                    gpio.digital_write(self.pin_led, 0)

                    if (self.needs_reset)
                        self.publish_status(self.msg["user"])
                        self.fail_safe_active = true
                    else
                        self.publish_status(string.format(self.msg["chan_fmt"], self.current_chan))
                    end
                end
            end
        end

        # Handle Remote Standby / Sleep
        if (now - self.last_act > self.fb_timeout && !self.is_sleeping) 
            self.is_sleeping = true
            if (self.log)  tasmota.log("IS SLEEPING TRUE", 2) end
            self.attention = false
            tasmota.cmd("Sleep 50")
            self.publish_status(self.msg["standby"]) 
        end

        # Handle Manual Override cooldown
        if (self.manual_interaction_time > 0 && (now - self.manual_interaction_time > 5000))
            self.manual_interaction_time = 0 
            if (self.needs_reset)
                if (self.execute_auto_reset) self.remote_hard_reset()
                else self.publish_status(self.msg["manual"]) end
            else
                self.publish_status(self.msg["ready"]) 
            end
        end

        # Error/State LED Signaling
        if (self.fail_safe_active || self.needs_reset) 
            var flash_rate = self.needs_reset ? 400 : 1500
            gpio.digital_write(self.pin_led, (now / flash_rate) % 2) 
        else 
            gpio.digital_write(self.pin_led, 0) 
        end
        
        var next_p = self.is_sleeping ? self.poll_idle : self.poll_active
        tasmota.set_timer(next_p, / -> self.monitor_loop())
    end

    # Helper for simple pulses
    def pulse_raw(idx)
        self.pulse_raw_raw(idx, self.pulse_high_ms, self.pulse_low_ms)
    end

    # Low-level GPIO pulsing with timing and rate limiting
    def pulse_raw_raw(idx, high, low)
        if (self.fail_safe_active) return end
        var now = tasmota.millis()
        if (now - self.last_rate_check > 60000) 
            self.pulse_count = 0
            self.last_rate_check = now 
        end
        self.pulse_count += 1
        
        # Anti-flood protection
        if (self.pulse_count > 80) 
            self.fail_safe_active = true
            self.publish_status(self.msg["excess"])
            return 
        end
        self.last_act = tasmota.millis()
        self.ignore_echo = true
        try 
            gpio.pin_mode(self.pins[idx], gpio.OUTPUT_OPEN_DRAIN)
            gpio.digital_write(self.pins[idx], 0) # Pulled to GND
            tasmota.delay(high)
            gpio.digital_write(self.pins[idx], 1) # Released (Floating/High)
            tasmota.delay(low)
        except .. as e
            self.fail_safe_active = true
            self.publish_status(self.msg["err_gpio"] + str(e))
        end 
        self.ignore_echo = false
    end

    # Logical channel switching with distance optimization
    def move_to_channel(t)
        var target = int(t)
        if (target < 0 || target > self.max_chan) return end
        self.working = true

        if (target == self.current_chan) 
            self.publish_status(string.format(self.msg["active_fmt"], self.current_chan))
            return 
        end
        
        # Wake up remote if in standby
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
        
        self.publish_status(string.format(self.msg["step_fmt"], target))
        try
            for i: 1..k
                self.pulse_raw_raw(r, self.chan_high_ms, self.chan_high_ms)
                self.current_chan = (self.current_chan + (f ? 1 : m - 1)) % m
                if (i < k) tasmota.delay(self.chan_low_ms) end
            end
            self.publish_status(string.format(self.msg["active_fmt"], self.current_chan))
        except .. as e
            self.working = false
            self.publish_status(self.msg["err_move"])
        end
    end

    # Execution of movement commands (Up, Down, Stop, Shade)
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
            self.pulse_raw_raw(self.r_stop, self.delay_shade, self.pulse_low_ms)
        else
            var r = (c == "up") ? self.r_up : (c == "down" ? self.r_down : self.r_stop)
            self.publish_status(string.format(self.msg["exec_fmt"], string.toupper(c)))
            self.pulse_raw(r)
        end
    end

    # Queue management for serial command execution
    def add_to_queue(q, p)
        if (self.fail_safe_active || self.manual_interaction_time > 0) 
            tasmota.resp_cmnd_error()
            return
        end
        if (size(self.queue) >= 20)
            if (self.log)  tasmota.log(self.msg["err_queue"], 2) end
            self.queue = []
            self.working = false
            return 
        end
        self.queue.push([q, p])
        if (!self.working) self.process_queue() end
        tasmota.resp_cmnd("{\"Shutter\":\"Queued\"}")
    end

    # Sequential processor for the command queue
    def process_queue()
        if (size(self.queue) == 0) 
            self.working = false
            if (!self.is_sleeping) self.publish_status(self.msg["ready"]) end
            return 
        end
        
        self.working = true
        var item = self.queue.pop(0)
        var cmd_type = item[0]
        var payload = item[1]

        try
            if (cmd_type == "chan") 
                self.move_to_channel(payload)
                tasmota.set_timer(self.post_delay, / -> self.process_queue())
            
            elif (cmd_type == "move") 
                self.do_move(payload) 
                tasmota.set_timer(self.post_delay, / -> self.process_queue())
            end
        except .. as e
            self.working = false 
            if (self.log)  tasmota.log("SHUTTER: Logik-Fehler in Queue: " + str(e), 2) end
        end
    end

    # MQTT status publishing logic
    def publish_status(s)
        if (!self.publish) return end
        var s_str = str(s)
        if (s_str == self.last_published_s && self.current_chan == self.last_published_chan) return end
        
        if (!self.fail_safe_active )
            self.status_text = s_str
            self.last_published_s = s_str
            self.last_published_chan = self.current_chan
        end
        if (self.mqtt_topic != nil) 
            tasmota.publish("tele/" + self.mqtt_topic + "/SENSOR", self.get_json_status(), false) 
        end
    end

    # JSON formatting for status payload
    def get_json_status()
        var fs = self.fail_safe_active ? "true" : "false"
        return string.format("{\"Shutter\":{\"State\":\"%s\",\"Channel\":%d,\"Failsafe\":%s}}", self.status_text, self.current_chan, fs)
    end

    # Reset failsafe state and manually set current channel
    def unlock(chan)
        self.fail_safe_active = false
        self.needs_reset = false
        self.pulse_count = 0
        self.current_chan = int(chan)
        self.manual_interaction_time = 0
        self.publish_status(string.format(self.msg["unlocked"], self.current_chan))
        tasmota.resp_cmnd_done()
    end

    # Helper function to remove whitespace from command payloads
    def manual_trim(s)
        var res = ""
        var st = str(s)
        for i:0..size(st)-1
            var char = st[i]
            if (char != " " && char != "\t" && char != "\r" && char != "\n")
                res += char
            end
        end
        return res
    end

    # Handles combined commands like 'chanandgo 5,up'
    def full_command(payload)
        var args = string.split(payload, ",")
        if (size(args) >= 2)
            var chan = self.manual_trim(args[0])
            var move = self.manual_trim(args[1])
            
            self.add_to_queue("chan", chan)
            self.add_to_queue("move", move)
            tasmota.resp_cmnd(string.format("{\"Shutter\":\"Queued %s on %s\"}", move, chan))
        else
            tasmota.resp_cmnd_error()
        end
    end
end

# Instantiate the controller
global.shutter = ShutterController()