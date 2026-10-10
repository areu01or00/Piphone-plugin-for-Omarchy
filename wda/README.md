# WebDriverAgent signing

The agent drives the phone through a **signed WebDriverAgent** runner. The Go
supervisor (`go/iphone-wdad/`) launches it and serves it to the owner over the
private Unix socket `$XDG_RUNTIME_DIR/iphone-agent/wda.sock` — nothing is exposed
on a network port.

`resign.sh` renews the runner when its profile expires. A free Apple provisioning
profile lasts seven days: first renew it interactively in Impactor, then run
`./resign.sh`. The helper dumps the renewed profile, extracts its public
certificate, signs the IPA with the existing local Impactor key, and installs it.
It never prints or copies the private key into this repository.
