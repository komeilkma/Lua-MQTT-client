-- @module socket
-- @author komeilkma
require "socketData"
module(..., package.seeall)

socket.isReady = link.isReady
local tSocketModule = nil
local function init()
    tSocketModule = tSocketModule or {
        [link.CELLULAR] = socketData,
        [link.CH395] = socketCh395,
        [link.W5500] = socketW5500
    }
end

function tcp(ssl, cert, tCoreExtPara)
    init()
    return tSocketModule[link.getNetwork()].tcp(ssl, cert, tCoreExtPara)
end

function udp()
    init()
    return tSocketModule[link.getNetwork()].udp()
end

function setTcpResendPara(retryCnt, retryMaxTimeout)
    init()
    return tSocketModule[link.getNetwork()].setTcpResendPara(retryCnt, retryMaxTimeout)    
end

function setDnsParsePara(retryCnt, retryTimeoutMulti)
    init()
    return tSocketModule[link.getNetwork()].setDnsParsePara(retryCnt, retryTimeoutMulti)
end

function printStatus()
    init()
    return tSocketModule[link.getNetwork()].printStatus()
end

function setLowPower(tm)
    init()
    return tSocketModule[link.getNetwork()].setLowPower(tm)
end

