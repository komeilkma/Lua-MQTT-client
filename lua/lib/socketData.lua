-- @module socketData
-- @author komeilkma

require "link"
require "utils"
module(..., package.seeall)

local sockets = {}
local SENDSIZE = 11200

local INDEX_MAX = 256

local socketsConnected = 0

local function errorInd(error)
    local coSuspended = {}
    
    for _, c in pairs(sockets) do
        c.error = error
        if c.co and coroutine.status(c.co) == "suspended" then
            table.insert(coSuspended, c.co)
        end
    end
    
    for k, v in pairs(coSuspended) do
        if v and coroutine.status(v) == "suspended" then
            coroutine.resume(v, false, error)
        end
    end
end

sys.subscribe("IP_ERROR_IND", function()errorInd('IP_ERROR_IND') end)
local mt = {}
mt.__index = mt
local function socket(protocol, cert, tCoreExtPara)
    local ssl = protocol:match("SSL")
    local co = coroutine.running()
    if not co then
        log.warn("socket.socket: socket must be called in coroutine")
        return nil
    end
    local o = {
        id = nil,
        protocol = protocol,
        tCoreExtPara = tCoreExtPara,
        ssl = ssl,
        cert = cert,
        co = co,
        input = {},
        output = {},
        wait = "",
        connected = false,
        iSubscribe = false,
        subMessage = nil,
        isBlock = false,
        msg = nil,
        rcvProcFnc = nil,
    }
    return setmetatable(o, mt)
end

function tcp(ssl, cert, tCoreExtPara)
    return socket("TCP" .. (ssl == true and "SSL" or ""), (ssl == true) and cert or nil, tCoreExtPara)
end

function udp()
    return socket("UDP")
end

function mt:connect(address, port, timeout)
    assert(self.co == coroutine.running(), "socket:connect: coroutine mismatch")
    
    if not link.isReady() then
        log.info("socket.connect: ip not ready")
        return false
    end
    
    self.address = address
    self.port = port
    local tCoreExtPara = self.tCoreExtPara or {}
    local rcvBufferSize = tCoreExtPara.rcvBufferSize or 0
    
    local socket_connect_fnc = (type(socketcore.sock_conn_ext)=="function") and socketcore.sock_conn_ext or socketcore.sock_conn
    if self.protocol == 'TCP' then
        self.id = socket_connect_fnc(0, address, port, rcvBufferSize)
    elseif self.protocol == 'TCPSSL' then
        local cert = {hostName = address}
        local insist = 1
        if self.cert then
            if self.cert.caCert then
                if self.cert.caCert:sub(1, 1) ~= "/" then self.cert.caCert = "/lua/" .. self.cert.caCert end
                cert.caCert = io.readFile(self.cert.caCert)
            end
            if self.cert.clientCert then
                if self.cert.clientCert:sub(1, 1) ~= "/" then self.cert.clientCert = "/lua/" .. self.cert.clientCert end
                cert.clientCert = io.readFile(self.cert.clientCert)
            end
            if self.cert.clientKey then
                if self.cert.clientKey:sub(1, 1) ~= "/" then self.cert.clientKey = "/lua/" .. self.cert.clientKey end
                cert.clientKey = io.readFile(self.cert.clientKey)
            end
            insist = self.cert.insist == 0 and 0 or 1
        end
        self.id = socket_connect_fnc(2, address, port, cert, rcvBufferSize, insist)
    else
        self.id = socket_connect_fnc(1, address, port, rcvBufferSize)
    end
    if type(socketcore.sock_conn_ext)=="function" then
        if not self.id or self.id<0 then
            if self.id==-2 then
                require "http"
                http.request("GET", "119.29.29.29/d?dn=" .. address, nil, nil, nil, 40000,
                    function(result, statusCode, head, body)
                        log.info("socket.httpDnsCb", result, statusCode, head, body)
                        sys.publish("SOCKET_HTTPDNS_RESULT_"..address.."_"..port, result, statusCode, head, body)
                    end)
                local _, result, statusCode, head, body = sys.waitUntil("SOCKET_HTTPDNS_RESULT_"..address.."_"..port)
                if result and statusCode == "200" and body and body:match("^[%d%.]+") then
                    return self:connect(body:match("^([%d%.]+)"),port,timeout)                
                end
            end
            self.id = nil
        end
    end
    if not self.id then
        log.info("socket:connect: core sock conn error", self.protocol, address, port, self.cert)
        return false
    end
    log.info("socket:connect-coreid,prot,addr,port,cert,timeout", self.id, self.protocol, address, port, self.cert, timeout or 120)
    sockets[self.id] = self
    self.wait = "SOCKET_CONNECT"
    self.timerId = sys.timerStart(coroutine.resume, (timeout or 120) * 1000, self.co, false, "TIMEOUT")
    local result, reason = coroutine.yield()
    if self.timerId and reason ~= "TIMEOUT" then sys.timerStop(self.timerId) end
    if not result then
        log.info("socket:connect: connect fail", reason)
		if reason == "RESPONSE" then
            sockets[self.id] = nil
			self.id = nil
		end
        sys.publish("LIB_SOCKET_CONNECT_FAIL_IND", self.ssl, self.protocol, address, port)
        return false
    end
    log.info("socket:connect: connect ok")
    
    if not self.connected then
        self.connected = true
        socketsConnected = socketsConnected+1
        sys.publish("SOCKET_ACTIVE", socketsConnected>0)
    end
    
    return true, self.id
end

function mt:asyncSelect(keepAlive, pingreq)
    assert(self.co == coroutine.running(), "socket:asyncSelect: coroutine mismatch")
    if self.error then
        log.warn('socket.client:asyncSelect', 'error', self.error)
        return false
    end
    
    self.wait = "SOCKET_SEND"
    local dataLen = 0
    while #self.output ~= 0 do
        local data = table.concat(self.output)
        dataLen = string.len(data)
        self.output = {}
	local sendSize = self.protocol == "UDP" and 1472 or SENDSIZE
        for i = 1, dataLen, sendSize do

            socketcore.sock_send(self.id, data:sub(i, i + sendSize - 1))
            if self.timeout then
                self.timerId = sys.timerStart(coroutine.resume, self.timeout * 1000, self.co, false, "TIMEOUT")
            end

            local result, reason = coroutine.yield()
            if self.timerId and reason ~= "TIMEOUT" then sys.timerStop(self.timerId) end
            sys.publish("SOCKET_ASYNC_SEND", result)
            if not result then
                sys.publish("LIB_SOCKET_SEND_FAIL_IND", self.ssl, self.protocol, self.address, self.port)
                return false
            end
        end
    end
    self.wait = "SOCKET_WAIT"
    if dataLen>0 then sys.publish("SOCKET_SEND", self.id, true) end
    if keepAlive and keepAlive ~= 0 then
        if type(pingreq) == "function" then
            sys.timerStart(pingreq, keepAlive * 1000)
        else
            sys.timerStart(self.asyncSend, keepAlive * 1000, self, pingreq or "\0")
        end
    end
    return coroutine.yield()
end

function mt:getAsyncSend()
    if self.error then return 0 end
    return #(self.output)
end

function mt:asyncSend(data, timeout)
    if self.error then
        log.warn('socket.client:asyncSend', 'error', self.error)
        return false
    end
    self.timeout = timeout
    table.insert(self.output, data or "")
    if self.wait == "SOCKET_WAIT" then coroutine.resume(self.co, true) end
    return true
end

function mt:asyncRecv()
    if #self.input == 0 then return "" end
    if self.protocol == "UDP" then
        return table.remove(self.input)
    else
        local s = table.concat(self.input)
        self.input = {}
        if self.isBlock then table.insert(self.input, socketcore.sock_recv(self.msg.socket_index, self.msg.recv_len)) end
        return s
    end
end

function mt:send(data, timeout)
    assert(self.co == coroutine.running(), "socket:send: coroutine mismatch")
    if self.error then
        log.warn('socket.client:send', 'error', self.error)
        return false
    end
    log.debug("socket.send", "total " .. string.len(data or "") .. " bytes", "first 30 bytes", tostring(data))
    local sendSize = self.protocol == "UDP" and 1472 or SENDSIZE
    for i = 1, string.len(data or ""), sendSize do
        self.wait = "SOCKET_SEND"
        socketcore.sock_send(5, data:sub(i, i + sendSize - 1))
        self.timerId = sys.timerStart(coroutine.resume, (timeout or 120) * 1000, self.co, false, "TIMEOUT")
        local result, reason = coroutine.yield()
        if self.timerId and reason ~= "TIMEOUT" then sys.timerStop(self.timerId) end
        if not result then
            log.info("socket:send", "send fail", reason)
            sys.publish("LIB_SOCKET_SEND_FAIL_IND", self.ssl, self.protocol, self.address, self.port)
            return false
        end
    end
    return true
end

function mt:recv(timeout, msg, msgNoResume)
    assert(self.co == coroutine.running(), "socket:recv: coroutine mismatch")
    if self.error then
        log.warn('socket.client:recv', 'error', self.error)
        return false
    end
    self.msgNoResume = msgNoResume
    if msg and not self.iSubscribe then
        self.iSubscribe = msg
        self.subMessage = function(data)
            if self.wait == "+RECEIVE" and not self.msgNoResume then
                if data then table.insert(self.output, data) end
                coroutine.resume(self.co, 0xAA)
            end
        end
        sys.subscribe(msg, self.subMessage)
    end
    if msg and #self.output > 0 then sys.publish(msg, false) end
    if #self.input == 0 then
        self.wait = "+RECEIVE"
        if timeout and timeout > 0 then
            local r, s = sys.wait(timeout)
            if r == nil then
                return false, "timeout"
            elseif r == 0xAA then
                local dat = table.concat(self.output)
                self.output = {}
                return false, msg, dat
            else
                return r, s
            end
        else
            local r, s = coroutine.yield()
            if r == 0xAA then
                local dat = table.concat(self.output)
                self.output = {}
                return false, msg, dat
            else
                return r, s
            end
        end
    end
    
    if self.protocol == "UDP" then
        local s = table.remove(self.input)
        return true, s
    else
        local s = table.concat(self.input)
        self.input = {}
        if self.isBlock then table.insert(self.input, socketcore.sock_recv(self.msg.socket_index, self.msg.recv_len)) end
        return true, s
    end
end

function mt:close()
    assert(self.co == coroutine.running(), "socket:close: coroutine mismatch")
    if self.iSubscribe then
        sys.unsubscribe(self.iSubscribe, self.subMessage)
        self.iSubscribe = false
    end
    log.info("socket:sock_close", self.id)
    local result, reason
    
    if self.id then
        socketcore.sock_close(self.id)
        self.wait = "SOCKET_CLOSE"
        while true do
            result, reason = coroutine.yield()
            if reason == "RESPONSE" then break end
        end
    end
    if self.connected then
        self.connected = false
        if socketsConnected>0 then
            socketsConnected = socketsConnected-1
        end
        sys.publish("SOCKET_ACTIVE", socketsConnected>0)
    end
    if self.input then
        self.input = {}
    end
    --end
    if self.id ~= nil then
        sockets[self.id] = nil
    end
end

function mt:setRcvProc(rcvCbFnc)
    assert(self.co == coroutine.running(), "socket:setRcvProc: coroutine mismatch")
    self.rcvProcFnc = rcvCbFnc
end

local function on_response(msg)
    local t = {
        [rtos.MSG_SOCK_CLOSE_CNF] = 'SOCKET_CLOSE',
        [rtos.MSG_SOCK_SEND_CNF] = 'SOCKET_SEND',
        [rtos.MSG_SOCK_CONN_CNF] = 'SOCKET_CONNECT',
    }
    if not sockets[msg.socket_index] then
        log.warn('response on nil socket', msg.socket_index, t[msg.id], msg.result)
        return
    end
    if sockets[msg.socket_index].wait ~= t[msg.id] then
        log.warn('response on invalid wait', sockets[msg.socket_index].id, sockets[msg.socket_index].wait, t[msg.id], msg.socket_index)
        return
    end
    log.info("socket:on_response:", msg.socket_index, t[msg.id], msg.result)
    if type(socketcore.sock_destroy) == "function" then
        if (msg.id == rtos.MSG_SOCK_CONN_CNF and msg.result ~= 0) or msg.id == rtos.MSG_SOCK_CLOSE_CNF then
            socketcore.sock_destroy(msg.socket_index)
        end
    end
    coroutine.resume(sockets[msg.socket_index].co, msg.result == 0, "RESPONSE")
end

rtos.on(rtos.MSG_SOCK_CLOSE_CNF, on_response)
rtos.on(rtos.MSG_SOCK_CONN_CNF, on_response)
rtos.on(rtos.MSG_SOCK_SEND_CNF, on_response)
rtos.on(rtos.MSG_SOCK_CLOSE_IND, function(msg)
    log.info("socket.rtos.MSG_SOCK_CLOSE_IND")
    if not sockets[msg.socket_index] then
        log.warn('close ind on nil socket', msg.socket_index, msg.id)
        return
    end
    if sockets[msg.socket_index].connected then
        sockets[msg.socket_index].connected = false
        if socketsConnected>0 then
            socketsConnected = socketsConnected-1
        end
        sys.publish("SOCKET_ACTIVE", socketsConnected>0)
    end
    sockets[msg.socket_index].error = 'CLOSED'
    
    --[[
    if type(socketcore.sock_destroy) == "function" then
        socketcore.sock_destroy(msg.socket_index)
    end]]
    sys.publish("LIB_SOCKET_CLOSE_IND", sockets[msg.socket_index].ssl, sockets[msg.socket_index].protocol, sockets[msg.socket_index].address, sockets[msg.socket_index].port)
    coroutine.resume(sockets[msg.socket_index].co, false, "CLOSED")
end)
rtos.on(rtos.MSG_SOCK_RECV_IND, function(msg)
    if not sockets[msg.socket_index] then
        log.warn('close ind on nil socket', msg.socket_index, msg.id)
        return
    end

    log.debug("socket.recv", msg.recv_len, sockets[msg.socket_index].rcvProcFnc)
    if sockets[msg.socket_index].rcvProcFnc then
        sockets[msg.socket_index].rcvProcFnc(socketcore.sock_recv, msg.socket_index, msg.recv_len)
    else
        if sockets[msg.socket_index].wait == "+RECEIVE" then
            coroutine.resume(sockets[msg.socket_index].co, true, socketcore.sock_recv(msg.socket_index, msg.recv_len))
        else
            if #sockets[msg.socket_index].input > INDEX_MAX then
                log.error("socket recv", "out of stack", "block")
                sockets[msg.socket_index].isBlock = true
                sockets[msg.socket_index].msg = msg
            else
                sockets[msg.socket_index].isBlock = false
                table.insert(sockets[msg.socket_index].input, socketcore.sock_recv(msg.socket_index, msg.recv_len))
            end
            sys.publish("SOCKET_RECV", msg.socket_index)
        end
    end
end)

function setTcpResendPara(retryCnt, retryMaxTimeout)
    ril.request("AT+TCPUSERPARAM=6," .. (retryCnt or 4) .. ",7200," .. (retryMaxTimeout or 16))
end

function setDnsParsePara(retryCnt, retryTimeoutMulti)
    ril.request("AT*DNSTMOUT="..(retryCnt or 4)..","..(retryTimeoutMulti or 4))
end

function printStatus()
    for _, client in pairs(sockets) do
        for k, v in pairs(client) do
            log.info('socket.printStatus', 'client', client.id, k, v)
        end
    end
end

function setLowPower(tm)
    ril.request("AT*RTIME="..tm)
end

