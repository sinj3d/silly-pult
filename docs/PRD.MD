PRD
# SillyPlut
This project is designed to enhance notification reception by utilizing a physical catapault to sling a harmless object towards the user when a notification is received

## Scope
The scope is limited to PC notifications at first for MVP, with designs implemented to capture notifications from phone using Bluetooth. 


## Tech Stack
The project would have a control panel, so:
- Control Panel: NextJS
- Firmware: c++, simply state the communication protocol and assume it's going to be implemented as we expect. Primarily should just be: activate, and wait for completion, and then that's it.
The system already provides the necessary stuff, such that we can already simply instruct catapault to act when we detect notifications on the windows system. As part of the project, include a test button in the control panel for sending a notification toast, that is then reflected automatically on the catapault. This should still be done via normal notification detection but the test tool emits a notification. 

The control panel allows control over focus times where catapault would act on work notifications only, and nothing else. And, monitors activities to catapault when you are distracted (by checking for websites like instagram, coolmathgames, etc. )
The control panel shows a dashboard with notification counts, ignored and focused notifications respectively, as well as distraction rates. 

**The project will focus on using macos' notification system to incorporate both iPhone forwarded notifications, as well as normal notifications. Both of which, needs primarily just us detectin gnotifications and emitting notifications from only the macos side.**