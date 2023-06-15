# frozen_string_literal: true

ENV['RACK_ENV'] ||= 'development'

ENV['DATABASE_URL'] ||= case ENV.fetch('RACK_ENV', nil)
                        when 'test'
                          'postgres:///tectonic_test'
                        when 'production'
                          'please_fill_me_in_later'
                        else
                          'postgres:///tectonic_development'
                        end
