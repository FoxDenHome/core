package services

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// The layout matches shutdownd's own install.sh, so a hand-made install is
// taken over in place rather than duplicated.
const (
	shutdowndBin     = "/usr/bin/shutdownd"
	shutdowndConfig  = "/etc/shutdownd"
	shutdowndUnit    = "/etc/systemd/system/shutdownd.service"
	shutdowndRunUnit = "/etc/systemd/system/shutdownd-run.service"
	shutdowndPolkit  = "/etc/polkit-1/rules.d/10-shutdownd.rules"
)

const shutdowndUnitText = `[Unit]
Description=shutdownd
StartLimitIntervalSec=0

[Service]
User=shutdownd
Type=simple
Restart=always
RestartSec=1
Environment=SHUTDOWND_CONFIG_DIR=/etc/shutdownd
ExecStart=/usr/bin/shutdownd

[Install]
WantedBy=multi-user.target
`

const shutdowndRunUnitText = `[Unit]
Description=shutdownd runner
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/shutdown -P 1
ExecStop=/usr/bin/shutdown -c
`

const shutdowndPolkitText = `polkit.addRule(function(action, subject) {
  if (action.id === "org.freedesktop.systemd1.manage-units" &&
    action.lookup("unit") == "shutdownd-run.service" &&
    subject.user === "shutdownd")
    {
      return polkit.Result.YES;
    }
});
`

func init() { shutdownd.installer = shutdowndLinux{} }

type shutdowndLinux struct{}

func (shutdowndLinux) Detect(sys *System) (bool, string) {
	if !sys.exists(shutdowndBin) {
		return false, ""
	}
	return true, "installed manually; enable it here to keep it updated"
}

func nologin() string {
	for _, p := range []string{"/usr/sbin/nologin", "/usr/bin/nologin", "/sbin/nologin"} {
		if _, err := exec.LookPath(p); err == nil {
			return p
		}
	}
	return "/usr/sbin/nologin"
}

func (shutdowndLinux) Install(ctx context.Context, sys *System, binary string) (string, error) {
	serverPem := shutdowndConfig + "/server.pem"
	if shutdowndServerCert() == nil && !sys.exists(serverPem) {
		return "", errors.New("this build has no pinned server.pem and none is installed: shutdownd would not know who may shut it down")
	}
	uid, gid, err := sys.LookupUser("shutdownd")
	if err != nil {
		if _, err := sys.Run(ctx, "useradd", "-r", "-d", "/var/empty", "-s", nologin(), "shutdownd"); err != nil {
			return "", err
		}
		if uid, gid, err = sys.LookupUser("shutdownd"); err != nil {
			return "", err
		}
	}

	restart := false
	changed, err := sys.installBinary(binary, shutdowndBin)
	if err != nil {
		return "", fmt.Errorf("installing binary: %w", err)
	}
	restart = restart || changed

	if err := mkdirOwned(sys, shutdowndConfig, uid, gid); err != nil {
		return "", err
	}
	if cert := shutdowndServerCert(); cert != nil {
		changed, err := sys.writeFile(serverPem, cert, 0o644)
		if err != nil {
			return "", err
		}
		restart = restart || changed
	}
	// cert.pem holds shutdownd's private key; it generates it on first start.
	if p := shutdowndConfig + "/cert.pem"; sys.exists(p) {
		if err := chmodOwned(sys, p, 0o600, uid, gid); err != nil {
			return "", err
		}
	}

	unitsChanged := false
	for _, f := range []struct {
		path, text string
	}{
		{shutdowndUnit, shutdowndUnitText},
		{shutdowndRunUnit, shutdowndRunUnitText},
		{shutdowndPolkit, shutdowndPolkitText}, // polkit picks up rule changes by itself
	} {
		changed, err := sys.writeFile(f.path, []byte(f.text), 0o644)
		if err != nil {
			return "", err
		}
		if changed && f.path != shutdowndPolkit {
			unitsChanged = true
		}
	}
	if unitsChanged {
		if _, err := sys.systemctl(ctx, "daemon-reload"); err != nil {
			return "", err
		}
		restart = true
	}
	if _, err := sys.systemctl(ctx, "enable", "shutdownd.service"); err != nil {
		return "", err
	}
	verb := "start"
	if restart {
		verb = "restart"
	}
	if _, err := sys.systemctl(ctx, verb, "shutdownd.service"); err != nil {
		return "", err
	}
	if out, err := sys.systemctl(ctx, "is-active", "shutdownd.service"); err != nil {
		return "", fmt.Errorf("shutdownd is not running: %s", strings.TrimSpace(out))
	}
	return "running " + shutdownd.Version, nil
}

func (shutdowndLinux) Remove(ctx context.Context, sys *System) error {
	if !sys.exists(shutdowndBin) && !sys.exists(shutdowndUnit) {
		return nil
	}
	// Disabling may fail if the unit is already gone; removal goes on regardless.
	_, _ = sys.systemctl(ctx, "disable", "--now", "shutdownd.service")
	var errs []error
	for _, p := range []string{shutdowndUnit, shutdowndRunUnit, shutdowndPolkit, shutdowndBin} {
		errs = append(errs, sys.remove(p))
	}
	_, err := sys.systemctl(ctx, "daemon-reload")
	errs = append(errs, err)
	// The config dir (with this machine's shutdownd identity) and the user stay,
	// so re-enabling keeps the same certificate.
	return errors.Join(errs...)
}
