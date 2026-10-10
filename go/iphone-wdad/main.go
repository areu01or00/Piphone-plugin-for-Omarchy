// iphone-wdad runs WebDriverAgent over a rootless userspace go-ios tunnel and forwards its ports.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"syscall"
	"time"

	"github.com/danielpaulus/go-ios/ios"
	"github.com/danielpaulus/go-ios/ios/installationproxy"
	"github.com/danielpaulus/go-ios/ios/testmanagerd"
	"github.com/danielpaulus/go-ios/ios/tunnel"
)

const (
	xctestConfig = "WebDriverAgentRunner.xctest"
	wdaPort      = 8100
	mjpegPort    = 9100
	ifacePort    = 49160
)

type status struct {
	State   string `json:"state"`
	Message string `json:"message"`
	Since   int64  `json:"since"`
}
type appRow struct {
	Name   string `json:"name"`
	Bundle string `json:"bundle"`
}

var statusPath, appsPath string

func writeAtomic(path string, v any) {
	b, _ := json.Marshal(v)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err == nil {
		_ = os.Rename(tmp, path)
	}
}
func writeStatus(state, message string) {
	writeAtomic(statusPath, status{State: state, Message: message, Since: time.Now().Unix()})
}

func findDevice(serial string) (ios.DeviceEntry, bool) {
	list, err := ios.ListDevices()
	if err != nil {
		return ios.DeviceEntry{}, false
	}
	for _, d := range list.DeviceList {
		if serial != "" {
			if d.Properties.SerialNumber == serial {
				return d, true
			}
			continue
		}
		if d.ConnectionTypeLabel() == "USB" {
			return d, true
		}
	}
	return ios.DeviceEntry{}, false
}

func writeApps(device ios.DeviceEntry) {
	conn, err := installationproxy.New(device)
	if err != nil {
		slog.Warn("apps.json: installation proxy unavailable", "error", err)
		return
	}
	defer conn.Close()
	apps, err := conn.BrowseAllApps()
	if err != nil {
		slog.Warn("apps.json: browse failed", "error", err)
		return
	}
	rows := make([]appRow, 0, len(apps))
	for _, a := range apps {
		if t, _ := a[installationproxy.ApplicationType].(string); t == "Hidden" {
			continue
		}
		name := ""
		for _, k := range []string{installationproxy.CFBundleDisplayName, installationproxy.CFBundleName, installationproxy.CFBundleIdentifier} {
			if v, ok := a[k].(string); ok && v != "" {
				name = v
				break
			}
		}
		bundle, _ := a[installationproxy.CFBundleIdentifier].(string)
		if name == "" || bundle == "" {
			continue
		}
		rows = append(rows, appRow{Name: name, Bundle: bundle})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	writeAtomic(appsPath, rows)
}

// forwardLocal forwards 127.0.0.1:hostPort to the device's phonePort via usbmux.
func forwardLocal(deviceID int, hostPort, phonePort uint16) (func(), error) {
	l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", hostPort))
	if err != nil {
		return func() {}, err
	}
	go func() {
		for {
			client, err := l.Accept()
			if err != nil {
				return
			}
			go func(client net.Conn) {
				defer client.Close()
				mux, err := ios.NewUsbMuxConnectionSimple()
				if err != nil {
					return
				}
				// ReleaseDeviceConnection nils mux's conn, so only close mux on the error path.
				if err := mux.Connect(deviceID, phonePort); err != nil {
					_ = mux.Close()
					return
				}
				deviceConn := mux.ReleaseDeviceConnection()
				defer deviceConn.Close()
				done := make(chan struct{}, 2)
				go func() { _, _ = io.Copy(deviceConn.Writer(), client); done <- struct{}{} }()
				go func() { _, _ = io.Copy(client, deviceConn.Reader()); done <- struct{}{} }()
				<-done
			}(client)
		}
	}()
	return func() { _ = l.Close() }, nil
}
func wdaReady() bool {
	client := http.Client{Timeout: time.Second}
	resp, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/status", wdaPort))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// runOnce drives one attach: pairing check, userspace tunnel, RSD device, WDA, forwards.
func runOnce(ctx context.Context, device ios.DeviceEntry, runner string) error {
	serial := device.Properties.SerialNumber
	if _, err := ios.ReadPairRecord(serial); err != nil {
		return fmt.Errorf("no existing pairing for %s; pair the device first (this binary never creates a pair record): %w", serial, err)
	}

	tun, err := tunnel.ConnectUserSpaceTunnelLockdown(device, ifacePort)
	if err != nil {
		return fmt.Errorf("userspace tunnel: %w", err)
	}
	defer tun.Close()
	device.UserspaceTUN = true
	device.UserspaceTUNHost = "127.0.0.1"
	device.UserspaceTUNPort = ifacePort

	rsd, err := ios.NewWithAddrPortDevice(tun.Address, tun.RsdPort, device)
	if err != nil {
		return fmt.Errorf("RSD connect: %w", err)
	}
	defer rsd.Close()
	handshake, err := rsd.Handshake()
	if err != nil {
		return fmt.Errorf("RSD handshake: %w", err)
	}
	rsdDevice, err := ios.GetDeviceWithAddress(serial, tun.Address, handshake)
	if err != nil {
		return fmt.Errorf("RSD device: %w", err)
	}
	rsdDevice.UserspaceTUN = true
	rsdDevice.UserspaceTUNHost = "127.0.0.1"
	rsdDevice.UserspaceTUNPort = ifacePort

	stopWDA, err := forwardLocal(device.DeviceID, wdaPort, wdaPort)
	if err != nil {
		return fmt.Errorf("forward %d: %w", wdaPort, err)
	}
	defer stopWDA()
	stopMJPEG, err := forwardLocal(device.DeviceID, mjpegPort, mjpegPort)
	if err != nil {
		return fmt.Errorf("forward %d: %w", mjpegPort, err)
	}
	defer stopMJPEG()

	go writeApps(device)

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() { // unplug watchdog
		for {
			select {
			case <-runCtx.Done():
				return
			case <-time.After(time.Second):
				if _, ok := findDevice(serial); !ok {
					cancel()
					return
				}
			}
		}
	}()

	errCh := make(chan error, 1)
	go func() {
		_, err := testmanagerd.RunTestWithConfig(runCtx, testmanagerd.TestConfig{
			BundleId:           runner,
			TestRunnerBundleId: runner,
			XctestConfigName:   xctestConfig,
			Device:             rsdDevice,
			Listener:           testmanagerd.NewTestListener(io.Discard, io.Discard, os.TempDir()),
		})
		errCh <- err
	}()

	deadline := time.Now().Add(25 * time.Second)
	for !wdaReady() {
		if time.Now().After(deadline) {
			return fmt.Errorf("WDA did not become ready at 127.0.0.1:%d", wdaPort)
		}
		select {
		case <-runCtx.Done():
			return nil
		case err := <-errCh:
			if err != nil {
				return fmt.Errorf("WDA runner: %w", err)
			}
			return fmt.Errorf("WDA runner exited before ready")
		case <-time.After(300 * time.Millisecond):
		}
	}
	writeStatus("ready", fmt.Sprintf("WDA available on 127.0.0.1:%d", wdaPort))

	select {
	case <-runCtx.Done():
		return nil
	case err := <-errCh:
		if err != nil {
			return fmt.Errorf("WDA runner: %w", err)
		}
		return fmt.Errorf("WDA runner exited")
	}
}
func main() {
	defRunner := os.Getenv("IPHONE_WDA_RUNNER")
	if defRunner == "" {
		defRunner = "com.facebook.WebDriverAgentRunner.xctrunner.YOURTEAMID"
	}
	runner := flag.String("runner", defRunner, "WDA runner bundle id (xctrunner + your Apple Team ID)")
	flag.Parse()

	dir := fmt.Sprintf("/run/user/%d/iphone-agent", os.Getuid())
	if x := os.Getenv("XDG_RUNTIME_DIR"); x != "" {
		dir = filepath.Join(x, "iphone-agent")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		slog.Error("cannot create runtime dir", "dir", dir, "error", err)
		os.Exit(1)
	}
	statusPath = filepath.Join(dir, "wda.json")
	appsPath = filepath.Join(dir, "apps.json")

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	writeStatus("no_phone", "connect an iPhone by USB")
	for {
		if ctx.Err() != nil {
			writeStatus("no_phone", "iphone-wdad stopped")
			return
		}
		device, ok := findDevice("")
		if !ok {
			writeStatus("no_phone", "connect an iPhone by USB")
			time.Sleep(2 * time.Second)
			continue
		}
		writeStatus("starting", "opening userspace tunnel and starting WDA")
		err := runOnce(ctx, device, *runner)
		if ctx.Err() != nil {
			writeStatus("no_phone", "iphone-wdad stopped")
			return
		}
		if err != nil {
			slog.Warn("attach failed", "error", err)
			writeStatus("error", err.Error())
		} else {
			writeStatus("no_phone", "WDA stopped; waiting for the next device")
		}
		time.Sleep(2 * time.Second)
	}
}
