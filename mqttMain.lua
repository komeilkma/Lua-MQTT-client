-- @author komeilkma
-- @module mqtt.mqttMain
module(...,package.seeall)
require"misc"
require"mqtt"
require"mqttOutMsg"
require"mqttInMsg"

local ready = false

function isReady()
    return ready
end

sys.taskInit(
    function()
        local retryConnectCnt = 0
        while true do
            if not socket.isReady() then
                retryConnectCnt = 0
                sys.waitUntil("IP_READY_IND",300000)
            end
            
            if socket.isReady() then
                local imei = misc.getImei()

                local mqttClient = mqtt.client(imei,600,"user","password")
                --mqttClient:connect("example.com",1884,"tcp_ssl",{caCert="ca.crt"})
                if mqttClient:connect("example.com",1884,"tcp") then
                    retryConnectCnt = 0
                    ready = true
                    
                    if mqttClient:subscribe({["/event0"]=0, ["/event1"]=1}) then
                        mqttOutMsg.init()
                        while true do
                            if not mqttInMsg.proc(mqttClient) then log.error("mqttMain.mqttInMsg.proc error") break end
                            if not mqttOutMsg.proc(mqttClient) then log.error("mqttMain.mqttOutMsg proc error") break end
                        end
                        mqttOutMsg.unInit()
                    end
                    ready = false
                else
                    retryConnectCnt = retryConnectCnt+1
                end
                mqttClient:disconnect()
                if retryConnectCnt>=5 then link.shut() retryConnectCnt=0 end
                sys.wait(5000)
            else
                net.switchFly(true)
                sys.wait(20000)
                net.switchFly(false)
            end
        end
    end
)
