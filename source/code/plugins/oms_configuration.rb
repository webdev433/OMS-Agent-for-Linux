# frozen_string_literal: true

module OMS

  class Configuration
    require 'openssl'
    require 'uri'

    require_relative 'omslog'
    
    @@ConfigurationLoaded = false

    @@Cert = nil
    @@Key = nil

    @@AgentId = nil
    @@ODSEndpoint = nil
    @@DiagnosticEndpoint = nil
    @@GetBlobODSEndpoint = nil
    @@NotifyBlobODSEndpoint = nil
    @@OmsCloudId = nil
    @@AzureResourceId = nil
    @@AzureIMDSEndpoint = "http://169.254.169.254/metadata/instance?api-version=2017-12-01"
    @@AzureResIDThreadLock = Mutex.new
    @@ProxyConfig = nil
    @@ProxyConfigFilePath = "/etc/opt/microsoft/omsagent/proxy.conf"
    @@UUID = nil
 
    class << self
      
      # test the onboard file existence
      def test_onboard_file(file_name)
        if !File.file?(file_name)
          OMS::Log.error_once("Could not find #{file_name} Make sure to onboard.")
          return false
        end
      
        if !File.readable?(file_name)
          OMS::Log.error_once("Could not read #{file_name} Check that the read permissions are set for the omsagent user")
          return false
        end

        return true
      end

      def get_proxy_config(proxy_conf_path)
        old_proxy_conf_path = '/etc/opt/microsoft/omsagent/conf/proxy.conf'
        if !File.exist?(proxy_conf_path) and File.exist?(old_proxy_conf_path)
          proxy_conf_path = old_proxy_conf_path
        end

        begin
          proxy_config = parse_proxy_config(File.read(proxy_conf_path))
        rescue SystemCallError # Error::ENOENT
          return {}
        end

        if proxy_config.nil?
          OMS::Log.error_once("Failed to parse the proxy configuration in '#{proxy_conf_path}'")
          return {}
        end

        return proxy_config
      end

      def parse_proxy_config(proxy_conf_str)
          # Remove the http(s) protocol
          proxy_conf_str = proxy_conf_str.gsub(/^(https?:\/\/)?/, "")

          # Check for unsupported protocol
          if proxy_conf_str[/^[a-z]+:\/\//]
            return nil
          end

          re = /^(?:(?<user>[^:]+):(?<pass>[^@]+)@)?(?<addr>[^:@]+)(?::(?<port>\d+))?$/ 
          matches = re.match(proxy_conf_str)
          if matches.nil? or matches[:addr].nil? 
            return nil
          end
          # Convert nammed matches to a hash
          Hash[ matches.names.map{ |name| name.to_sym}.zip( matches.captures ) ]
      end

      def get_azure_resid_from_imds()
          begin
            uri = URI.parse(@@AzureIMDSEndpoint)
            http_get_req = Net::HTTP::Get.new(uri, initheader = {'Metadata' => 'true'})

            if @@ProxyConfig.empty?
              http_req = Net::HTTP.new(uri.host, uri.port)
            else
              http_req = Net::HTTP.new(uri.host, uri.port, @@ProxyConfig[:addr], @@ProxyConfig[:port], @@ProxyConfig[:user], @@ProxyConfig[:pass])
            end

            http_req.open_timeout = 3
            http_req.read_timeout = 2

            res = http_req.start() do |http|
              http.request(http_get_req)
            end

            imds_instance_json = JSON.parse(res.body)

            return nil if !imds_instance_json.has_key?("compute") || imds_instance_json['compute'].empty? #classic vm

            imds_instance_json_compute = imds_instance_json['compute']

            #guard from missing keys
            return nil unless imds_instance_json_compute.has_key?("subscriptionId") && imds_instance_json_compute.has_key?("resourceGroupName") && imds_instance_json_compute.has_key?("name") && imds_instance_json_compute.has_key?("vmScaleSetName")

            #guard from blank values
            return nil if imds_instance_json_compute['subscriptionId'].empty? || imds_instance_json_compute['resourceGroupName'].empty? || imds_instance_json_compute['name'].empty?

            azure_resource_id = '/subscriptions/' + imds_instance_json_compute['subscriptionId'] + '/resourceGroups/' + imds_instance_json_compute['resourceGroupName'] + '/providers/Microsoft.Compute/'

            if (imds_instance_json_compute['vmScaleSetName'].empty?)
              azure_resource_id = azure_resource_id + 'virtualMachines/' + imds_instance_json_compute['name']
            else
              azure_resource_id = azure_resource_id + 'virtualMachineScaleSets/' + imds_instance_json_compute['vmScaleSetName'] + '/virtualMachines/' + imds_instance_json_compute['name']
            end

            return azure_resource_id

          rescue => e
            # this may be a container instance or a non-Azure VM
            OMS::Log.warn_once("Could not fetch Azure Resource ID from IMDS, Reason: #{e}")
            return nil
          end
      end

      def update_azure_resource_id()
          retries=1
          max_retries=3

          loop do
            break if retries > max_retries
            azure_resource_id = get_azure_resid_from_imds()
            if azure_resource_id.nil?
              sleep (retries * 120)
              retries += 1
              next
            end

            @@AzureResourceId = azure_resource_id unless @@AzureResourceId == azure_resource_id
            retries=1 #reset
            sleep 60
          end

          OMS::Log.warn_once("Exceeded max attempts to fetch Azure Resource ID, killing the thread")
          return #terminate
      end

      # load the configuration from the configuration file, cert, and key path
      def load_configuration(conf_path, cert_path, key_path)
        return true if @@ConfigurationLoaded
        return false if !test_onboard_file(conf_path) or !test_onboard_file(cert_path) or !test_onboard_file(key_path)

        @@ProxyConfig = get_proxy_config(@@ProxyConfigFilePath)

        endpoint_lines = IO.readlines(conf_path).select{ |line| line.start_with?("OMS_ENDPOINT")}
        if endpoint_lines.size == 0
          OMS::Log.error_once("Could not find OMS_ENDPOINT setting in #{conf_path}")
          return false
        elsif endpoint_lines.size > 1
          OMS::Log.warn_once("Found more than one OMS_ENDPOINT setting in #{conf_path}, will use the first one.")
        end

        begin
          endpoint_url = endpoint_lines[0].split("=")[1].strip
          @@ODSEndpoint = URI.parse( endpoint_url )
          @@GetBlobODSEndpoint = @@ODSEndpoint.clone
          @@GetBlobODSEndpoint.path = '/ContainerService.svc/GetBlobUploadUri'
          @@NotifyBlobODSEndpoint = @@ODSEndpoint.clone
          @@NotifyBlobODSEndpoint.path = '/ContainerService.svc/PostBlobUploadNotification'
        rescue => e
          OMS::Log.error_once("Error parsing endpoint url. #{e}")
          return false
        end

        begin
          diagnostic_endpoint_lines = IO.readlines(conf_path).select{ |line| line.start_with?("DIAGNOSTIC_ENDPOINT=")}
          if diagnostic_endpoint_lines.size == 0
            # Endpoint to be inferred from @@ODSEndpoint
            @@DiagnosticEndpoint = @@ODSEndpoint.clone
            @@DiagnosticEndpoint.path = '/DiagnosticsDataService.svc/PostJsonDataItems'
          else
            if diagnostic_endpoint_lines.size > 1
              OMS::Log.warn_once("Found more than one DIAGNOSTIC_ENDPOINT setting in #{conf_path}, will use the first one.")
            end
            diagnostic_endpoint_url = diagnostic_endpoint_lines[0].split("=")[1].strip
            @@DiagnosticEndpoint = URI.parse( diagnostic_endpoint_url )
          end
        rescue => e
          OMS::Log.error_once("Error obtaining diagnostic endpoint url. #{e}")
          return false
        end

        agentid_lines = IO.readlines(conf_path).select{ |line| line.start_with?("AGENT_GUID")}
        if agentid_lines.size == 0
          OMS::Log.error_once("Could not find AGENT_GUID setting in #{conf_path}")
          return false
        elsif agentid_lines.size > 1
          OMS::Log.warn_once("Found more than one AGENT_GUID setting in #{conf_path}, will use the first one.")
        end

        begin
          @@AgentId = agentid_lines[0].split("=")[1].strip
        rescue => e
          OMS::Log.error_once("Error parsing agent id. #{e}")
          return false
        end

        File.open(conf_path).each_line do |line|
          if line =~ /AZURE_RESOURCE_ID/
            @@AzureResourceId = line.sub("AZURE_RESOURCE_ID=","").strip
            Thread.new(&method(:update_azure_resource_id)) if @@AzureResIDThreadLock.try_lock
          end
          if line =~ /OMSCLOUD_ID/
            @@OmsCloudId = line.sub("OMSCLOUD_ID=","").strip
          end
          if line =~ /UUID/
            @@UUID = line.sub("UUID=","").strip
          end
        end

        begin
          raw = File.read cert_path
          @@Cert = OpenSSL::X509::Certificate.new raw
          raw = File.read key_path
          @@Key  = OpenSSL::PKey::RSA.new raw
        rescue => e
          OMS::Log.error_once("Error loading certs: #{e}")
          return false
        end

        @@ConfigurationLoaded = true
        return true        
      end # load_configuration

      def cert
        @@Cert
      end # getter cert

      def key
        @@Key
      end # getter key

      def agent_id
        @@AgentId
      end # getter agent_id

      def ods_endpoint
        @@ODSEndpoint
      end # getter ods_endpoint

      def diagnostic_endpoint
        @@DiagnosticEndpoint
      end # getter diagnostic_endpoint

      def get_blob_ods_endpoint
        @@GetBlobODSEndpoint
      end # getter get_blob_ods_endpoint

      def notify_blob_ods_endpoint
        @@NotifyBlobODSEndpoint
      end # getter notify_blob_ods_endpoint

      def azure_resource_id
        @@AzureResourceId
      end

      def omscloud_id
        @@OmsCloudId
      end

      def uuid
        @@UUID
      end # getter for VM uuid

    end # Class methods
        
  end # class Common
end # module OMS
