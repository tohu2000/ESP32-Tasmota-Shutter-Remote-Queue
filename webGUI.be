    import webserver

    class ShutterWebUI : Driver

        def init()
            tasmota.add_driver(self)
        end

        def web_add_main_button()
            if !global.shutter return end
            
            var h = "<hr><div style='font-weight:bold;margin-bottom:4px;'>Shutter Digital Twin</div>"
            
            # 1. ERROR DISPLAY (Mit 'find' statt 'contains')
            if shutter.fail_safe_active || shutter.needs_reset
                var is_critical = (shutter.status_text.find("FAILSAFE") != nil && shutter.status_text.find("User") == nil)
                var err_color = is_critical ? "#cc0000" : "#d4a017" 
                h += "<div style='background-color:" + err_color + ";color:white;padding:10px;text-align:center;font-weight:bold;border-radius:4px;margin-bottom:10px;'>"
                h += "SYSTEM MESSAGE: " + shutter.status_text + "<br>"
                h += "<button style='margin-top:8px;background-color:white;color:black;border:none;padding:8px 16px;font-weight:bold;border-radius:4px;cursor:pointer;' onclick='la(\"&sh_reset=1\");'>RESET & SYNC</button>"
                h += "</div>"
            end

            # 2. MOVEMENT BUTTONS
            h += "<div style='margin-bottom:8px;'>"
            h += "<button style='display:block;width:100%;margin:4px 0;height:40px;' onclick='la(\"&sh_go=up\");'>UP</button>"
            h += "<button style='display:block;width:100%;margin:4px 0;height:40px;' onclick='la(\"&sh_go=stop\");'>STOP</button>"
            h += "<button style='display:block;width:100%;margin:4px 0;height:40px;' onclick='la(\"&sh_go=down\");'>DOWN</button>"
            
            # 3. SHADE MODE (2.5s Logik wird durch 'shade' String im Script getriggert)
            h += "<button style='display:block;width:100%;margin:4px 0;background-color:#d4a017;color:white;height:40px;font-weight:bold;border:none;border-radius:4px;cursor:pointer;' onclick='la(\"&sh_go=shade\");'>Shade Mode</button>"
            
            # 4. CHANNEL 00
            h += "<button style='display:block;width:100%;margin:4px 0;height:40px;font-weight:bold;border-radius:4px;cursor:pointer;border:1px solid #ccc;' onclick='la(\"&sh_ch=0\");'>Channel 00 (All)</button>"
            h += "</div>"
            
            # 5. CHANNEL GRID
            h += "<div style='margin-bottom:4px;font-size:90%;font-weight:bold;'>Individual Channels</div>"
            h += "<div style='text-align:center;max-width:280px;margin:0 auto;'>"
            webserver.content_send(h)

            for i:1..15
                var label = (i < 10 ? "0" + str(i) : str(i))
                var btn = "<button style='width:auto;min-width:50px;margin:2px;padding:8px 4px;font-size:14px;border:1px solid #ccc;' onclick='la(\"&sh_ch=" + str(i) + "\");'>" + label + "</button>"
                webserver.content_send(btn)
            end
            
            webserver.content_send("</div>")
        end

        def web_sensor()
            if !global.shutter return end
            
            if webserver.has_arg("sh_go") shutter.add_to_queue("move", webserver.arg("sh_go")) end
            if webserver.has_arg("sh_ch") shutter.add_to_queue("chan", webserver.arg("sh_ch")) end
            if webserver.has_arg("sh_reset") shutter.remote_hard_reset() end
            
            var cur = shutter.current_chan
            var display_chan = (cur < 10 ? "0" + str(cur) : str(cur))
            
            webserver.content_send("{s}Active Channel{m}" + display_chan + "{e}")
            
            var st = shutter.status_text
            if (shutter.is_sleeping) st = shutter.msg["standby"] end
            webserver.content_send("{s}System Status{m}" + st + "{e}")
        end
    end

    var shutter_ui = ShutterWebUI()