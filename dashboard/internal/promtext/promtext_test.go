package promtext

import (
	"strings"
	"testing"
)

const sample = `# HELP node_disk_info Info of /sys/block/<block_device>.
# TYPE node_disk_info gauge
node_disk_info{device="sdc",model="OOS20000G",path="pci-0000:06:00.0-sas-exp0x5003048001b9673f-phy0-lun-0",serial="00017JMJ"} 1
node_load1 0.17
smartctl_device_attribute{attribute_id="5",attribute_name="Reallocated_Sector_Ct",attribute_value_type="raw",device="sda"} 0
weird{msg="a \"quoted\" \\ value, with {braces}"} 1.5e+09 1700000000000
`

func TestParse(t *testing.T) {
	m, err := Parse(strings.NewReader(sample))
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := m.Value("node_load1", nil); !ok || v != 0.17 {
		t.Errorf("node_load1 = %v, %v", v, ok)
	}
	info := m.Find("node_disk_info", map[string]string{"device": "sdc"})
	if len(info) != 1 || info[0].Labels["serial"] != "00017JMJ" {
		t.Errorf("node_disk_info = %+v", info)
	}
	if _, ok := m.Value("smartctl_device_attribute", map[string]string{"attribute_name": "Reallocated_Sector_Ct", "device": "sda"}); !ok {
		t.Error("attribute not found")
	}
	w := m.Find("weird", nil)
	if len(w) != 1 || w[0].Labels["msg"] != `a "quoted" \ value, with {braces}` || w[0].Value != 1.5e9 {
		t.Errorf("weird = %+v", w)
	}
}
