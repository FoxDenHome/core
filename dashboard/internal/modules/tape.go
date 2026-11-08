package modules

import (
	"context"
	"strconv"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
	"github.com/FoxDenHome/core/dashboard/internal/snmp"
)

// BDT-MIB. The library reuses Dell's storage MIB layout under BDT's
// enterprise number, including Dell's status values.
const bdtGlobalStatus = "1.3.6.1.4.1.20884.10893.2.101.2.1.0"

var bdtStatuses = map[int64]struct {
	text   string
	status rack.Status
}{
	1: {"other", rack.StatusUnknown},
	2: {"unknown", rack.StatusUnknown},
	3: {"ok", rack.StatusOK},
	4: {"non-critical", rack.StatusWarn},
	5: {"critical", rack.StatusCrit},
	6: {"non-recoverable", rack.StatusCrit},
}

type tapeLibrary struct {
	env *Env
	dev *config.Device
}

func init() {
	register(Spec{
		Name:        "ibm-ts3100",
		Description: "IBM TS3100 / BDT FlexStor II 2U tape library. Global status and uptime over SNMP.",
		Height:      2,
		New: func(env *Env, dev *config.Device) (Driver, error) {
			if _, err := decodeOptions(dev, struct{}{}); err != nil {
				return nil, err
			}
			return &tapeLibrary{env: env, dev: dev}, nil
		},
	})
}

func (t *tapeLibrary) Skeleton() rack.State {
	return rack.State{
		Status: rack.StatusUnknown,
		Faceplate: []rack.Group{{ID: "leds", Kind: rack.KindLED, Label: "Status", Rows: 2, Slots: []rack.Slot{
			{ID: "status", Label: "Status", Status: rack.StatusUnknown},
		}}},
	}
}

func (t *tapeLibrary) Poll(ctx context.Context) (rack.State, error) {
	c, err := snmp.Dial(ctx, t.dev.Address, t.env.SNMPCommunity)
	if err != nil {
		return rack.State{}, err
	}
	defer c.Close()
	vals, err := c.Get(sysUpTime, bdtGlobalStatus)
	if err != nil {
		return rack.State{}, err
	}

	st := t.Skeleton()
	st.Status = rack.StatusOK
	lib := rack.Section{Title: "Library"}
	led := &st.Faceplate[0].Slots[0]
	if v, ok := vals.Int(bdtGlobalStatus); ok {
		s, known := bdtStatuses[v]
		if !known {
			s.text, s.status = strconv.FormatInt(v, 10), rack.StatusUnknown
		}
		lib.AddStatus("Global status", s.text, s.status)
		st.Status = rack.Worst(st.Status, s.status)
		led.Status, led.Value = s.status, s.text
		st.Summary = s.text
	}
	if ticks, ok := vals.Int(sysUpTime); ok {
		lib.Add("Uptime", formatDuration(time.Duration(ticks)*10*time.Millisecond))
	}
	st.Sections = []rack.Section{lib}
	st.Rollup()
	return st, nil
}
