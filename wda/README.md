# WDA host service

`wda_up.py` waits for a USB iPhone, opens the userspace RSD tunnel with `autopair=False`, launches the signed XCUITest runner, and forwards `127.0.0.1:8100` in-process through usbmux. State is written to `$XDG_RUNTIME_DIR/iphone-agent/wda.json`.

The free provisioning profile expires weekly. First use Impactor interactively to renew it; then run `./resign.sh`. The helper dumps the renewed profile, extracts its public certificate, signs the IPA with the existing local Impactor key, and installs it. It never prints or copies the private key into this repository.
