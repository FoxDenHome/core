//! `sas3temp` — report the IOC ("ROC") temperature of LSI/Broadcom Fusion-MPT
//! HBAs such as the SAS3008, i.e. the same number as `storcli /c0 show temperature`.
//!
//! There is no sysfs/hwmon attribute for this, so we do what storcli does: open the
//! driver's control device (`/dev/mpt3ctl`, `/dev/mpt2ctl`) and submit a raw MPI2
//! `CONFIG` message frame asking for Configuration Page **IO Unit 7**, which carries
//! `IOCTemperature` / `IOCTemperatureUnits` (and, on some boards, a board sensor).
//!
//! Reading a config page is always two round trips: first the page *header* (to learn
//! its length), then the page body into a DMA buffer the driver sets up for us.
//!
//! Needs `CAP_SYS_ADMIN`: `run0 sas3temp`.

// The ABI structs below mirror kernel/firmware layouts; most fields exist only to get
// the offsets right and are never read.
#![allow(dead_code)]

use std::error::Error;
use std::fmt;
use std::fs::File;
use std::io;
use std::mem::{align_of, offset_of, size_of};
use std::os::fd::{AsRawFd, RawFd};
use std::os::raw::{c_int, c_ulong};

#[cfg(target_endian = "big")]
compile_error!("MPI2 structures are little-endian; only little-endian hosts are supported");

extern "C" {
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
}

// ---------------------------------------------------------------- constants

const CTL_DEVICES: [&str; 2] = ["/dev/mpt3ctl", "/dev/mpt2ctl"];
const MAX_IOC_SCAN: u32 = 16;

const MPI2_FUNCTION_CONFIG: u8 = 0x04;
const CONFIG_ACTION_PAGE_HEADER: u8 = 0x00;
const CONFIG_ACTION_READ_CURRENT: u8 = 0x01;
/// `MPI2_CONFIG_PAGETYPE_IO_UNIT`. The low nibble of `PageType` is the type, the high
/// nibble is the page attribute the firmware reports back in the header.
const CONFIG_PAGETYPE_IO_UNIT: u8 = 0x00;
const CONFIG_PAGETYPE_MASK: u8 = 0x0f;
const IO_UNIT_PAGE_7: u8 = 7;
const IOCSTATUS_MASK: u16 = 0x7fff;

/// Byte offsets inside `MPI2_CONFIG_PAGE_IO_UNIT_7`, each `u16` value followed by a unit byte.
const OFF_IOC_TEMPERATURE: usize = 0x10;
const OFF_BOARD_TEMPERATURE: usize = 0x14;

const UNIT_FAHRENHEIT: u8 = 0x01;
const UNIT_CELSIUS: u8 = 0x02;

/// Prometheus gauge name; the `_celsius` suffix is the unit, so Fahrenheit readings
/// get converted before they are exposed.
const METRIC: &str = "lsi_hba_temperature_celsius";

const USAGE: &str = "\
usage: sas3temp [-c <n>] [-d <device>]

Writes the HBA temperatures to stdout in Prometheus text exposition format.

  -c, --controller <n>   only report controller <n> (also accepts storcli's /c0 form)
  -d, --device <path>    control device (default: /dev/mpt3ctl, then /dev/mpt2ctl)
  -h, --help             this text";

// ------------------------------------------------------- ioctl ABI (mpt3sas)

/// `_IOWR(type, nr, size)` as encoded by asm-generic/ioctl.h.
const fn iowr(magic: u8, nr: u8, size: usize) -> u32 {
    (3 << 30) | ((size as u32) << 16) | ((magic as u32) << 8) | nr as u32
}

/// `struct mpt3_ioctl_header`
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct IoctlHeader {
    ioc_number: u32,
    port_number: u32,
    max_data_size: u32,
}

/// `struct mpt3_ioctl_pci_info` — bitfield: device:5, function:3, bus:24.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PciInfo {
    word: u32,
    segment_id: u32,
}

/// `struct mpt3_ioctl_iocinfo`
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct IocInfo {
    hdr: IoctlHeader,
    adapter_type: u32,
    port_number: u32,
    pci_id: u32,
    hw_rev: u32,
    subsystem_device: u32,
    subsystem_vendor: u32,
    rsvd0: u32,
    firmware_version: u32,
    bios_version: u32,
    driver_version: [u8; 32],
    rsvd1: u8,
    scsi_id: u8,
    rsvd2: u16,
    pci_information: PciInfo,
}

/// `MPI2_CONFIG_PAGE_HEADER`
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PageHeader {
    page_version: u8,
    page_length: u8, // in dwords
    page_number: u8,
    page_type: u8,
}

/// `MPI2_CONFIG_REQUEST`
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct ConfigRequest {
    action: u8,
    sgl_flags: u8,
    chain_offset: u8,
    function: u8,
    ext_page_length: u16,
    ext_page_type: u8,
    msg_flags: u8,
    vp_id: u8,
    vf_id: u8,
    reserved1: u16,
    reserved2: u8,
    proxy_vf_id: u8,
    reserved4: u16,
    reserved3: u32,
    header: PageHeader,
    page_address: u32,
    /// The driver overwrites this with a scatter-gather element it builds itself,
    /// so everything from here on is never copied in from userspace.
    page_buffer_sge: [u32; 4],
}

/// `MPI2_CONFIG_REPLY`
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct ConfigReply {
    action: u8,
    sgl_flags: u8,
    msg_length: u8,
    function: u8,
    ext_page_length: u16,
    ext_page_type: u8,
    msg_flags: u8,
    vp_id: u8,
    vf_id: u8,
    reserved1: u16,
    reserved2: u16,
    ioc_status: u16,
    ioc_log_info: u32,
    header: PageHeader,
}

/// `struct mpt3_ioctl_command`, whose trailing `mf[1]` is the MPI request frame.
#[repr(C)]
struct MptCommand {
    hdr: IoctlHeader,
    timeout: u32,
    reply_frame_buf_ptr: usize,
    data_in_buf_ptr: usize,
    data_out_buf_ptr: usize,
    sense_data_ptr: usize,
    max_reply_bytes: u32,
    data_in_size: u32,
    data_out_size: u32,
    max_sense_bytes: u32,
    data_sge_offset: u32, // in dwords
    mf: ConfigRequest,
}

/// The kernel encodes `sizeof(struct mpt3_ioctl_command)` in the ioctl number, and that
/// struct ends right after the first byte of `mf[1]`.
const KARG_SIZE: usize = {
    let align = align_of::<MptCommand>();
    (offset_of!(MptCommand, mf) + align) / align * align
};

const MPT_IOCINFO: u32 = iowr(b'L', 17, size_of::<IocInfo>());
const MPT_COMMAND: u32 = iowr(b'L', 20, KARG_SIZE);

const _: () = {
    assert!(size_of::<ConfigRequest>() == 0x2c);
    assert!(offset_of!(ConfigRequest, header) == 0x14);
    assert!(offset_of!(ConfigRequest, page_buffer_sge) == 0x1c);
    assert!(size_of::<ConfigReply>() == 0x18);
    assert!(offset_of!(ConfigReply, ioc_status) == 0x0e);
    assert!(size_of::<IocInfo>() == 92);
    assert!(offset_of!(MptCommand, mf) % 4 == 0);
};

// ----------------------------------------------------------------- decoding

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Temperature {
    NotPresent,
    Celsius(u16),
    Fahrenheit(u16),
}

impl Temperature {
    /// Decode a `u16` temperature plus its trailing unit byte at `offset` in a config page.
    fn from_page(page: &[u8], offset: usize) -> Self {
        let (Some(value), Some(&unit)) = (page.get(offset..offset + 2), page.get(offset + 2))
        else {
            return Self::NotPresent;
        };
        let raw = u16::from_le_bytes([value[0], value[1]]);
        match unit {
            UNIT_CELSIUS => Self::Celsius(raw),
            UNIT_FAHRENHEIT => Self::Fahrenheit(raw),
            _ => Self::NotPresent,
        }
    }

    fn celsius(self) -> Option<f32> {
        match self {
            Self::Celsius(v) => Some(f32::from(v)),
            Self::Fahrenheit(v) => Some((f32::from(v) - 32.0) * 5.0 / 9.0),
            Self::NotPresent => None,
        }
    }
}

impl fmt::Display for Temperature {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Celsius(v) => write!(f, "{v} C"),
            Self::Fahrenheit(v) => write!(f, "{v} F ({:.1} C)", self.celsius().unwrap_or_default()),
            Self::NotPresent => f.write_str("not present"),
        }
    }
}

fn pci_address(pci: &PciInfo) -> String {
    let (device, function, bus) = (pci.word & 0x1f, (pci.word >> 5) & 0x7, (pci.word >> 8) & 0xff_ffff);
    format!("{:04x}:{bus:02x}:{device:02x}.{function}", pci.segment_id)
}

fn firmware_version(v: u32) -> String {
    let [major, minor, unit, dev] = v.to_be_bytes();
    format!("{major:02}.{minor:02}.{unit:02}.{dev:02}")
}

/// The `MPI2_IOCSTATUS_*` codes a CONFIG request can plausibly come back with.
fn ioc_status_name(status: u16) -> &'static str {
    match status {
        0x0001 => "INVALID_FUNCTION",
        0x0002 => "BUSY",
        0x0003 => "INVALID_SGL",
        0x0004 => "INTERNAL_ERROR",
        0x0005 => "INVALID_VPID",
        0x0006 => "INSUFFICIENT_RESOURCES",
        0x0007 => "INVALID_FIELD",
        0x0008 => "INVALID_STATE",
        0x0020 => "CONFIG_INVALID_ACTION",
        0x0021 => "CONFIG_INVALID_TYPE",
        0x0022 => "CONFIG_INVALID_PAGE",
        0x0023 => "CONFIG_INVALID_DATA",
        0x0024 => "CONFIG_NO_DEFAULTS",
        0x0025 => "CONFIG_CANT_COMMIT",
        _ => "unknown",
    }
}

// ------------------------------------------------------ prometheus rendering

/// One line of the text exposition format: the metric's labels plus its value.
#[derive(Clone, Debug, PartialEq)]
struct Sample {
    labels: Vec<(&'static str, String)>,
    celsius: f32,
}

/// Every sensor IO Unit Page 7 exposes for one controller, absent ones skipped.
fn samples_for(index: u32, info: &IocInfo, page: &[u8]) -> Vec<Sample> {
    let identity = [
        ("controller", index.to_string()),
        ("pci_address", pci_address(&info.pci_information)),
        ("adapter_type", adapter_type(info.adapter_type).to_owned()),
        ("firmware", firmware_version(info.firmware_version)),
    ];
    [("ioc", OFF_IOC_TEMPERATURE), ("board", OFF_BOARD_TEMPERATURE)]
        .into_iter()
        .filter_map(|(sensor, offset)| {
            let celsius = Temperature::from_page(page, offset).celsius()?;
            let mut labels = identity.to_vec();
            labels.push(("sensor", sensor.to_owned()));
            Some(Sample { labels, celsius })
        })
        .collect()
}

/// Label values only ever need `\`, `"` and newlines escaped.
fn escape_label(value: &str) -> String {
    value
        .chars()
        .flat_map(|c| match c {
            '\\' => vec!['\\', '\\'],
            '"' => vec!['\\', '"'],
            '\n' => vec!['\\', 'n'],
            other => vec![other],
        })
        .collect()
}

fn render(samples: &[Sample]) -> String {
    let mut out = format!(
        "# HELP {METRIC} Temperature reported by an LSI Fusion-MPT HBA sensor.\n\
         # TYPE {METRIC} gauge\n"
    );
    for sample in samples {
        let labels: Vec<String> = sample
            .labels
            .iter()
            .map(|(name, value)| format!("{name}=\"{}\"", escape_label(value)))
            .collect();
        // One decimal is plenty, and keeps Fahrenheit conversions from going ragged.
        let celsius = (sample.celsius * 10.0).round() / 10.0;
        out.push_str(&format!("{METRIC}{{{}}} {celsius}\n", labels.join(",")));
    }
    out
}

fn adapter_type(kind: u32) -> &'static str {
    match kind {
        0x03 => "SAS",
        0x04 | 0x05 => "SAS2",
        0x06 => "SAS3",
        0x07 => "SAS3.5",
        _ => "unknown",
    }
}

// ------------------------------------------------------------------- ioctls

fn iocinfo(fd: RawFd, ioc_number: u32) -> io::Result<IocInfo> {
    let mut info = IocInfo {
        hdr: IoctlHeader { ioc_number, ..IoctlHeader::default() },
        ..IocInfo::default()
    };
    // SAFETY: `MPT_IOCINFO`'s encoded size matches `IocInfo`, which is a `repr(C)` mirror
    // of the kernel's `struct mpt3_ioctl_iocinfo`; the driver only writes within it.
    let rc = unsafe { ioctl(fd, c_ulong::from(MPT_IOCINFO), &mut info as *mut IocInfo) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(info)
}

/// Submit one MPI2 CONFIG frame; the page body (if any) is DMA'd into `page`.
fn config_request(
    fd: RawFd,
    ioc_number: u32,
    request: ConfigRequest,
    page: &mut [u8],
) -> io::Result<ConfigReply> {
    let mut reply = ConfigReply::default();
    let mut command = MptCommand {
        hdr: IoctlHeader { ioc_number, ..IoctlHeader::default() },
        timeout: 10,
        reply_frame_buf_ptr: std::ptr::addr_of_mut!(reply) as usize,
        data_in_buf_ptr: if page.is_empty() { 0 } else { page.as_mut_ptr() as usize },
        data_out_buf_ptr: 0,
        sense_data_ptr: 0,
        max_reply_bytes: size_of::<ConfigReply>() as u32,
        data_in_size: page.len() as u32,
        data_out_size: 0,
        max_sense_bytes: 0,
        data_sge_offset: (offset_of!(ConfigRequest, page_buffer_sge) / 4) as u32,
        mf: request,
    };

    // SAFETY: `command` is at least `KARG_SIZE` bytes and its layout mirrors
    // `struct mpt3_ioctl_command`; the buffers we hand over stay alive for the call and
    // are exactly as large as the sizes we declare.
    let rc = unsafe { ioctl(fd, c_ulong::from(MPT_COMMAND), &mut command as *mut MptCommand) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }

    let status = reply.ioc_status & IOCSTATUS_MASK;
    if status != 0 {
        return Err(io::Error::other(format!(
            "config request failed: IOCStatus 0x{status:04x} ({}), IOCLogInfo 0x{:08x}",
            ioc_status_name(status),
            reply.ioc_log_info
        )));
    }
    Ok(reply)
}

/// The `PAGE_HEADER` probe frame; only `PageType`/`PageNumber` are meaningful in it.
fn io_unit_page7_probe() -> ConfigRequest {
    ConfigRequest {
        function: MPI2_FUNCTION_CONFIG,
        action: CONFIG_ACTION_PAGE_HEADER,
        header: PageHeader {
            page_number: IO_UNIT_PAGE_7,
            page_type: CONFIG_PAGETYPE_IO_UNIT,
            ..PageHeader::default()
        },
        ..ConfigRequest::default()
    }
}

/// Fetch IO Unit Page 7 (header round trip, then the page itself).
fn read_io_unit_page7(fd: RawFd, ioc_number: u32) -> io::Result<Vec<u8>> {
    let probe = io_unit_page7_probe();
    let header = config_request(fd, ioc_number, probe, &mut [])?.header;
    if header.page_type & CONFIG_PAGETYPE_MASK != CONFIG_PAGETYPE_IO_UNIT
        || header.page_number != IO_UNIT_PAGE_7
    {
        return Err(io::Error::other(format!(
            "unexpected page header: type 0x{:02x}, number {}",
            header.page_type, header.page_number
        )));
    }
    if header.page_length == 0 {
        return Err(io::Error::other("IO Unit Page 7 is not supported by this controller"));
    }

    let mut page = vec![0u8; usize::from(header.page_length) * 4];
    let read = ConfigRequest { action: CONFIG_ACTION_READ_CURRENT, header, ..probe };
    config_request(fd, ioc_number, read, &mut page)?;
    Ok(page)
}

// --------------------------------------------------------------------- main

struct Args {
    controller: Option<u32>,
    device: Option<String>,
}

impl Args {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, Box<dyn Error>> {
        let mut parsed = Args { controller: None, device: None };
        let mut args = args;
        while let Some(arg) = args.next() {
            let mut value = || args.next().ok_or_else(|| format!("{arg} needs an argument"));
            match arg.as_str() {
                "-c" | "--controller" => {
                    parsed.controller = Some(value()?.trim_start_matches("/c").parse()?);
                }
                "-d" | "--device" => parsed.device = Some(value()?),
                "-h" | "--help" => {
                    println!("{USAGE}");
                    std::process::exit(0);
                }
                other => return Err(format!("unknown argument: {other}\n{USAGE}").into()),
            }
        }
        Ok(parsed)
    }
}

fn open_control_device(explicit: Option<&str>) -> Result<(String, File), Box<dyn Error>> {
    let candidates: Vec<&str> = explicit.map_or_else(|| CTL_DEVICES.to_vec(), |path| vec![path]);
    let mut last_error = None;
    for path in candidates {
        match File::open(path) {
            Ok(file) => return Ok((path.to_owned(), file)),
            Err(error) => last_error = Some((path.to_owned(), error)),
        }
    }
    let (path, error) = last_error.expect("at least one candidate");
    Err(match error.kind() {
        io::ErrorKind::PermissionDenied => {
            format!("{path}: {error} — this needs root, try `run0 sas3temp`").into()
        }
        io::ErrorKind::NotFound => {
            format!("{path}: {error} — is the mpt3sas driver loaded?").into()
        }
        _ => format!("{path}: {error}").into(),
    })
}

fn main() -> Result<(), Box<dyn Error>> {
    let args = Args::parse(std::env::args().skip(1))?;
    let (path, device) = open_control_device(args.device.as_deref())?;
    let fd = device.as_raw_fd();

    let wanted: Vec<u32> = args.controller.map_or_else(|| (0..MAX_IOC_SCAN).collect(), |c| vec![c]);
    let controllers: Vec<(u32, IocInfo)> = wanted
        .into_iter()
        .filter_map(|n| iocinfo(fd, n).ok().map(|info| (n, info)))
        .collect();

    if controllers.is_empty() {
        return Err(match args.controller {
            Some(c) => format!("no controller {c} behind {path}").into(),
            None => format!("no controllers found behind {path}").into(),
        });
    }

    let mut samples = Vec::new();
    for (index, info) in controllers {
        let page = read_io_unit_page7(fd, index)?;
        samples.extend(samples_for(index, &info, &page));
    }
    print!("{}", render(&samples));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a synthetic IO Unit Page 7 body.
    fn page7(ioc: (u16, u8), board: (u16, u8)) -> Vec<u8> {
        let mut page = vec![0u8; 0x28];
        page[..4].copy_from_slice(&[0x05, 0x0a, IO_UNIT_PAGE_7, CONFIG_PAGETYPE_IO_UNIT]);
        page[OFF_IOC_TEMPERATURE..][..2].copy_from_slice(&ioc.0.to_le_bytes());
        page[OFF_IOC_TEMPERATURE + 2] = ioc.1;
        page[OFF_BOARD_TEMPERATURE..][..2].copy_from_slice(&board.0.to_le_bytes());
        page[OFF_BOARD_TEMPERATURE + 2] = board.1;
        page
    }

    #[test]
    fn decodes_celsius_and_absent_board_sensor() {
        let page = page7((47, UNIT_CELSIUS), (0, 0));
        assert_eq!(Temperature::from_page(&page, OFF_IOC_TEMPERATURE), Temperature::Celsius(47));
        assert_eq!(Temperature::from_page(&page, OFF_BOARD_TEMPERATURE), Temperature::NotPresent);
    }

    #[test]
    fn converts_fahrenheit_readings() {
        let page = page7((122, UNIT_FAHRENHEIT), (95, UNIT_FAHRENHEIT));
        let ioc = Temperature::from_page(&page, OFF_IOC_TEMPERATURE);
        assert_eq!(ioc, Temperature::Fahrenheit(122));
        assert_eq!(ioc.celsius(), Some(50.0));
        assert_eq!(Temperature::NotPresent.celsius(), None);
    }

    #[test]
    fn truncated_pages_do_not_panic() {
        for len in 0..0x18 {
            let page = page7((47, UNIT_CELSIUS), (30, UNIT_CELSIUS));
            let _ = Temperature::from_page(&page[..len], OFF_IOC_TEMPERATURE);
            let _ = Temperature::from_page(&page[..len], OFF_BOARD_TEMPERATURE);
        }
    }

    #[test]
    #[cfg(target_pointer_width = "64")]
    fn ioctl_numbers_match_the_kernel_abi() {
        assert_eq!(KARG_SIZE, 72); // sizeof(struct mpt3_ioctl_command) on LP64
        assert_eq!(MPT_COMMAND, 0xc048_4c14); // _IOWR('L', 20, 72)
        assert_eq!(MPT_IOCINFO, 0xc05c_4c11); // _IOWR('L', 17, 92)
        assert_eq!(offset_of!(ConfigRequest, page_buffer_sge) / 4, 7);
    }

    /// Regression: PageType 0x03 (MPI 1.x SCSI device) made the IOC answer
    /// IOCStatus 0x0021 CONFIG_INVALID_TYPE. IO Unit is type 0x00 in MPI2.
    #[test]
    fn probe_frame_asks_for_io_unit_page_7() {
        let probe = io_unit_page7_probe();
        assert_eq!(probe.function, MPI2_FUNCTION_CONFIG);
        assert_eq!(probe.action, CONFIG_ACTION_PAGE_HEADER);
        assert_eq!(probe.header.page_type & CONFIG_PAGETYPE_MASK, 0x00);
        assert_eq!(probe.header.page_number, 7);
        assert_eq!(ioc_status_name(0x0021), "CONFIG_INVALID_TYPE");
    }

    fn iocinfo_fixture() -> IocInfo {
        IocInfo {
            adapter_type: 0x06,
            firmware_version: 0x1000_0c00,
            pci_information: PciInfo { word: 0x03 << 8, segment_id: 0 },
            ..IocInfo::default()
        }
    }

    #[test]
    fn renders_one_labelled_gauge_per_sensor() {
        let page = page7((47, UNIT_CELSIUS), (30, UNIT_CELSIUS));
        let samples = samples_for(0, &iocinfo_fixture(), &page);
        assert_eq!(
            render(&samples),
            concat!(
                "# HELP lsi_hba_temperature_celsius ",
                "Temperature reported by an LSI Fusion-MPT HBA sensor.\n",
                "# TYPE lsi_hba_temperature_celsius gauge\n",
                "lsi_hba_temperature_celsius{controller=\"0\",pci_address=\"0000:03:00.0\",",
                "adapter_type=\"SAS3\",firmware=\"16.00.12.00\",sensor=\"ioc\"} 47\n",
                "lsi_hba_temperature_celsius{controller=\"0\",pci_address=\"0000:03:00.0\",",
                "adapter_type=\"SAS3\",firmware=\"16.00.12.00\",sensor=\"board\"} 30\n",
            )
        );
    }

    #[test]
    fn absent_sensors_are_omitted_and_fahrenheit_is_converted() {
        let page = page7((100, UNIT_FAHRENHEIT), (0, 0));
        let samples = samples_for(1, &iocinfo_fixture(), &page);
        assert_eq!(samples.len(), 1);
        assert!(render(&samples).ends_with("sensor=\"ioc\"} 37.8\n"));
        assert!(render(&samples).contains("controller=\"1\""));
    }

    #[test]
    fn label_values_are_escaped() {
        assert_eq!(escape_label(r#"a"b\c"#), r#"a\"b\\c"#);
        assert_eq!(escape_label("a\nb"), r"a\nb");
    }

    #[test]
    fn empty_output_still_carries_help_and_type() {
        assert_eq!(render(&[]).lines().count(), 2);
    }

    #[test]
    fn formats_identifiers_like_lspci_and_the_driver() {
        let pci = PciInfo { word: (0x03 << 8) | (0 << 5) | 0x00, segment_id: 0 };
        assert_eq!(pci_address(&pci), "0000:03:00.0");
        assert_eq!(firmware_version(0x1000_0c00), "16.00.12.00");
    }
}
