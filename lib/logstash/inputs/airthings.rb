# encoding: utf-8
require "logstash/inputs/base"
require "stud/interval"
require "socket" # for Socket.gethostname

# Generate a repeating message.
#
# This plugin is intented only as an example.

class AirThingsApiConnection
  def initialize(client_id, client_secret, logger)
    @session = Net::HTTP.start("ext-api.airthings.com", 443, use_ssl: true)
    
    @logger = logger
    @client_id = client_id
    @client_secret = client_secret

    @token_hash = {
      expires: 0
    }
  end

  def get_token
    now = Time.now.to_i

    expires = @token_hash[:expires]

    if expires < now
      @logger.debug("Getting new Airthings API access token")
      
      req = Net::HTTP::Post.new("https://accounts-api.airthings.com/v1/token")
      req.body = JSON.generate({
        grant_type: "client_credentials",
        client_id: @client_id,
        client_secret: @client_secret.value,
        scope: [ "read:device:current_values" ]
      })
      req["Content-Type"] = "application/json"
      
      resp = @session.request(req)

      resp_json = JSON.parse(resp.body)

      @token_hash = {
        expires: now + resp_json["expires_in"] - 60,
        response: resp_json
      }
    end

    return @token_hash[:response]["access_token"]
  end

  def send_request(method_class, path)
    unless path.start_with?("/")
      path = "/" + path
    end
    
    req = method_class.new("https://ext-api.airthings.com" + path)
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer " + self.get_token
    
    resp = @session.request(req)

    resp_json = JSON.parse(resp.body)

    error = resp_json["error_description"]
    if error
      @logger.error("Error received from Airthings API", :error => error)
    end

    return resp_json
  end

  def get_devices
    resp = self.send_request(Net::HTTP::Get, "/v1/devices")

    return resp["devices"]
  end

  def get_latest_values(device_id)
    resp = self.send_request(Net::HTTP::Get, "/v1/devices/#{device_id}/latest-samples")

    return resp["data"]
  end
end

class LogStash::Inputs::Airthings < LogStash::Inputs::Base
  config_name "airthings"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain"

  # The message string to use in the event.
  config :client_id, :validate => :string
  config :client_secret, :validate => :password
  
  # Set how frequently messages should be sent.
  #
  # The default, `1`, means send a message every second.
  config :interval, :validate => :number, :default => 60

  config :device_list_interval, :validate => :number, :default => 600

  public
  def register
    @logger.info("Connecting to Airthings API", :client_id => @client_id)
    @conn = AirThingsApiConnection.new(@client_id, @client_secret, @logger)
  end # def register

  def run(queue)
    # we can abort the loop if stop? becomes true
    reload_devices_at = 0
    devices = []
    time_by_device = {}
    
    while !stop?
      now = Time.now.to_i

      if !devices || now >= reload_devices_at
        @logger.info("Getting devices from Airthings API")
        devices = @conn.get_devices

        unless devices
          devices = []
        end

        reload_devices_at = now + @device_list_interval
      end
      
      devices.each { |device|
        device_id = device["id"]
        
        @logger.debug("Getting latest values from Airthings API", :device_id => device_id)
        latest_values = @conn.get_latest_values(device_id)

        time = latest_values.delete("time")

        unless time_by_device[device_id] == time
          time_by_device[device_id] = time
          
          airthings = {
            device: {
              id: device_id,
              type: device["deviceType"],
              segment: device["segment"],
              location: device["location"]
            },
            time: time,
            metrics: latest_values
          }

          event = LogStash::Event.new("airthings" => airthings)
          decorate(event)
          queue << event
        end
      }
    
      # because the sleep interval can be big, when shutdown happens
      # we want to be able to abort the sleep
      # Stud.stoppable_sleep will frequently evaluate the given block
      # and abort the sleep(@interval) if the return value is true
      Stud.stoppable_sleep(@interval) { stop? }
    end # loop
  end # def run

  def stop
    # nothing to do in this case so it is not necessary to define stop
    # examples of common "stop" tasks:
    #  * close sockets (unblocking blocking reads/accepts)
    #  * cleanup temporary files
    #  * terminate spawned threads
  end
end # class LogStash::Inputs::Airthings
