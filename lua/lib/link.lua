-- @module link
-- @author komeilkma

require "net"
module(..., package.seeall)

local publish = sys.publish
local request = ril.request
local ipAddr = ""
local gprsAttached
local cid_manual = 5
local readyTable = {false, false, false}
CELLULAR = 1
CH395 = 2
W5500 = 3
local network = CELLULAR

function setReady(mode, state)
    readyTable[mode] = state
end
function getIp()
    return ipAddr
end
function isReady()
    return readyTable[network]
end

local apnname, username, password
local dnsIP
local authProt, authApn, authUser, authPassword

function setAPN(apn, user, pwd)
    apnname, username, password = apn, user, pwd
end

function setDnsIP(ip1, ip2)
    dnsIP = "\"" .. (ip1 or "") .. "\",\"" .. (ip2 or "") .. "\""
end

local function setCgdf()
    request("AT+AUTOAPN=0")
    request('AT*CGDFLT=1,"IP","' .. authApn .. '",,,,,,,,,,,,,,,,,,1')
    request('AT*CGDFAUTH=1,' .. authProt .. ',"' .. authUser .. '","' .. authPassword .. '"', nil, function(cmd, result)
        if result then
            sys.restart("CGDFAUTH")
        else
            sys.timerStart(setCgdf, 5000)
        end
    end)
end

function setAuthApn(prot, apn, user, pwd)
    request('AT+CPNETAPN=2,"' .. apn .. '","' .. user .. '","' .. pwd .. '",' .. prot)
end

local function Pdp_Act()
    log.info("link.Pdp_Act", readyTable[CELLULAR], net.getNetMode(), gprsAttached)
    if readyTable[CELLULAR] then
        request("AT+CGDCONT?", nil, cgdcontRsp)
        return
    end
    if net.getNetMode() == net.NetMode_LTE then
        if not gprsAttached then
            gprsAttached = true
            sys.publish("GPRS_ATTACH", true)
        end
        if not apnname then
            sys.timerStart(pdpCmdCnf, 1000, "SET_PDP_4G_WAITAPN", true)
        else
            request("AT+CGDCONT?", nil, cgdcontRsp)
        end
    else
        request('AT+CGATT?')
    end
end

local function procshut(curCmd, result, respdata, interdata)
    if network~=CELLULAR then
        return
    end
    if IsCidActived(cid_manual, interdata) then
        ril.request(string.format('AT+CGACT=0,%d', cid_manual), nil, function(cmd, result)
            if result then
                readyTable[CELLULAR] = false
                sys.publish('IP_ERROR_IND')

                if net.getState() ~= 'REGISTERED' then
                    return
                end
                sys.timerStart(Pdp_Act, 2000)
            end
        end)
    else
        readyTable[CELLULAR] = false
        sys.publish('IP_ERROR_IND')

        if net.getState() ~= 'REGISTERED' then
            return
        end
        sys.timerStart(Pdp_Act, 2000)
    end
end

function shut()
    if network~=CELLULAR then
        return
    end
    readyTable[CELLULAR] = false
    sys.publish('IP_ERROR_IND')

    if net.getState() ~= 'REGISTERED' then
        return
    end
    sys.timerStart(Pdp_Act, 2000)
end

function analysis_cgdcont(data)
    local tmp, loc, result
    while data do
        _, loc = string.find(data, "\r\n")
        if loc then
            tmp = string.sub(data, 1, loc)
            data = string.sub(data, loc + 1, -1)
            log.info("analysis_cgdcont ", tmp, loc, data)
        else
            tmp = data
            data = nil
            log.info("analysis_cgdcont end", tmp, loc, data)
        end
        if tmp then
            local cid, pdptyp, apn, addr = string.match(tmp, "(%d+),(.+),(.+),[\"\'](.+)[\"\']")
            if not cid or not pdptyp or not apn or not addr then
                log.info("analysis_cgdcont CGDCONT is empty")
                ipAddr = ""
                result = false
            else
                log.info("analysis_cgdcont ", cid, pdptyp, apn, addr)
                if addr:match("%d+%.%d+%.%d+%.%d") then
                    ipAddr = addr
                    return true
                else
                    log.info("analysis_cgdcont CGDCONT is empty1")
                    ipAddr = ""
                    return false
                end
            end
        else
            ipAddr = ""
            log.info("analysis_cgdcont tmp is empty")
        end
    end

    return result
end

function IsCidActived(cid, data)
    if not data then
        return
    end
    for k, v in string.gfind(data, "(%d+),%s*(%d)") do
        log.info("iscidactived ", k, v)
        if cid == tonumber(k) and v == '1' then
            return true
        end
    end

    return
end

function IsExistActivedCid(data)
    if not data then
        return
    end
    for k, v in string.gfind(data, "(%d+),%s*(%d)") do
        if v == '1' then
            log.info("ExistActivedCid ", k, v)
            return true
        end
    end
    return
end

local cgdcontResult

function cgdcontRsp()
    if cgdcontResult then
        pdpCmdCnf("CONNECT_DELAY", true)
    end
end

function pdpCmdCnf(curCmd, result, respdata, interdata)
    log.info("link.pdpCmdCnf", curCmd, result, respdata, interdata)
    if string.find(curCmd, "CGDCONT%?") then
        if result and interdata then
            result = analysis_cgdcont(interdata)
        else
            result = false
        end
    end

    if result then
        cgdcontResult = false
        if string.find(curCmd, "CGDCONT=") then
            request(string.format('AT+CGACT=1,%d', cid_manual), nil, pdpCmdCnf)
        elseif string.find(curCmd, "CGDCONT%?") then
            cgdcontResult = true
        elseif string.find(curCmd, "CONNECT_DELAY") and network == CELLULAR then
            log.info("publish IP_READY_IND")
            readyTable[CELLULAR] = true
            publish("IP_READY_IND")
        elseif string.find(curCmd, "CGACT=") then
            request("AT+CGDCONT?", nil, cgdcontRsp)
        elseif string.find(curCmd, "CGACT%?") then
            if IsExistActivedCid(interdata) then
                sys.timerStart(pdpCmdCnf, 100, "CONNECT_DELAY", true)
            else
                request(string.format('AT+CGDCONT=%d,"IP","%s"', cid_manual, authApn or apnname), nil, pdpCmdCnf)
            end
        elseif string.find(curCmd, "CGDFLT") then
            request("AT+CGDCONT?", nil, cgdcontRsp)
        elseif string.find(curCmd, "SET_PDP_4G_WAITAPN") then
            if not apnname then
                sys.timerStart(pdpCmdCnf, 100, "SET_PDP_4G_WAITAPN", true)
            else
                request("AT+CGDCONT?", nil, cgdcontRsp, 1000)
            end
        end
    else
        if net.getState() ~= 'REGISTERED' then
            return
        end
        if net.getNetMode() == net.NetMode_LTE then
            request("AT+CGDCONT?", nil, cgdcontRsp, 1000)
        else
            request("AT+CGATT?", nil, nil, 1000)
        end
    end
end


sys.subscribe("IMSI_READY", function()
    if not apnname then
        local mcc, mnc = tonumber(sim.getMcc(), 16), tonumber(sim.getMnc(), 16)
        apnname, username, password = apn and apn.get_default_apn(mcc, mnc) 
        if not apnname or apnname == '' or apnname == "CMNET" then
            apnname = (mcc == 0x460 and (mnc == 0x01 or mnc == 0x06)) and 'UNINET' or 'CMIOT'
        end
    end
    username = username or ''
    password = password or ''
end)

ril.regRsp('+CGATT', function(a, b, c, intermediate)
    local attached = (intermediate == "+CGATT: 1")
    if gprsAttached ~= attached then
        gprsAttached = attached
        sys.publish("GPRS_ATTACH", attached)
    end

    if readyTable[CELLULAR] then
        return
    end

    if attached then
        log.info("pdp active", apnname, username, password)
        request("AT+CGACT?", nil, pdpCmdCnf, 1000)
    elseif net.getState() == 'REGISTERED' then
        sys.timerStart(request, 2000, "AT+CGATT=1")
        sys.timerStart(request, 2000, "AT+CGATT?")
    end
end)

rtos.on(rtos.MSG_PDP_DEACT_IND, function()
    if network~=CELLULAR then
        return
    end
    readyTable[CELLULAR] = false
    sys.publish('IP_ERROR_IND')

    if net.getState() ~= 'REGISTERED' then
        return
    end
    sys.timerStart(Pdp_Act, 2000)
end)

sys.subscribe("NET_STATE_REGISTERED", Pdp_Act)

local function cindCnf(cmd, result)
    if not result then
        request("AT+CIND=1", nil, cindCnf, 1000)
    end
end

local function cgevurc(data)
    if network~=CELLULAR then
        return
    end
    local cid = 0
    log.info("link.cgevurc", data)

    if string.match(data, "DEACT") then
        cid = string.match(data, "DEACT,(%d)")
        cid = tonumber(cid)

        if cid == cid_manual then
            request("AT+CFUN?")
            readyTable[CELLULAR] = false
            sys.publish('IP_ERROR_IND')
            sys.publish('PDP_DEACT_IND')
            if net.getState() ~= 'REGISTERED' then
                return
            end
            sys.timerStart(Pdp_Act, 2000)
        end
    end

end
request("AT+CIND=1", nil, cindCnf)
ril.regUrc("*CGEV", cgevurc)
ril.regUrc("+CGDCONT", function(data)
    pdpCmdCnf("AT+CGDCONT?", true, "OK", data)
end)

function openNetwork(mode, para)
    local tSocketModule = {
        [CH395] = socketCh395,
        [W5500] = socketW5500
    }
    local md = mode or CELLULAR
        closeNetWork()
        network = md
        if network == CELLULAR then
            net.switchFly(false)
            return true
        else
            ipAddr=tSocketModule[network].open(para)
            if ipAddr~="" then
                return true
            else
                log.info('link','open CH395 err')
                return false
            end
        end
        return false
end

function closeNetWork()
    local tSocketModule =  {
        [CH395] = socketCh395,
        [W5500] = socketW5500
    }

    if network == CELLULAR then
        net.switchFly(true)
        return true
    else
        return tSocketModule[network].close()
    end
    return false
end

function getNetwork()
    return network
end
