require "timeout"

require "log4r"
require "winrm"

require "vagrant/util/retryable"

module VagrantPlugins
  module CommunicatorWinRM
    class WinRMShell
      include Vagrant::Util::Retryable

      # These are the exceptions that we retry because they represent
      # errors that are generally fixed from a retry and don't
      # necessarily represent immediate failure cases.
      @@exceptions_to_retry_on = [
        HTTPClient::KeepAliveDisconnected,
        WinRM::WinRMHTTPTransportError,
        Errno::EACCES,
        Errno::EADDRINUSE,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::ENETUNREACH,
        Errno::EHOSTUNREACH,
        Timeout::Error
      ]

      attr_reader :logger
      attr_reader :username
      attr_reader :password
      attr_reader :host
      attr_reader :port
      attr_reader :timeout_in_seconds
      attr_reader :max_tries

      def initialize(host, username, password, options = {})
        @logger = Log4r::Logger.new("vagrant::communication::winrmshell")
        @logger.debug("initializing WinRMShell")

        @host               = host
        @port               = options[:port] || 5985
        @username           = username
        @password           = password
        @timeout_in_seconds = options[:timeout_in_seconds] || 60
        @max_tries          = options[:max_tries] || 20
      end

      def powershell(command, &block)
        execute_shell(command, :powershell, &block)
      end

      def cmd(command, &block)
        execute_shell(command, :cmd, &block)
      end

      def wql(query)
        execute_wql(query)
      end

      def upload(from, to)
        @logger.debug("Uploading: #{from} to #{to}")
        file_name = (cmd("echo %TEMP%\\winrm-upload-#{rand()}"))[:data][0][:stdout].chomp
        powershell <<-EOH
          if(Test-Path #{to}) {
            rm #{to}
          }
        EOH
        Base64.encode64(IO.binread(from)).gsub("\n",'').chars.to_a.each_slice(8000-file_name.size) do |chunk|
          out = cmd("echo #{chunk.join} >> \"#{file_name}\"")
        end
        powershell <<-EOH
          mkdir $([System.IO.Path]::GetDirectoryName(\"#{to}\"))
          $base64_string = Get-Content \"#{file_name}\"
          $bytes  = [System.Convert]::FromBase64String($base64_string)
          $new_file = [System.IO.Path]::GetFullPath(\"#{to}\")
          [System.IO.File]::WriteAllBytes($new_file,$bytes)
        EOH
      end

      def download(from, to)
        @logger.debug("Downloading: #{from} to #{to}")
        output = powershell("[System.convert]::ToBase64String([System.IO.File]::ReadAllBytes(\"#{from}\"))")
        contents = output[:data].map!{|line| line[:stdout]}.join.gsub("\\n\\r", '')
        out = Base64.decode64(contents)
        IO.binwrite(to, out)
      end

      protected

      def execute_shell(command, shell=:powershell, &block)
        raise Errors::InvalidShell, shell: shell unless shell == :cmd || shell == :powershell

        begin
          execute_shell_with_retry(command, shell, &block)
        rescue => e
          raise_winrm_exception(e, shell, command)
        end
      end

      def execute_shell_with_retry(command, shell, &block)
        retryable(:tries => @max_tries, :on => @@exceptions_to_retry_on, :sleep => 10) do
          @logger.debug("#{shell} executing:\n#{command}")
          output = session.send(shell, command) do |out, err|
            block.call(:stdout, out) if block_given? && out
            block.call(:stderr, err) if block_given? && err
          end
          @logger.debug("Exit status: #{output[:exitcode].inspect}")
          return output
        end
      end

      def execute_wql(query)
        retryable(:tries => @max_tries, :on => @@exceptions_to_retry_on, :sleep => 10) do
          @logger.debug("#executing wql: #{query}")
          output = session.wql(query)
          @logger.debug("wql result: #{output.inspect}")
          return output
        end
      rescue => e
        raise_winrm_exception(e, :wql, query)
      end

      def raise_winrm_exception(winrm_exception, shell, command)
        # If the error is a 401, we can return a more specific error message
        if winrm_exception.message.include?("401")
          raise Errors::AuthError,
            :user => @username,
            :password => @password,
            :endpoint => endpoint,
            :message => winrm_exception.message
        end

        raise Errors::ExecutionError,
          :shell => shell,
          :command => command,
          :message => winrm_exception.message
      end

      def new_session
        @logger.info("Attempting to connect to WinRM...")
        @logger.info("  - Host: #{@host}")
        @logger.info("  - Port: #{@port}")
        @logger.info("  - Username: #{@username}")

        client = ::WinRM::WinRMWebService.new(endpoint, :plaintext, endpoint_options)
        client.set_timeout(@timeout_in_seconds)
        client.toggle_nori_type_casting(:off) #we don't want coersion of types
        client
      end

      def session
        @session ||= new_session
      end

      def endpoint
        "http://#{@host}:#{@port}/wsman"
      end

      def endpoint_options
        { :user => @username,
          :pass => @password,
          :host => @host,
          :port => @port,
          :operation_timeout => @timeout_in_seconds,
          :basic_auth_only => true }
      end
    end #WinShell class
  end
end
