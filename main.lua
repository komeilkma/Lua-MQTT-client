PROJECT = "Lua-MQTT-client"
VERSION = "1.0.0"
require "log"
LOG_LEVEL = log.LOGLEVEL_TRACE
require "sys"
require "net"
net.startQueryAll(60000, 60000)
require "mqttMain"
sys.init(0, 0)
sys.run()
