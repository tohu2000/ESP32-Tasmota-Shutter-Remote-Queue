# 433MHz Multi-Channel Shutter Bridge for Tasmota (Berry)

This project provides a professional-grade bridge between **Tasmota (ESP32)** and proprietary **433MHz RF** multi-channel shutter remotes. It uses the Berry scripting language to handle complex channel-stepping logic, hardware synchronization, and specialized functions like the "Shade" (intermediate) position.

## 📟 Hardware Compatibility
Designed for the common 5-button (up,down, channel left and right, stop) 433MHz remote family (OOK/FSK) found in the shutter industry.

> [!CAUTION]
> **Voltage Warning:** The original remote is designed for a **3V CR2430 lithium cell**. This project powers the RC PCB directly with **3.3V** from the ESP32. While most remote control ICs have tolerances that allow for this minor voltage increase, proceed at your own risk. **Ensure the 100µF Elko is present** to help regulate current spikes and protect the remote's MCU.
This project interfaces with consumer-grade RF remote controls that are originally designed for occasional manual operation. While the ESP32 allows for powerful automation, please keep the following in mind:
* **Thermal Limits:** Proprietary 433MHz transmitters (especially high-gain 25mW versions) lack active cooling. They are intended for short bursts. "Spamming" commands or running them in tight software loops can cause the RF components to overheat and fail permanently.
* **The "Hard" Power Factor:** Unlike a CR2430 battery which "sags" under stress, a 3.3V supply from an ESP32 is a "hard" power source. It will continue to drive current into the remote even if a software hang occurs, increasing the risk of hardware damage.
* **Safety Watchdog:** The provided Berry script includes a safety watchdog to mitigate these risks. However, you should **avoid automation logic** (e.g., in Home Assistant or Node-RED) that triggers the remote repeatedly without significant cooldown periods.
**Recommendation:** Limit high-frequency bursts and ensure your automation doesn't create infinite "ping-pong" loops between the bridge and your smart home controller.

---

* **10-Channel LCD (Target Model)**: Displays channels `00` through `09`.
* **15-Channel LCD**: Displays channels `00` through `15`.
* **Channel `00` Note**: Channel 00 actuates all devices registered on the remote.

* **Model Note (5-Channel LED Variants)**: The script is fully compatible with 5-channel LED models, as the channel-stepping logic is identical (LCD is replaced by 7 LEDs 00 – 05 and one operation LED). 
**Wiring Requirement:** Unlike the 10- and 15-channel LCD remotes, the buttons on most 5-channel LED variants do **not** switch against Ground potential. To interface these models with an ESP32, **optocouplers** (e.g., PC817) are required for each control line to ensure electrical isolation and proper signal switching.

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




## 🕹️ Command Reference

You can trigger these commands via the Tasmota Console, HTTP-API, or MQTT.

| Command | Payload Example | Description | Pulse Sequence (Internal) |
| :--- | :--- | :--- | :--- |
| **`chan`** | `5` | Selects a specific channel without moving. | `Wake -> Step to 5` |
| **`goup`** | *(none)* | Moves the shutter on the **current** channel up. | `Wake -> Up-Pulse` |
| **`godown`** | *(none)* | Moves the shutter on the **current** channel down. | `Wake -> Down-Pulse` |
| **`stop`** | *(none)* | Sends a stop pulse on the **current** channel. | `Wake -> Stop-Pulse` |
| **`goshade`** | *(none)* | Triggers the intermediate "Shade" position. | `Wake -> Long-Stop (4.5s)` |
| **`chanandgo`** | `3,down` | **Main Command:** Changes to channel and moves: `up` `down` `stop` `shade` | `Wake -> Step to 3 -> Down` |
| **`hardreset`**| *(none)* | Perfroms a 4s power cycle via GPIO 18. | `Power OFF -> Power ON` |
| **`unlock`** | `1` | Clears Failsafe state and sets current channel. | `Software Reset only` |

### Usage Examples

**Via Tasmota Console:**
```tasmota
chanandgo 12,up    // Moves shutter on channel 12 up
goshade            // Triggers shade for the currently active channel
hardreset          // Forces remote to Channel 01 if sync is lost
````

Via MQTT: Topic: 
`cmnd/your_device_topic/chanandgo`

`Payload: 7,down`

Via HTTP-API: `http://<IP>/cmnd?cmnd=chanandgo%205,shade`

## 🛠 Technical Implementation

### Open Drain (Open Gate) Parallel Wiring
The ESP32 is wired in parallel with the physical buttons of the remote. This is made possible by configuring the ESP32 GPIOs as **Output Open Drain**. In this state, the ESP32 only pulls the line to Ground (simulating a button press) or remains high-impedance (floating). 

### Synchronization & Manual Use
* **Hard Reset**: The ESP32 controls the remote's power (VCC). On boot, it performs a 4-second power cycle to force the remote back to its default starting channel.
* **Manual Parity**: Physical buttons remain functional thanks to the Open Drain configuration. 330 Ohm resistors protect GPIOs if GND and remote is actuated Vcc.

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
       ESP32 DEVKIT                  433MHz REMOTE PCB
    ┌────────────────┐           ┌────────────────────┐
    │        GPIO 18 ├──────┬────┤ VCC (+)            │
    │                │     ┌┴┐   │                    │
    │                │  100uF│   │                    │
    │                │  (Elko)   │  [Buttons to GND]  │
    │                │     └┬┘   │                    │
    │            GND ├──────┴────┤ GND (-)            │
    │                │           └──────────┬─────────┘
    │                │    330R              │
    │        GPIO 13 ├────[###]─────────────┤ UP
    │        GPIO 12 ├────[###]─────────────┤ DOWN
    │        GPIO 14 ├────[###]─────────────┤ STOP
    │        GPIO 27 ├────[###]─────────────┤ CH (-)
    │        GPIO 26 ├────[###]─────────────┤ CH (+)
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
       ┌─────────────────────────────────────────────────────────┐
       │                  [ INITIALIZATION ]                     │
       │           Hard Reset -> Channel 1 -> SLEEP              │
       └───────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
       ┌─────────────────────────────────────────────────────────┐
  ┌───►│                   STATE: SLEEP                          │
  │    │   (Remote Display OFF | working: NO | is_sleeping: YES) │
  │    └───────────────────────────┬─────────────────────────────┘
  │            ▲                   │
  │            │         [ MONITOR LOOP POLLING ]
  │      (Auto-Sleep)    - Every 100ms (poll_idle)
  │            │         - Checks for Button Press (Manual)
  │            │                   │
  │      [ 7s PASSES ]      [ NEW CMD RECEIVED ]
  │            │                   │
  │            │        (Action: Send STOP Pulse to wake)
  │            │                   │
  │            │                   │
  │            │                   │                             
  │            │                   ▼                             
  │    ┌─────────────────────────────────────────────────────────┐◄────┐
  │    │                   STATE: WORKING                        │◄──┐ │
  │    │   (Relays Clicking | working: YES | Queue Size > 0)     │   │ │
  │    └──────┬────────────────────┬────────────────────┬────────┘   │ │
  │           │                    │                    │            │ │
  │     [ STEP CHANNEL ]     [ SEND MOVE CMD ]    [ NEW CMD IN ]     │ │
  │     (Wait 1000ms)        (Wait 1200ms+)       (Add to Queue)     │ │
  │           │                    │                    │            │ │
  │           └───────────┬────────┴────────────────────┘            │ │
  │                       │                                          │ │
  │               [ IS QUEUE EMPTY? ] ─── NO (Process Next) ─────────┘ │
  │                       │                                            │
  │                   YES (Finish)                                     │
  │                       │                                            │
  │                       ▼                                            │
  │    ┌─────────────────────────────────────────────────────────┐     │
  │    │                    STATE: IDLE                          │     │
  │    │   (Remote Display ON | working: NO | is_sleeping: NO)   │     │
  │    └──────┬───────────────────────────────────────┬──────────┘     │
  │           │                                       │                │
  │     [ 7s PASSES ]                            [ NEW CMD IN ]        │
  │           │                                  (Add to Queue)        │
  │           │                                         │              │
  │           ▼                                         └──────────────┘
  └─────[ GO TO SLEEP ]              


NOTE: monitor loop tracks chan buttons and updates self.current_chan


================================================================================
SHUTTER CONTROLLER: monitor_loop() - Finite State Machine (FSM)
================================================================================

       +-----------------------------------------------------------+
       |                  START: monitor_loop()                    |
       +-----------------------------------------------------------+
                     |                              |
      [now - boot_time < 2000ms?] --- YES ---> [Set Timer 200ms]
                     |                         [     Exit      ]
                    NO
                     |
       +----------------------------+        +---------------------------+
       |   PIN SCANNING PHASE       | <----- | !working && !failsafe?    |
       +----------------------------+  (YES) +---------------------------+
                     |                         (NO -> skip to LED Logic)
              [any_pressed != -1?]
              /                \
          (YES)                (NO)
            |                    |
     +--------------+     +-----------------------------------------+
     | BUTTON ACTIVE|     |        BUTTON RELEASE DETECTION         |
     +--------------+     +-----------------------------------------+
     | 1. Sleep 0   |        |                                 |
     | 2. last_act  |     [press_time > 0 && debounce_ms met?] |
     | 3. start_time|        |                                 |
     | 4. Monitor:  |       (YES)                            (NO)
     |    Desync?   |        |                                 |
     |    Stuck?    |     +-------------------------+          |
     +--------------+     |   HANDLE RELEASE LOGIC  |          |
            |             | 1. is_sleeping?         |          |
            |             |    YES -> Wake Up Only  |          |
            |             |    NO  -> Step Channel  |          |
            |             | 2. Clear press_time     |          |
            |             +-------------------------+          |
            |                        |                         |
            +------------------------+-------------------------+
                                     |
                    +-----------------------------------+
                    |      STANDBY / POWER SAVING       |
                    | (now - last_act > fb_timeout)     |
                    | [Sleep 50 / is_sleeping = true]   |
                    +-----------------------------------+
                                     |
                    +-----------------------------------+
                    |     HARDWARE SIGNALING (LED)      |
                    | (Priority: Press > Error > Idle)  |
                    +-----------------------------------+
                                     |
                    +-----------------------------------+
                    |         TIMER SCHEDULING          |
                    | (poll_idle [100] vs active [10])  |
                    +-----------------------------------+

```


## 🛡️ Safety & Failsafe Mechanisms

To protect the sensitive 433MHz hardware and ensure permanent synchronization, the Berry script implements several levels of safety:

### 1. Hardware Protection (Physical Layer)
The ESP32 GPIOs are configured as **Open Drain** (pulling to GND only). As an additional "insurance," **330 Ω resistors** are installed in each control line. These protect both the ESP32 and the remote's MCU from short circuits or misconfigurations (e.g., if a pin briefly goes to "Push-Pull" during a Tasmota update).

### 2. Software Watchdog (Stuck-Pin Protection)
The `monitor_loop` permanently monitors the state of all control lines:
* **Manual Override:** Detects if a button is pressed longer than 400ms (risk of desync).
* **Stuck-Pin Lock:** If a pin remains LOW (active) for more than **10 seconds** continuously, the script triggers a Failsafe. This prevents the transmitter unit from burning out in the event of a software hang.

### 3. Rate Limiting (Anti-Spam / Thermal Protection)
Proprietary 433MHz transmitters are not designed for continuous operation. To avoid thermal damage, the script monitors the transmission frequency:
* **Pulse Counter:** The script counts every pulse sent.
* **Limit:** If more than **80 pulses within 60 seconds** are registered (typical for faulty automation loops in Home Assistant), the bridge immediately enters lock mode (`FAILSAFE: Excessive Pulsing`).
* **Cooldown:** The counter is automatically reset after 60 seconds.

### 4. Hard Sync (Power-Cycle Recovery)
Since 433MHz is a one-way protocol without a return channel, synchronization can be lost during intensive manual use:
* **Hard Reset:** Using **GPIO 18**, the script can cut the power supply to the remote. This forces the remote to restart at **Channel 01**.
* **Unlock Command:** Using the `unlock <channel>` command, a failsafe state can be manually cleared, and the software can be re-synchronized with the remote's display.
---
### 💡 Status LED Indicators
The onboard LED provides real-time feedback on the bridge's health and synchronization status:

* **Fast Blinking (400ms):** **Manual Interaction Detected.** A physical button press was registered. Please check if the software channel still matches the remote's display.
* **Slow Blinking (1500ms):** **Failsafe Active.** The bridge has locked itself because a pin is stuck LOW or the transmission rate limit (80 pulses/min) was exceeded.

> [!TIP]
> Use the `unlock <channel>` command to clear the failsafe once the issue is resolved.

## 🏠 Home Assistant Integration
Integrate your shutters into Home Assistant using MQTT Template Covers and Sensors.

### 1. Covconfiguration.yaml to your `cocover:
```yaml
  - platform: mqtt
    name: "Living Room Shutter"
    command_topic: "cmnd/shutter_controller/chanandgo"
    state_topic: "stat/shutter_controller/STATE"
    availability_topic: "tele/shutter_controller/chanandgo"
    payload_open: "3,up"
    payload_close: "3,down"
    payload_stop: "3,stop"
    state_open: "Idle"
    state_closed: "Sleep"
    optimistic: true
```
## 2. Monitoring Sensors
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
          topic: "cmnd/shutter_controller/chanandgo"
          payload: "3,shade"
```

---

## 🚀 Installation
1.  **Upload**: Place `shutter.be` and `webGUI.be` in the Tasmota File System.
2.  **Auto-Start**: Add `load("shutter.be")` and `load("webGUI.be")` to your `autoexec.be`.
3.  **Developer Note**: This script uses a **"Flat-If"** architecture to maintain high stability. This avoids the `elif` parser bug found in some Tasmota Berry versions, ensuring the script compiles and runs reliably on the ESP32-D0WD-V3 chipset.
