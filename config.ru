# frozen_string_literal: true

require_relative 'app'
logger = Logger.new $stdout
logger.level = Logger::DEBUG
run Tectonic.freeze.app
