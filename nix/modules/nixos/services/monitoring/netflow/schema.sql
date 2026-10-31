-- Applied by vector's ExecStartPre on every start, so everything is IF NOT EXISTS.
-- Changing an existing table needs a manual ALTER (or DROP) on islandfox.

CREATE DATABASE IF NOT EXISTS netflow;

-- Our own space: RFC1918, CGNAT, loopback, link-local, multicast, ULA and our public /48.
-- IPv4 is stored IPv4-mapped, hence the ::ffff: prefixes.
CREATE FUNCTION IF NOT EXISTS foxdenInternal AS (addr) -> arrayExists(
    range -> isIPAddressInRange(IPv6NumToString(addr), range),
    [
        '::ffff:10.0.0.0/104',
        '::ffff:172.16.0.0/108',
        '::ffff:192.168.0.0/112',
        '::ffff:100.64.0.0/106',
        '::ffff:127.0.0.0/104',
        '::ffff:169.254.0.0/112',
        '::ffff:224.0.0.0/100',
        '::ffff:0.0.0.0/104',
        '::/127',
        'fc00::/7',
        'fe80::/10',
        'ff00::/8',
        '2a0e:7d44:f069::/48'
    ]
);

CREATE TABLE IF NOT EXISTS netflow.flows
(
    time_received DateTime CODEC(DoubleDelta, ZSTD),
    flow_start DateTime CODEC(DoubleDelta, ZSTD),
    flow_end DateTime CODEC(DoubleDelta, ZSTD),
    type LowCardinality(String),
    sampler IPv6,
    etype LowCardinality(String),
    proto LowCardinality(String),
    src_addr IPv6,
    dst_addr IPv6,
    src_port UInt16,
    dst_port UInt16,
    bytes UInt64,
    packets UInt64,
    in_if UInt32,
    out_if UInt32,
    tcp_flags UInt16,
    sampling_rate UInt64,
    src_external Bool MATERIALIZED NOT foxdenInternal(src_addr),
    dst_external Bool MATERIALIZED NOT foxdenInternal(dst_addr),
    -- External client talking to one of our listening ports. Replies to our own
    -- outbound connections come from a low port to a high one, so they are excluded.
    inbound Bool MATERIALIZED src_external AND dst_port < src_port
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time_received)
ORDER BY (time_received, dst_port)
TTL time_received + INTERVAL 30 DAY;

-- Per-minute rollup of inbound traffic per service, kept longer for baselines
CREATE TABLE IF NOT EXISTS netflow.inbound_1m
(
    minute DateTime,
    dst_addr IPv6,
    dst_port UInt16,
    proto LowCardinality(String),
    flows SimpleAggregateFunction(sum, UInt64),
    bytes SimpleAggregateFunction(sum, UInt64),
    packets SimpleAggregateFunction(sum, UInt64),
    sources AggregateFunction(uniq, IPv6),
    -- Source /24 (IPv4) or /48 (IPv6). A flood from as many prefixes as addresses is a botnet.
    prefixes AggregateFunction(uniq, String)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(minute)
ORDER BY (minute, dst_port, proto, dst_addr)
TTL minute + INTERVAL 90 DAY;

CREATE MATERIALIZED VIEW IF NOT EXISTS netflow.inbound_1m_mv TO netflow.inbound_1m AS
SELECT
    toStartOfMinute(time_received) AS minute,
    dst_addr,
    dst_port,
    proto,
    count() AS flows,
    sum(bytes) AS bytes,
    sum(packets) AS packets,
    uniqState(src_addr) AS sources,
    uniqState(cutIPv6(src_addr, 10, 1)) AS prefixes
FROM netflow.flows
WHERE inbound
GROUP BY minute, dst_addr, dst_port, proto;
