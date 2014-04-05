require 'chef_metal/transport'
require 'docker'
require 'archive/tar/minitar'

module ChefMetalDocker
  class DockerTransport < ChefMetal::Transport
    def initialize(repository_name, container_name, credentials, connection)
      @repository_name = repository_name
      @image = Docker::Image.get("#{repository_name}:latest", connection)
      @container_name = container_name
      @credentials = credentials
      @connection = connection
      @forwarded_ports = []
    end

    attr_reader :container_name
    attr_reader :repository_name
    attr_reader :image
    attr_reader :credentials
    attr_reader :connection
    attr_reader :forwarded_ports

    def execute(command, commit=true)
      begin
        # Delete the container if it exists and is dormant
        connection.delete("/containers/#{container_name}")
      rescue Docker::Error::NotFoundError
      end
      @container = Docker::Container.create({
        'name' => container_name,
        'Image' => "#{repository_name}:latest",
        'Cmd' => (command.is_a?(String) ? command.split(/\s+/) : command),
#        'ExposedPorts' => @forwarded_ports.inject({}) do |result, remote_port, local_port|
#          result["#{remote_port}/tcp"] = {}
#          result
#        end,
        'AttachStdout' => true,
        'AttachStderr' => true,
        'TTY' => false
      }, connection)

      # Start the container
      @container.start({
        'PortBindings' => @forwarded_ports.inject({}) do |result, remote_port, local_port|
          result["#{remote_port}/tcp"] = [{
            'HostIp' => '127.0.0.1',
            'HostPort' => local_port
          }]
          result
        end
      })

      # Capture stdout / stderr
      stdout = ''
      stderr = ''
      @container.attach do |type, str|
        case type
        when :stdout
          stdout << str
        when :stderr
          stderr << str
        else
          raise "unexpected message type #{type}"
        end
      end

      # Capture exit code
      exit_status = @container.wait

      @image = @container.commit('repo' => repository_name) if commit
      DockerResult.new(stdout, stderr, exit_status['StatusCode'])
    end

    def read_file(path)
      container = Docker::Container.create({
        'Image' => "#{repository_name}:latest",
        'Cmd' => %w(echo true)
      }, connection)
      begin
        tarfile = ''
        # NOTE: this would be more efficient if we made it a stream and passed that to Minitar
        container.copy(path) do |block|
          tarfile << block
        end
      ensure
        container.delete
      end

      output = ''
      Archive::Tar::Minitar::Input.open(StringIO.new(tarfile)) do |inp|
        inp.each do |entry|
          while next_output = entry.read
            output << next_output
          end
          entry.close
        end
      end

      output
    end

    def write_file(path, content)
      # TODO hate tempfiles.  Find an in memory way.
      Tempfile.open('metal_docker_write_file') do |file|
        file.write(content)
        file.close
        @image = @image.insert_local('localPath' => file.path, 'outputPath' => path, 't' => "#{repository_name}:latest")
      end
    end

    def download_file(path, local_path)
      # TODO stream
      file = File.open(local_path, 'w')
      begin
        file.write(read_file(path))
        file.close
      rescue
        File.delete(file)
      end
    end

    def upload_file(local_path, path)
      @image = @image.insert_local('localPath' => local_path, 'outputPath' => path, 't' => "#{repository_name}:latest")
    end

    # Forward requests to a port on the guest to a server on the host
    def forward_remote_port_to_local(remote_port, local_port)
      @forwarded_ports << [ remote_port, local_port ]
    end

    def disconnect
    end

    def available?
    end

    private

    # Copy of container.attach with timeout support
    def attach_with_timeout(container, options = {}, read_timeout, &block)
      opts = {
        :stream => true, :stdout => true, :stderr => true
      }.merge(options)
      # Creates list to store stdout and stderr messages
      msgs = Docker::Messages.new
      connection.post(
        "/containers/#{container.id}/attach",
        opts,
        :response_block => attach_for(block, msgs),
        :read_timeout => read_timeout
      )
      [msgs.stdout_messages, msgs.stderr_messages]
    end

    # Method that takes chunks and calls the attached block for each mux'd message
    def attach_for(block, msg_stack)
      messages = Docker::Messages.new
      lambda do |c,r,t|
        messages = messages.decipher_messages(c)
        msg_stack.append(messages)

        unless block.nil?
          messages.stdout_messages.each do |msg|
            block.call(:stdout, msg)
          end
          messages.stderr_messages.each do |msg|
            block.call(:stderr, msg)
          end
        end
      end
    end

    class DockerResult
      def initialize(stdout, stderr, exitstatus)
        @stdout = stdout
        @stderr = stderr
        @exitstatus = exitstatus
      end

      attr_reader :stdout
      attr_reader :stderr
      attr_reader :exitstatus

      def error!
        raise "Error: code #{exitstatus}.\nSTDOUT:#{stdout}\nSTDERR:#{stderr}" if exitstatus != 0
      end
    end
  end
end
