#!/usr/bin/env ruby

require 'net/http'
require 'uri'

url = URI(ARGV.fetch(0, 'http://rails:3000/health'))
attempts = Integer(ENV.fetch('WAIT_FOR_HEALTH_ATTEMPTS', '60'))
sleep_seconds = Integer(ENV.fetch('WAIT_FOR_HEALTH_SLEEP', '5'))

attempts.times do
  begin
    response = Net::HTTP.get_response(url)
    if response.is_a?(Net::HTTPSuccess)
      exit 0
    end
  rescue StandardError
    # Keep waiting until the service is ready.
  end

  sleep sleep_seconds
end

warn "Timed out waiting for #{url}"
exit 1
