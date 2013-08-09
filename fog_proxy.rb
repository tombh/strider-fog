require 'rubygems'
require 'fog'

HOME_DIR = '/home/strider'
REPO_DIR = HOME_DIR + '/repo'

def usage(s)
  $stderr.puts(s)
  $stderr.puts("Usage: #{File.basename($0)}: --jobid <ID> --phase <prepare|test|deploy|cleanup> --cmd \"<UNIX command>\"")
  exit(2)
end

# Provides a means to stream an SSH command and also return exit data
# Based on: http://stackoverflow.com/questions/3386233/how-to-get-exit-status-with-rubys-netssh-library
def ssh_exec!(ssh, command)
  exit_code = nil
  exit_signal = nil
  ssh.open_channel do |channel|
    channel.exec(command) do |ch, success|
      unless success
        abort "FAILED: couldn't execute command (ssh.channel.exec)"
      end
      channel.on_data do |ch,data|
        # STDOUT
        puts data
      end

      channel.on_extended_data do |ch,type,data|
        # STDERR
        puts data
      end

      channel.on_request("exit-status") do |ch,data|
        exit_code = data.read_long
      end

      channel.on_request("exit-signal") do |ch, data|
        exit_signal = data.read_long
      end
    end
  end
  ssh.loop
  [exit_code, exit_signal]
end

def remote_cmd ip, cmd, exit_script = true, user = 'strider'
  puts "user: #{user}"
  Net::SSH.start(ip, user, :paranoid => Net::SSH::Verifiers::Null.new) do |ssh|
    # Run the command on the remote server
    exit_code = ssh_exec!(ssh, cmd).first
    # Mirror the exit code to this very script
    exit(exit_code) if exit_script
  end
end

loop { case ARGV[0]
  when '--jobid' then ARGV.shift; $jobid = ARGV.shift
  when '--dir' then ARGV.shift; $dir = ARGV.shift
  when '--phase' then ARGV.shift; $phase = ARGV.shift
  when '--cmd' then ARGV.shift; $cmd = ARGV.shift
  when /^-/ then usage("Unknown option: #{ARGV[0].inspect}")
  else break
end; }
usage "Missing arguments" if $jobid.nil? || $phase.nil? || $cmd.nil?

docean = Fog::Compute.new({
  :provider => 'DigitalOcean'
  # Relies on credentials being placed in ~/.fog
  # See http://fog.io/about/getting_started.html for more info
})

# Get the server
if $phase == "prepare"
  # DigitalOcean-specific instance spec
  # 512MB Ubuntu 13.04 x64 in Amsterdam
  server = docean.servers.create(
    :name => "StriderWorker#{$jobid}",
    :image_id  => 350076,
    :flavor_id => 66,
    :region_id => 2,
    :ssh_key_ids => "25948"
  )
else
  server = docean.servers.all.select{|s| s.name == "StriderWorker#{$jobid}"}.first
end

if $phase == "prepare"
  puts "Server ID: #{server.id}"
  puts "Waiting for server to become active..."

  server.wait_for { ready? }
  sleep 1 # Give it a little bit of extra breathing space, man.
  if server.ready?
    puts "Server active."
  else
    raise "Server creation/connection failed."
  end

  puts "Creating 'strider' user on remote server..."
  remote_cmd(
    server.ip_address,
    "useradd -d #{HOME_DIR} -m strider -s /bin/bash && \
    cp -r /root/.ssh #{HOME_DIR} && \
    echo \"strider ALL=(ALL) NOPASSWD: ALL\" >> /etc/sudoers",
    false,
    'root'
  )

  # The repo needs to be on the remote server before we can test.
  puts "Tarring repo..."
  puts `cd /tmp && tar -zcf repo#{$jobid}.tgz -C #{$dir} . --exclude=".git" 2>&1`
  puts "Copying repo to remote server..."
  puts `scp \
          -o UserKnownHostsFile=/dev/null \
          -o StrictHostKeyChecking=no \
          /tmp/repo#{$jobid}.tgz \
          strider@#{server.ip_address}:#{HOME_DIR} \
          && echo Copied.`
  puts "Unpacking repo on remote..."
  remote_cmd(
    server.ip_address,
    "mkdir -p #{REPO_DIR} && tar -vzxf repo#{$jobid}.tgz -C #{REPO_DIR}",
    false
  )
end

if $phase == "cleanup"
  server.destroy
  server.wait_for { !ready? }
  puts "Server destroyed."
else
  remote_cmd(server.ip_address, "cd #{REPO_DIR} && " + $cmd)
end