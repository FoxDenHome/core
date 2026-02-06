local qtype_AAAA = pdns.AAAA
local policy_NODATA = pdns.policykinds.NODATA

local ipv6_block_set = newDS()
ipv6_block_set:add{
    "google.com"
}

function preresolve(dq)
    if dq.qtype ~= qtype_AAAA then
        return false
    end
    if not ipv6_block_set:check(dq.qname) then
        return false
    end

    dq.appliedPolicy.policyKind = policy_NODATA
    return false
end
