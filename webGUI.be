import webserver
import string

class ShutterWebUI : Driver
    # Modul-Referenz statisch binden, um 'undeclared' Fehler zu vermeiden
    static var ws = webserver 

    def init()
        tasmota.add_driver(self)
    end

    def web_add_main_button()
        # Prüfen ob Logik-Instanz global vorhanden ist
        if !global.shutter return end
        var s = global.shutter
        
        var h = "<hr><div style='font-weight:bold;margin-bottom:4px;'>Shutter Digital Twin</div>"
        
        # 1. ERROR & FAILSAFE DISPLAY
        if s.fail_safe_active || s.needs_reset
            var is_critical = (s.status_text.find("FAILSAFE") != nil || s.status_text.find("Error") != nil)
            var err_color = is_critical ? "#cc0000" : "#d4a017" 
            
            h += "<div style='background-color:" + err_color + ";color:white;padding:10px;text-align:center;font-weight:bold;border-radius:4px;margin-bottom:10px;'>"
            h += "SYSTEM MESSAGE: " + s.status_text + "<br>"
            h += "<button style='margin-top:8px;background-color:white;color:black;border:none;padding:8px 16px;font-weight:bold;border-radius:4px;cursor:pointer;' onclick='la(\"&sh_reset=1\");'>RESET & SYNC</button>"
            h += "</div>"
        end

        # 2. MOVEMENT BUTTONS
        h += "<div style='margin-bottom:8px;'>"
        h += "<button style='display:block;width:100%;margin:4px 0;height:40px;' onclick='la(\"&sh_go=up\");'>UP</button>"
        h += "<button style='display:block;width:100%;margin:4px 0;height:40px;' onclick='la(\"&sh_go=stop\");'>STOP / WAKE</button>"
        h += "<button style='display:block;width:100%;margin:4px 0;height:40px;' onclick='la(\"&sh_go=down\");'>DOWN</button>"
        
        # 3. SHADE MODE
        h += "<button style='display:block;width:100%;margin:4px 0;background-color:#d4a017;color:white;height:40px;font-weight:bold;border:none;border-radius:4px;cursor:pointer;' onclick='la(\"&sh_go=shade\");'>Shade Mode</button>"
        h += "</div>"
        
        self.ws.content_send(h)
        h = "" # Puffer leeren

        # 4. CHANNEL GRID
        h += "<div style='margin-bottom:4px;font-size:90%;font-weight:bold;'>Individual Channels</div>"
        h += "<button style='display:block;width:100%;margin:4px 0;height:40px;font-weight:bold;border-radius:4px;cursor:pointer;border:1px solid #ccc;' onclick='la(\"&sh_ch=0\");'>Channel 00 (All)</button>"
        h += "<div style='text-align:center;max-width:280px;margin:0 auto;'>"
        
        for i:1..15
            var label = (i < 10 ? "0" + str(i) : str(i))
            h += "<button style='width:auto;min-width:50px;margin:2px;padding:8px 4px;font-size:14px;border:1px solid #ccc;' onclick='la(\"&sh_ch=" + str(i) + "\");'>" + label + "</button>"
            if (i % 5 == 0) h += "<br>" end
        end
        
        h += "</div>"
        self.ws.content_send(h)
    end

    def web_sensor()
        if !global.shutter return end
        var s = global.shutter

        # Commands verarbeiten
        if self.ws.has_arg("sh_go") s.add_to_queue("move", self.ws.arg("sh_go")) end
        if self.ws.has_arg("sh_ch") s.add_to_queue("chan", self.ws.arg("sh_ch")) end
        if self.ws.has_arg("sh_reset") s.remote_hard_reset() end
        
        # Status-Zeilen in der Tasmota Hauptseite
        var cur = s.current_chan
        var display_chan = (cur < 10 ? "0" + str(cur) : str(cur))
        self.ws.content_send("{s}Active Channel{m}" + display_chan + "{e}")
        
        var st = s.status_text
        if (s.is_sleeping && !s.fail_safe_active) st = s.msg["standby"] end
        self.ws.content_send("{s}System Status{m}" + st + "{e}")
    end
end

# Instanz erzeugen
var shutter_ui = ShutterWebUI()