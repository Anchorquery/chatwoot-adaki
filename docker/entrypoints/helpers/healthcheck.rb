#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'uri'

url = ENV.fetch('HEALTHCHECK_URL', 'http://127.0.0.1:3000/health')
response = Net::HTTP.get_response(URI(url))

exit(response.is_a?(Net::HTTPSuccess) && JSON.parse(response.body)['status'] == 'woot' ? 0 : 1)
