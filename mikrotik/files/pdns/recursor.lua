local ipv6_block_set = newDS()
ipv6_block_set:add{
    "google.com"
}

function preresolve(dq)
    if dq.qtype ~= pdns.AAAA then
        return false
    end
    if not ipv6_block_set:check(dq.qname) then
        return false
    end

    dq.appliedPolicy.policyKind = pdns.policykinds.NODATA
    return false
end
