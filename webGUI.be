import webserver

class ShutterWebUI : Driver

    def init()
        tasmota.add_driver(self)
    end

    def web_add_main_button()
        # Haupt-Steuerung HTML
        var h = "<hr><div style='font-weight:bold;margin-bottom:4px;'>Shutter Control</div>"
        h += "<div style='margin-bottom:8px;'>"
        h += "<button style='display:block;width:100%;margin:4px 0;' onclick='la(\"&sh_go=up\");'>Move Up</button>"
        h += "<button style='display:block;width:100%;margin:4px 0;' onclick='la(\"&sh_go=stop\");'>Stop</button>"
        h += "<button style='display:block;width:100%;margin:4px 0;' onclick='la(\"&sh_go=down\");'>Move Down</button>"
        h += "<button style='display:block;width:100%;margin:8px 0;background-color:#d4a017;color:white;' onclick='la(\"&sh_go=shade\");'>Shade Mode</button>"
        h += "</div>"
        
        h += "<div style='margin-bottom:4px;font-size:90%;font-weight:bold;'>Channel Selection</div>"
        h += "<div style='text-align:center;max-width:280px;margin:0 auto;'>"
        webserver.content_send(h)

        # Kanäle dynamisch - kompakte Buttons ohne feste Breite
        var max = 6
        if global.shutter != nil && shutter.max_chan != nil
            max = shutter.max_chan
        end

        for i:1..max
            # Nutzt Auto-Breite und kleineres Padding für schmales Design
            var btn = "<button style='width:auto;min-width:45px;margin:2px;padding:4px 8px;font-size:14px;' onclick='la(\"&sh_ch=" + str(i) + "\");'>" + str(i) + "</button>"
            webserver.content_send(btn)
        end
        
        webserver.content_send("<script>setInterval(function(){if(!document.hidden){la('');}},2000);</script>")
        webserver.content_send("</div>")
    end

    def web_sensor()
        if global.shutter == nil return end
        
        # Eingaben verarbeiten
        if webserver.has_arg("sh_go") shutter.add_to_queue("move", webserver.arg("sh_go")) end
        if webserver.has_arg("sh_ch") shutter.add_to_queue("chan", webserver.arg("sh_ch")) end
        
        # Nur noch die stabilen Felder anzeigen
        var st = shutter.is_sleeping ? "Sleeping" : "Active"
        
        webserver.content_send("{s}Active Channel{m}" + str(shutter.current_chan) + "{e}")
        webserver.content_send("{s}Remote Status{m}" + st + "{e}")
    end
end

var shutter_ui = ShutterWebUI()