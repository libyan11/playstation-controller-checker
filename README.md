# PlayStation Controller Checker

A single-page browser tool that tests a PlayStation controller (DualShock 4 or DualSense) over WebHID. It tells a genuine Sony controller from a clone, grades how well it works, and produces a shareable report with per-controller history.

It checks stick drift and range, every button, analog triggers, gyro and touchpad, lightbar and rumble, battery and Bluetooth signal, and (for the DualShock 4) runs Sony's security-chip handshake. It also has an aim trainer and recommended settings for Call of Duty and Fortnite.

## Run

Double-click `start.bat`. It serves the folder at http://127.0.0.1:8790 and opens it in Chrome (WebHID needs a secure origin like localhost). Requires Python (`py`) and Chrome. Close the window to stop the server.

Use Chrome or Edge on a computer, plug the controller in with a USB data cable, quit Steam and DS4Windows, then click **Connect & test**.

## Files

- `index.html`: the app
- `tests/run.html`: automated tests, driving the real page with simulated controllers from `tests/mock-controller.js` (genuine and fake DualShock 4 and DualSense, over USB and Bluetooth)
- `tools/`: PowerShell scripts for HID and battery testing, and `run-tests.mjs`

## Running the tests

Headless, from a terminal (needs Node 22+, Chrome and Python; exit code 0 means everything passed; takes about 3 minutes):

```
node tools/run-tests.mjs
```

Or open `tests/run.html` through `start.bat`'s server and keep the tab visible and focused: browsers pause animation in background tabs, and the timed tests depend on it.

The simulated controllers prove the page's logic is self-consistent, not that every physical controller behaves identically.
