# frozen_string_literal: true

require_relative 'app'
require 'roda'

case ENV.fetch('RACK_ENV', nil)
when 'production', 'staging'
  require 'rollbar'
  Rollbar.configure do |config|
    config.access_token = 'af9bc8d8ba3046709eb245325547338b'
    config.enabled = true
  end
  run Tectonic.freeze.app
else
  logger = Logger.new $stdout
  logger.level = Logger::DEBUG
  run Tectonic.freeze.app
end
