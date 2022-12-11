-- @module mqtt
-- @author komeilkma
require "log"
require "socket"
require "utils"
module(..., package.seeall)

local CONNECT, CONNACK, PUBLISH, PUBACK, PUBREC, PUBREL, PUBCOMP, SUBSCRIBE, SUBACK, UNSUBSCRIBE, UNSUBACK, PINGREQ, PINGRESP, DISCONNECT = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
local CLIENT_COMMAND_TIMEOUT = 60000

local function encodeLen(len)
    local s = ""
    local digit
    repeat
        digit = len % 128
        len = (len - digit) / 128
        if len > 0 then
            digit = bit.bor(digit, 0x80)
        end
        s = s .. string.char(digit)
    until (len <= 0)
    return s
end

local function encodeUTF8(s)
    if not s or #s == 0 then
        return ""
    else
        return pack.pack(">P", s)
    end
end

local function packCONNECT(clientId, keepAlive, username, password, cleanSession, will, version)
    local content = pack.pack(">PbbHPAAAA",
        version == "3.1" and "MQIsdp" or "MQTT",
        version == "3.1" and 3 or 4,
        (#username == 0 and 0 or 1) * 128 + (#password == 0 and 0 or 1) * 64 + will.retain * 32 + will.qos * 8 + will.flag * 4 + cleanSession * 2,
        keepAlive,
        clientId,
        encodeUTF8(will.topic),
        encodeUTF8(will.payload),
        encodeUTF8(username),
        encodeUTF8(password))
    return pack.pack(">bAA",
        CONNECT * 16,
        encodeLen(string.len(content)),
        content)
end

local function packSUBSCRIBE(dup, packetId, topics)
    local header = SUBSCRIBE * 16 + dup * 8 + 2
    local data = pack.pack(">H", packetId)
    for topic, qos in pairs(topics) do
        data = data .. pack.pack(">Pb", topic, qos)
    end
    return pack.pack(">bAA", header, encodeLen(#data), data)
end

local function packUNSUBSCRIBE(dup, packetId, topics)
    local header = UNSUBSCRIBE * 16 + dup * 8 + 2
    local data = pack.pack(">H", packetId)
    for k, topic in pairs(topics) do
        data = data .. pack.pack(">P", topic)
    end
    return pack.pack(">bAA", header, encodeLen(#data), data)
end

local function packPUBLISH(dup, qos, retain, packetId, topic, payload)
    local header = PUBLISH * 16 + dup * 8 + qos * 2 + retain
    local len = 2 + #topic + #payload
    if qos > 0 then
        return pack.pack(">bAPHA", header, encodeLen(len + 2), topic, packetId, payload)
    else
        return pack.pack(">bAPA", header, encodeLen(len), topic, payload)
    end
end

local function packACK(id, dup, packetId)
    return pack.pack(">bbH", id * 16 + dup * 8 + (id == PUBREL and 1 or 0) * 2, 0x02, packetId)
end

local function packZeroData(id, dup, qos, retain)
    dup = dup or 0
    qos = qos or 0
    retain = retain or 0
    return pack.pack(">bb", id * 16 + dup * 8 + qos * 2 + retain, 0)
end

local function unpack(s)
    if #s < 2 then return end
    log.debug("mqtt.unpack", #s, string.toHex(string.sub(s, 1, 50)))
    
    local len = 0
    local multiplier = 1
    local pos = 2
    
    repeat
        if pos > #s then return end
        local digit = string.byte(s, pos)
        len = len + ((digit % 128) * multiplier)
        multiplier = multiplier * 128
        pos = pos + 1
    until digit < 128
    
    if #s < len + pos - 1 then return end
    
    local header = string.byte(s, 1)
    
    local packet = {id = (header - (header % 16)) / 16, dup = ((header % 16) - ((header % 16) % 8)) / 8, qos = bit.band(header, 0x06) / 2, retain = bit.band(header, 0x01)}
    local nextpos
    
    if packet.id == CONNACK then
        nextpos, packet.ackFlag, packet.rc = pack.unpack(s, "bb", pos)
    elseif packet.id == SUBACK then
        nextpos, packet.ackFlag, packet.rc = pack.unpack(s, "bb", pos)
        if len >= 2 then
            nextpos, packet.packetId = pack.unpack(s, ">H", pos)
            packet.grantedQos = string.sub(s, nextpos, pos + len - 1)
        else
            packet.packetId = 0
            packet.grantedQos = ""
        end
    elseif packet.id == PUBLISH then
        nextpos, packet.topic = pack.unpack(s, ">P", pos)
        if packet.qos > 0 then
            nextpos, packet.packetId = pack.unpack(s, ">H", nextpos)
        end
        packet.payload = string.sub(s, nextpos, pos + len - 1)
    elseif packet.id ~= PINGRESP then
        if len >= 2 then
            nextpos, packet.packetId = pack.unpack(s, ">H", pos)
        else
            packet.packetId = 0
        end
    end
    
    return packet, pos + len
end

local mqttc = {}
mqttc.__index = mqttc

function client(clientId, keepAlive, username, password, cleanSession, will, version)
    local o = {}
    local packetId = 1
    
    if will then
        will.flag = 1
    else
        will = {flag = 0, qos = 0, retain = 0, topic = "", payload = ""}
    end
    
    o.clientId = clientId
    o.keepAlive = keepAlive or 300
    o.username = username or ""
    o.password = password or ""
    o.cleanSession = cleanSession or 1
    o.version = version or "3.1.1"
    o.will = will
    o.commandTimeout = CLIENT_COMMAND_TIMEOUT
    o.cache = {}
    o.inbuf = ""
    o.connected = false
    o.getNextPacketId = function()
        packetId = packetId == 65535 and 1 or (packetId + 1)
        return packetId
    end
    o.lastOTime = 0
    
    setmetatable(o, mqttc)
    
    return o
end

function mqttc:checkKeepAlive()
    if self.keepAlive == 0 then return true end
    if os.time() - self.lastOTime >= self.keepAlive then
        if not self:write(packZeroData(PINGREQ)) then
            log.info("mqtt.client:", "pingreq send fail")
            return false
        end
    end
    return true
end

function mqttc:write(data)
    log.debug("mqtt.client:write", string.toHex(string.sub(data, 1, 50)))
    self.io = socket.tcp()
    local r = self.io:send(data)
    if r then self.lastOTime = os.time() end
    return r
end

function mqttc:read(timeout, msg, msgNoResume)
    if not self:checkKeepAlive() then
        log.warn("mqtt.read checkKeepAlive fail")
        return false
    end
    
    local packet, nextpos = unpack(self.inbuf)
    if packet then
        self.inbuf = string.sub(self.inbuf, nextpos)
        return true, packet
    end
    
    while true do
        local recvTimeout
        
        if self.keepAlive == 0 then
            recvTimeout = timeout
        else
            local kaTimeout = (self.keepAlive - (os.time() - self.lastOTime)) * 1000
            recvTimeout = kaTimeout > timeout and timeout or kaTimeout
        end
        
        local r, s, p = self.io:recv(recvTimeout == 0 and 5 or recvTimeout, msg, msgNoResume)
        if r then
            self.inbuf = self.inbuf .. s
        elseif s == "timeout" then 
            if not self:checkKeepAlive() then
                return false
            elseif timeout <= recvTimeout then
                return false, "timeout"
            else
                timeout = timeout - recvTimeout
            end
        else 
            return r, s, p
        end
        local packet, nextpos = unpack(self.inbuf)
        if packet then
            self.inbuf = string.sub(self.inbuf, nextpos)
            if packet.id ~= PINGRESP then
                return true, packet
            end
        end
    end
end

function mqttc:waitfor(id, timeout, msg, msgNoResume)
    for index, packet in ipairs(self.cache) do
        if packet.id == id then
            return true, table.remove(self.cache, index)
        end
    end
    
    while true do
        local insertCache = true
        local r, data, param = self:read(timeout, msg, msgNoResume)
        if r then
            if data.id == PUBLISH then
                if data.qos > 0 then
                    if not self:write(packACK(data.qos == 1 and PUBACK or PUBREC, 0, data.packetId)) then
                        log.info("mqtt.client:waitfor", "send publish ack failed", data.qos)
                        return false
                    end
                end
            elseif data.id == PUBREC or data.id == PUBREL then
                if not self:write(packACK(data.id == PUBREC and PUBREL or PUBCOMP, 0, data.packetId)) then
                    log.info("mqtt.client:waitfor", "send ack fail", data.id == PUBREC and "PUBREC" or "PUBCOMP")
                    return false
                end
                insertCache = false
            end
            
            if data.id == id then
                return true, data
            end
            if insertCache then table.insert(self.cache, data) end
        else
            return false, data, param
        end
    end
end

function mqttc:connect(host, port, transport, cert, timeout)
    if self.connected then
        log.info("mqtt.client:connect", "has connected")
        return false
    end
    
    if self.io then
        self.io:close()
        self.io = nil
    end
    
    if transport and transport ~= "tcp" and transport ~= "tcp_ssl" then
        log.info("mqtt.client:connect", "invalid transport", transport)
        return false
    end
    
    self.io = socket.tcp(transport == "tcp_ssl" or type(cert) == "table", cert)

    if not self:write(packCONNECT(self.clientId, self.keepAlive, self.username, self.password, self.cleanSession, self.will, self.version)) then
        log.info("mqtt.client:connect", "send fail")
        return false
    end
    
    local r, packet = self:waitfor(CONNACK, self.commandTimeout, nil, true)

    if (not r) or (not packet) or packet.rc ~= 0 then
        log.info("mqtt.client:connect", "connack error", r and packet.rc or -1)
        return false, packet and packet.rc or -1
    end
    
    self.connected = true
    
    return true
end

function mqttc:subscribe(topic, qos)
    if not self.connected then
        log.info("mqtt.client:subscribe", "not connected")
        return false
    end
    
    local topics
    if type(topic) == "string" then
        topics = {[topic] = qos and qos or 0}
    else
        topics = topic
    end
    
    if not self:write(packSUBSCRIBE(0, self.getNextPacketId(), topics)) then
        log.info("mqtt.client:subscribe", "send failed")
        return false
    end
    
    local r, packet = self:waitfor(SUBACK, self.commandTimeout, nil, true)
    if not r then
        log.info("mqtt.client:subscribe", "wait ack failed")
        return false
    end
    
    if not (packet.grantedQos and packet.grantedQos~="" and not packet.grantedQos:match(string.char(0x80))) then
        log.info("mqtt.client:subscribe", "suback grant qos error", packet.grantedQos)
        return false
    end
    
    return true
end

function mqttc:publish(topic, payload, qos, retain)
    if not self.connected then
        log.info("mqtt.client:publish", "not connected")
        return false
    end
    
    qos = qos or 0
    retain = retain or 0
    
    if not self:write(packPUBLISH(0, qos, retain, qos > 0 and self.getNextPacketId() or 0, topic, payload)) then
        log.info("mqtt.client:publish", "socket send failed")
        return false
    end
    
    if qos == 0 then return true end
    
    if not self:waitfor(qos == 1 and PUBACK or PUBCOMP, self.commandTimeout, nil, true) then
        log.warn("mqtt.client:publish", "wait ack timeout")
        return false
    end
    
    return true
end

function mqttc:receive(timeout, msg)
    if not self.connected then
        log.info("mqtt.client:receive", "not connected")
        return false
    end
    
    return self:waitfor(PUBLISH, timeout, msg)
end

function mqttc:disconnect()
    if self.io then
        if self.connected then self:write(packZeroData(DISCONNECT)) end
        self.io:close()
        self.io = nil
    end
    self.cache = {}
    self.inbuf = ""
    self.connected = false
end
