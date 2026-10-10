#!/usr/bin/env python3
"""Keep WebDriverAgent running and forward localhost:8100 through usbmux."""
import asyncio
import json
import os
import signal
import time
from pathlib import Path

from pymobiledevice3.dtx import ns_types
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.testmanaged.xcuitest import TestConfig, XCUITestService
from pymobiledevice3.tcp_forwarder import UsbmuxTcpForwarder
from pymobiledevice3.usbmux import list_devices

RUNNER = os.getenv("IPHONE_WDA_RUNNER", "com.facebook.WebDriverAgentRunner.xctrunner.YOURTEAMID")
STATUS = Path(os.getenv("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "iphone-agent/wda.json"
APPS = STATUS.with_name("apps.json")

# pymobiledevice3 can recurse while rendering NSError from an exited runner.
ns_types.NSError.__repr__ = ns_types.NSError.__str__ = lambda s: f"NSError({s.domain} {s.code})"


def set_status(state: str, message: str = "") -> None:
    STATUS.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = STATUS.with_suffix(".tmp")
    tmp.write_text(json.dumps({"state": state, "message": message[:300], "since": int(time.time())}) + "\n")
    os.chmod(tmp, 0o600)
    tmp.replace(STATUS)


async def usb_phone():
    return next((d for d in await list_devices() if d.is_usb), None)


def write_apps(rows: list[dict]) -> None:
    APPS.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = APPS.with_suffix(".tmp")
    tmp.write_text(json.dumps(rows) + "\n")
    os.chmod(tmp, 0o600)
    tmp.replace(APPS)


async def refresh_apps(serial: str) -> None:
    """Publish installed app names + bundle ids for the panel and phone.ts."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    lockdown = await create_using_usbmux(serial=serial, autopair=False)
    try:
        async with InstallationProxyService(lockdown) as service:
            apps = await service.get_apps(application_type="Any")
    finally:
        await lockdown.close()
    rows = []
    for bundle, info in apps.items():
        if not isinstance(info, dict) or info.get("IsHidden"):
            continue
        name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or bundle
        rows.append({"name": str(name), "bundle": str(bundle)})
    rows.sort(key=lambda row: row["name"].lower())
    write_apps(rows)


async def wda_ready() -> bool:
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", 8100), 1)
        writer.write(b"GET /status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        await writer.drain()
        data = await asyncio.wait_for(reader.read(4096), 2)
        writer.close()
        await writer.wait_closed()
        return b"200" in data.split(b"\r\n", 1)[0]
    except (OSError, asyncio.TimeoutError):
        return False


async def run_once(device) -> None:
    set_status("starting", "opening userspace tunnel")
    tunnel = UserspaceRsdTunnel(serial=device.serial, autopair=False, remotepairing_fallback=False)
    async with tunnel as rsd:
        config = await TestConfig.create_for(rsd, runner_bundle_id=RUNNER)
        forward = UsbmuxTcpForwarder(device.serial, 8100, 8100, usbmux_connection_type="USB")
        mjpeg = UsbmuxTcpForwarder(device.serial, 9100, 9100, usbmux_connection_type="USB")  # WDA MJPEG
        tasks = [asyncio.create_task(forward.start(address="127.0.0.1")),
                 asyncio.create_task(mjpeg.start(address="127.0.0.1")),
                 asyncio.create_task(XCUITestService(rsd).run(config))]
        try:
            for _ in range(30):
                if any(t.done() for t in tasks):
                    raise RuntimeError("WDA runner or port forward exited during startup")
                if await wda_ready():
                    try:
                        await refresh_apps(device.serial)
                    except Exception as exc:
                        print(f"apps.json unavailable: {type(exc).__name__}: {exc}", flush=True)
                    set_status("ready", "WDA available on 127.0.0.1:8100")
                    break
                await asyncio.sleep(.5)
            else:
                raise TimeoutError("WDA did not become ready within 15 seconds")
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                await task
            raise RuntimeError("WDA runner or port forward exited")
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


async def main() -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    while not stop.is_set():
        try:
            device = await usb_phone()
            if device is None:
                set_status("no_phone", "connect an iPhone by USB")
                await asyncio.sleep(2)
                continue
            await run_once(device)
        except asyncio.CancelledError:
            break
        except Exception as exc:
            # usbmuxd commonly exits when the last USB phone is removed.
            if type(exc).__name__ in {"ConnectionFailedToUsbmuxdError", "ConnectionFailedError"}:
                set_status("no_phone", "connect an iPhone by USB")
            else:
                set_status("error", f"{type(exc).__name__}: {exc}")
            try:
                await asyncio.wait_for(stop.wait(), timeout=2)
            except asyncio.TimeoutError:
                pass
    set_status("no_phone", "WDA supervisor stopped")


if __name__ == "__main__":
    asyncio.run(main())
