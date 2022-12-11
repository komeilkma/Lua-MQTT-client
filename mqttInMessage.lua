-- @author komeilkma
-- @module mqtt.mqttInMessage


module(...,package.seeall)

function proc(mqttClient)
    local result,data
    while true do
        result,data = mqttClient:receive(60000,"APP_SOCKET_SEND_DATA")
        if result then
            log.info("mqttInMessage.proc",data.topic,string.toHex(data.payload))
        else
            break
        end
    end
	
    return result or data=="timeout" or data=="APP_SOCKET_SEND_DATA"
end
