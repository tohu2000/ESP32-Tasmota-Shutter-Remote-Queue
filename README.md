# 433MHz Multi-Channel Shutter Bridge for Tasmota (Berry)

This project provides a professional-grade bridge between **Tasmota (ESP32)** and proprietary **433MHz RF** multi-channel shutter remotes. It uses the Berry scripting language to handle complex channel-stepping logic, hardware synchronization, and specialized functions like the "Shade" (intermediate) position.

## 📟 Hardware Compatibility
Designed for the common 5-button 433MHz remote family (OOK/FSK) found in the shutter industry.

> [!CAUTION]
> **Voltage Warning:** The original remote is designed for a **3V CR2340 lithium cell**. This project powers the RC PCB directly with **3.3V** from the ESP32. While most remote control ICs have tolerances that allow for this minor voltage increase, proceed at your own risk. **Ensure the 100µF Elko is present** to help regulate current spikes and protect the remote's MCU.


* **10-Channel LCD (Target Model)**: Displays channels `00` through `09`.
* **15-Channel LCD**: Displays channels `00` through `15`.
* **Channel 00 Note**: Channel 00 actuates all devices registered on the remote. The script excludes this feature to ensure only a single channel is operative.
* **Model Note**: For 5-channel LED variants, the script can be used as the channel handling is identical; with the LCD replaced by LEDs 1 to 5 for the channel and one for operations.

* Search for 'Funkhandsender PRIMERO' on the web for details

### 📸 Build Gallery
| Tasmota WebGUI (max_chan = 6) |
| :---: |
| <img src="tasmota_web_gui.jpg" width="50%"> |
| Home Assistant Dashoboard |
| <img src="home_assistant_dashboard.jpg" width="50%"> |

| Installed Hardware | Completed Build (Back) | 
| :---: | :---: | 
| <img src="rc_installed.jpg" width="40%"> | <img src="rc_closed_back_pack_neat.jpg" width="40%"> | 

| Component Wiring | PCB Detail |
| :---: | :---: |
| <img src="rc_open_wired.jpg" width="40%"> | <img src="rc_open_pcb_top_wired.jpg" width="40%"> |
| **Capacitor Mod** | **Final Assembly** |
| <img src="rc_open_elko_wired.jpg" width="40%"> | <img src="rc_closed_back_pack.jpg" width="40%"> |

## 🛠 Technical Implementation

### Open Drain (Open Gate) Parallel Wiring
The ESP32 is wired in parallel with the physical buttons of the remote. This is made possible by configuring the ESP32 GPIOs as **Output Open Drain**. In this state, the ESP32 only pulls the line to Ground (simulating a button press) or remains high-impedance (floating). 

### Synchronization & Manual Use
* **Hard Reset**: The ESP32 controls the remote's power (VCC). On boot, it performs a 4-second power cycle to force the remote back to its default starting channel.
* **Manual Parity**: Physical buttons remain functional thanks to the Open Drain configuration.

## ⛓️ Sequential Command Queuing

Because moving a specific shutter requires a sequence of pulses (Wake -> Step -> Move), the script uses a non-blocking FIFO queue.

| Step | Action | Description | Delay |
| :--- | :--- | :--- | :--- |
| 1 | **Wake-up** | Sends a `Stop` pulse to turn on the remote. | 800ms |
| 2 | **Step Right** | Pulse to move to the target channel. | 450ms |
| 3 | **Direction** | Sends the `Up/Down` pulse. | 250ms |

## 📐 Hardware Architecture

### Schematic (Direct Drive / High-Side Switching)
In this setup, GPIO 18 acts as the 3.3V power source for the remote. Driving the pin LOW cuts power to the device, allowing for a hard hardware reset.

```text
       ESP32 DEVKIT                433MHz REMOTE PCB
    ┌────────────────┐           ┌────────────────────┐
    │        GPIO 18 ├──────┬────┤ VCC (+)            │
    │                │     ┌┴┐   │                    │
    │                │  100uF│   │                    │
    │                │  (Elko)   │  [Buttons to GND]  │
    │                │     └┬┘   │                    │
    │            GND ├──────┴────┤ GND (-)            │
    │                │           └──────────┬─────────┘
    │        GPIO 13 ├──────────────────────┤ UP
    │        GPIO 12 ├──────────────────────┤ DOWN
    │        GPIO 14 ├──────────────────────┤ STOP
    │        GPIO 27 ├──────────────────────┤ CH (-)
    │        GPIO 26 ├──────────────────────┤ CH (+)
    └────────────────┘           
    (All Buttons: GPIO Open Drain | Power: Active-Low for Reset)
```

### ⚡ Technical Specifications
* **Power Management (GPIO 18)**: 
    * **LOW**: Power OFF (Reset State)
    * **HIGH**: Power ON (Operating State)
* **Buffer Capacitor**: A **100µF Electrolytic (Elko)** is wired across the remote's power input (VCC to GND). This is critical as the ESP32 GPIO must handle the instantaneous current surge when the 433MHz transmitter fires.
* **Control Logic**: All button GPIOs (12, 13, 14, 26, 27) are configured in **Open Drain** mode. They act as electronic switches that pull the remote's button pads to ground to trigger commands.
  
### ⚙️ Tasmota Initialization
Run these commands in the Tasmota Console to set up the pins before loading the Berry script:

```tasmota
// Configure Power Pin (Active-Low)
GpioConfig 18, 1    // Mode: Output
DigitalWrite 18, 0  // Default to ON

// Configure Button Pins (Mode 2: Open Drain)
GpioConfig 13, 2
GpioConfig 12, 2
GpioConfig 14, 2
GpioConfig 27, 2
GpioConfig 26, 2

// Global Settings
SetOption114 1  // Detach buttons from internal relays
SetOption1 1    // Disable multipress
```

### 🔄 Sync Logic (`shutter.be`)
Because the remote is powered by **GPIO 18**, we can force a "Hard Sync":
1. **Boot**: `gpio.digital_write(18, 0)` (Power OFF for 4 seconds).
2. **Ready**: `gpio.digital_write(18, 1)` (Power ON).
3. **Result**: The remote's MCU restarts at **Channel 01**. The Berry script sets `current_channel = 1`. We now have a guaranteed starting point without feedback.

### ⚡ Power Management
The remote is powered directly from the ESP32's 3.3V rail (or via the VCC GPIO through a transistor). The Berry script handles a **4-second cold boot** delay on startup to ensure the remote's LCD has stabilized before the first channel-sync pulse is sent.

### Synchronization & Manual Use
Since the remote buttons are still active, manual interaction is possible. However, because 433MHz is a one-way protocol, manual channel changes on the remote will not be detected by the ESP32. To maintain synchronization:
* **Hard Reset**: The ESP32 controls the remote's power (VCC). On boot, it performs a 4-second power cycle to force the remote back to its default starting channel.
* **Enhancement Path**: For users requiring 100% manual/software parity, the project could be modified by detaching the physical buttons from the remote's MCU and routing them as inputs into the ESP32 for full signal interception.

## ⛓️ Sequential Command Queuing

Because moving a specific shutter requires a sequence of pulses (Wake -> Step -> Move), the script uses a non-blocking FIFO queue. This ensures that pulses never overlap and the remote has sufficient time to process each "tap."

### Example: "Move Shutter 3 Down"
If the remote is currently on **Channel 1** and is in **Sleep mode**, a single `shutter_full 3,down` command triggers the following automated sequence:

| Step | Action | Description | Delay |
| :--- | :--- | :--- | :--- |
| 1 | **Wake-up** | Sends a `Stop` pulse to turn on the remote screen/LEDs. | 800ms |
| 2 | **Step Right** | Sends pulse to move from Ch 1 to Ch 2. | 450ms |
| 3 | **Step Right** | Sends pulse to move from Ch 2 to Ch 3. | 450ms |
| 4 | **Direction** | Sends the `Down` pulse on the now-active Ch 3. | 250ms |
| 5 | **Redundancy** | Sends a second `Down` pulse for reliability. | 550ms |

```
       ┌───────────────────────────────────────────┐
       │             SYSTEM STARTUP                │
       │        (remote_hard_reset())              │
       └─────────────┬─────────────────────────────┘
                     │
                     ▼
       ┌───────────────────────────────────────────┐
       │             STATE: SLEEP                  │◄────────────────┐
       │ (VCC: ON | current_chan: 1 | is_sleep: T) │                 │
       └─────────────┬─────────────────────────────┘                 │
                     │                                               │
              [RECEIVE COMMAND]                                [10s INACTIVITY]
                     │                                               │
                     ▼                                               │
       ┌───────────────────────────────────────────┐                 │
       │             STATE: WAKING                 │                 │
       │ (Pulse STOP | is_sleep: F | delay 800ms)  │                 │
       └─────────────┬─────────────────────────────┘                 │
                     │                                               │
                     ▼                                               │
       ┌───────────────────────────────────────────┐                 │
       │            STATE: STEPPING                │◄──┐             │
       │ (working: T | Pulse CH+/- | delay 450ms)  │   │             │
       └─────────────┬─────────────────────────────┘   │(Loop until  │
                     │                                 │ target_chan │
              [TARGET REACHED]                         │ reached)    │
                     │                                 └─────────────┘
                     ▼                                               │
       ┌───────────────────────────────────────────┐                 │
       │             STATE: MOVING                 │                 │
       │ (working: T | Pulse UP/DOWN/SHADE)        │                 │
       └─────────────┬─────────────────────────────┘                 │
                     │                                               │
             [COMMAND FINISHED]                                      │
                     │                                               │
                     ▼                                               │
       ┌───────────────────────────────────────────┐                 │
       │              STATE: IDLE                  │                 │
       │ (working: F | last_act: now | status: OK) ├─────────────────┘
       └─────────────┬─────────────────────────────┘
                     │
              [NEW COMMAND RECEIVED]
              (Check if target != current)
                     │
                     ▼
             (Go to WAKING/STEPPING)

```

🏠 Home Assistant Integrati
Integrate your shutters into Home Assistant using MQTT Template Covers and Sensors.

### 1. Covconfiguration.yaml to your `cocover:
  - platform: mqtt
    name: "Living Room Shutter"
    command_topic: "cmnd/shutter_controller/shutter_full"
    state_topic: "stat/shutter_controller/STATE"
    availability_topic: "tele/shutter_controller/LWT"
    payload_open: "3,up"
    payload_close: "3,down"
    payload_stop: "3,stop"
    state_open: "Idle"
    state_closed: "Sleep"
    optimistic: true
```

### 2. Monitoring Sensors
Add these to track the active channel and bridge status in real-time.

```yaml
mqtt:
  sensor:
    - name: "Shutter Current Channel"
      state_topic: "stat/shutter_controller/CHANNEL"
      icon: "mdi:numeric"
    - name: "Shutter Bridge Status"
      state_topic: "stat/shutter_controller/STATE"
      icon: "mdi:remote"
```

### 3. Shade Helper (Script)
```yaml
script:
  shutter_shade:
    alias: "Set Living Room to Shade"
    sequence:
      - service: mqtt.publish
        data:
          topic: "cmnd/shutter_controller/shutter_full"
          payload: "3,shade"
```

---

## 🚀 Installation
1.  **Upload**: Place `shutter.be` and `webGUI.be` in the Tasmota File System.
2.  **Auto-Start**: Add `load("shutter.be")` and `load("webGUI.be")` to your `autoexec.be`.
3.  **Developer Note**: This script uses a **"Flat-If"** architecture to maintain high stability. This avoids the `elif` parser bug found in some Tasmota Berry versions, ensuring the script compiles and runs reliably on the ESP32-D0WD-V3 chipset.
