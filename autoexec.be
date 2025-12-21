# autoexec.be - TasmotaSCMini Final Fix

# 1. Radikale Bereinigung
# Da get_driver nicht geht, nutzen wir den Tasmota-Befehl zum Entladen
tasmota.cmd("BerryUninstall") 

# 2. Kurze Verzögerung für den Speicher-Cleanup
tasmota.set_timer(200, def ()
    print("SYSTEM: Bereinigung abgeschlossen. Lade Module...")
    
    # 3. Module direkt laden (einfach und stabil)
    load('shutter.be')
    print("SYSTEM: shutter.be geladen")
    
    load('webGUI.be')
    print("SYSTEM: webGUI.be geladen")
    
    print("SYSTEM: TasmotaSCMini erfolgreich gestartet.")
end)