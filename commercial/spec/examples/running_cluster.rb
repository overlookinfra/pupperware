shared_examples 'a running pupperware cluster' do
  require 'timeout'
  require 'json'
  require 'rspec/core'
  require 'net/http'

  include Helpers

  def get_puppetdb_state
    # make sure PDB container hasn't stopped
    get_service_container('puppetdb', 5)
    # now query its status endpoint
    pdb_uri = URI::join(get_service_base_uri('puppetdb', 8080), '/status/v1/services/puppetdb-status')
    response = Net::HTTP.get_response(pdb_uri)
    STDOUT.puts "retrieved raw puppetdb status: #{response.body}"
    case response
      when Net::HTTPSuccess then
        return JSON.parse(response.body)['state']
      else
       return ''
    end
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError => e
    STDOUT.puts "PDB not accepting connections yet #{pdb_uri}: #{e}"
    return ''
  rescue JSON::ParserError
    STDOUT.puts "Invalid JSON response: #{e}"
    return ''
  rescue
    STDOUT.puts "Failure querying #{pdb_uri}: #{$!}"
    raise
  end

  def start_puppetserver
    container = get_service_container('puppet')
    status = get_container_status(container)
    # puppetserver has a healthcheck, we can let that deal with timeouts
    while (status == 'starting' || status == "'starting'")
      sleep(1)
      status = get_container_status(container)
    end

    return status
  end

  def get_postgres_extensions
    result = run_command('docker-compose --no-ansi exec -T postgres psql --username=puppetdb --command="SELECT * FROM pg_extension"')
    extensions = result[:stdout].chomp
    STDOUT.puts("retrieved extensions: #{extensions}")
    extensions
  end

  def run_agent(agent_name)
    # setting up a Windows TTY is difficult, so we don't
    # allocating a TTY will show container pull output on Linux, but that's not good for tests
    result = run_command("docker run --rm --network pupperware_default --name #{agent_name} --hostname #{agent_name} puppet/puppet-agent-alpine")
    return result[:status].exitstatus
  end

  def check_report(agent_name)
    pdb_uri = URI::join(get_service_base_uri('puppetdb', 8080), '/pdb/query/v4')
    result = run_command("docker-compose --no-ansi exec -T puppet facter domain")
    domain = result[:stdout].chomp
    body = "{ \"query\": \"nodes { certname = \\\"#{agent_name}.#{domain}\\\" } \" }"

    out = ''
    Timeout::timeout(120) do
      Net::HTTP.start(pdb_uri.hostname, pdb_uri.port) do |http|
        while out.empty?
          req = Net::HTTP::Post.new(pdb_uri)
          req.content_type = 'application/json'
          req.body = body
          res =  http.request(req)
          out = res.body if res.code == '200' && !res.body.empty?
          STDOUT.puts "retrieved agent #{agent_name} report info from #{req.uri}: HTTP #{res.code} /  #{res.body}"
          sleep(1) if out.empty?
        end
        return JSON.parse(out).first['report_timestamp']
      end
    end
  rescue Timeout::Error
    STDOUT.puts("failed to retrieve report for #{agent_name} due to timeout")
    return ''
  rescue
    STDOUT.puts("failed to retrieve report for #{agent_name}: #{$!}")
    return ''
  end

  def clean_certificate(agent_name)
    result = run_command('docker-compose --no-ansi exec -T puppet facter domain')
    domain = result[:stdout].chomp
    STDOUT.puts "cleaning cert for #{agent_name}.#{domain}"
    result = run_command("docker-compose --no-ansi exec -T puppet puppetserver ca clean --certname #{agent_name}.#{domain}")
    return result[:status].exitstatus
  end

  def start_puppetdb
    status = get_puppetdb_state
    # since pdb doesn't have a proper healthcheck yet, this could spin forever
    # add a timeout so it eventually returns.
    Timeout::timeout(240) do
      while status != 'running'
        sleep(1)
        status = get_puppetdb_state
      end
    end
  rescue Timeout::Error
    STDOUT.puts('puppetdb never entered running state')
    raise
  else
    return status
  end

  it 'should start all of the cluster services' do
    run_command('docker-compose --no-ansi up --detach')
    result = run_command('docker-compose --no-ansi ps puppet')
    expect(result[:status].exitstatus).to eq(0), "service puppet not found: #{result[:stdout].chomp}"

    result = run_command('docker-compose --no-ansi ps puppetdb')
    expect(result[:status].exitstatus).to eq(0), "service puppetdb not found: #{result[:stdout].chomp}"

    result = run_command('docker-compose --no-ansi ps postgres')
    expect(result[:status].exitstatus).to eq(0), "service postgres not found: #{result[:stdout].chomp}"
  end

  it 'should start puppetserver' do
    status = start_puppetserver
    expect(status).to match(/\'?healthy\'?/)
  end

  it 'should start puppetdb' do
    status = start_puppetdb
    expect(status).to eq('running')
  end

  it 'should include postgres extensions' do
    installed_extensions = get_postgres_extensions
    expect(installed_extensions).to match(/^\s+pg_trgm\s+/)
    expect(installed_extensions).to match(/^\s+pgcrypto\s+/)
  end

  it 'should be able to run an agent' do
    status = run_agent(@test_agent)
    expect(status).to eq(0)
  end

  it 'should have a report in puppetdb' do
    timestamp = check_report(@test_agent)
    expect(timestamp).not_to eq('')
    @timestamps << timestamp
  end

  it 'should be able to clean a certificate' do
    status = clean_certificate(@test_agent)
    expect(status).to eq(0)
  end
end
