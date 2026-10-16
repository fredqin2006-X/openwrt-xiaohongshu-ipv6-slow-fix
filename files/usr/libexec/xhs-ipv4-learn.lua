-- Read a live pcap stream in RAM. Only matching domain + public destination
-- addresses reach nftables. No request URLs, cookies or payloads are logged.
local dry = arg[1] == '--dry-run'
local domains = {}
for line in io.lines(dry and arg[2] or '/etc/xhs-ipv4/domains') do
    domains[#domains + 1] = line:lower()
end
local function matches(host)
    if not host then return false end
    host = host:lower():gsub('%.$', ''):gsub(':%d+$', '')
    for _, domain in ipairs(domains) do
        if host == domain or host:sub(-#domain-1) == '.' .. domain then return true end
    end
    return false
end
local function u16(s, p)
    local a,b=s:byte(p,p+1); if not b then return nil end
    return a*256+b
end
local function u32(s,p,little)
    local a,b,c,d=s:byte(p,p+3); if not d then return nil end
    if little then return a+b*256+c*65536+d*16777216 end
    return a*16777216+b*65536+c*256+d
end
local function tls_host(s)
    if s:byte(1) ~= 22 or s:byte(6) ~= 1 or #s < 44 then return nil end
    local pos = 44
    pos = pos + 1 + s:byte(pos)
    local size = u16(s,pos); if not size then return nil end
    pos=pos+2+size
    size=s:byte(pos); if not size then return nil end
    pos=pos+1+size
    size=u16(s,pos); if not size then return nil end
    local last=math.min(pos+2+size-1,#s)
    pos=pos+2
    while pos+3<=last do
        local typ,n=u16(s,pos),u16(s,pos+2)
        local body=pos+4
        if typ==0 and body+n-1<=#s then
            local q=body+2
            while q+2<body+n do
                local kind,len=s:byte(q),u16(s,q+1)
                if not len or q+2+len>=body+n then break end
                if kind==0 then return s:sub(q+3,q+2+len) end
                q=q+3+len
            end
        end
        pos=body+n
    end
end
local learned,flows,last_gc={},{},0
local function learn(host,addr,now)
    if not matches(host) then return end
    if learned[addr] and now-learned[addr]<10 then return end
    learned[addr]=now
    if dry then
        io.write(host:lower(),' ',addr,'\n')
    else
        -- addr is built solely from 16 raw IPv6 bytes, never from packet text.
        local rc=os.execute("nft add element inet xhs_ipv4 targets6 '{ "..addr.." timeout 1h }' 2>/dev/null")
        if rc~=0 then learned[addr]=nil end
    end
end
local header=io.read(24)
assert(header and #header==24,'missing pcap header')
local magic=header:sub(1,4)
local little=magic=='\212\195\178\161' or magic=='\077\060\178\161'
assert(little or magic=='\161\178\195\212' or magic=='\161\178\060\077','unsupported pcap format')
local link=u32(header,21,little)
local function inspect(s,now)
    local p
    if link==1 then
        local ether=u16(s,13); p=15
        while ether==0x8100 or ether==0x88a8 do ether=u16(s,p+2); p=p+4 end
        if ether~=0x86dd then return end
    elseif link==276 then
        if u16(s,1)~=0x86dd then return end; p=21
    elseif link==113 then
        if u16(s,15)~=0x86dd then return end; p=17
    else return end
    if #s<p+39 or s:byte(p)<96 or s:byte(p)>111 then return end
    local dest=p+24
    if s:byte(dest)<0x20 or s:byte(dest)>0x3f then return end
    local words={}
    for i=0,7 do words[#words+1]=string.format('%x',u16(s,dest+i*2)) end
    local addr=table.concat(words,':')
    local proto,q=s:byte(p+6),p+40
    while proto==0 or proto==43 or proto==60 do
        if #s<q+1 then return end
        proto,q=s:byte(q),q+(s:byte(q+1)+1)*8
    end
    if proto~=6 or #s<q+19 then return end
    local port=u16(s,q+2)
    if port~=80 and port~=443 then return end
    local offset=math.floor(s:byte(q+12)/16)*4
    if offset<20 then return end
    local data=s:sub(q+offset)
    if #data==0 then return end
    local seq=u32(s,q+4,false)
    local key=s:sub(p+8,p+39)..s:sub(q,q+3)
    if data:byte(1)==22 or data:match('^[A-Z]+ ') then
        flows[key]={seq=seq,data=data,at=now}
    elseif flows[key] then
        local f=flows[key]
        local delta=(seq-f.seq)%4294967296
        if delta<=#f.data and delta+#data>#f.data and delta+#data<=16384 then
            f.data=f.data..data:sub(#f.data-delta+1); f.at=now
        end
    end
    local flow=flows[key]
    if not flow then return end
    local host=tls_host(flow.data) or flow.data:match('\r\n[Hh][Oo][Ss][Tt]:%s*([^\r\n ]+)')
    if host then learn(host,addr,now); flows[key]=nil end
    if now-last_gc>10 then
        local count=0
        for k,f in pairs(flows) do
            count=count+1
            if now-f.at>15 or count>1024 then flows[k]=nil end
        end
        for k,t in pairs(learned) do if now-t>3600 then learned[k]=nil end end
        last_gc=now
    end
end
while true do
    local h=io.read(16)
    if not h then break end
    assert(#h==16,'short pcap packet header')
    local n=u32(h,9,little)
    assert(n and n<=262144,'invalid pcap capture length')
    local packet=io.read(n)
    if not packet or #packet<n then break end
    inspect(packet,dry and u32(h,1,little) or os.time())
end
