# frozen_string_literal: true

ENV['RACK_ENV'] ||= 'development'

ENV['DATABASE_URL'] ||= case ENV['RACK_ENV']
                        when 'test'
                          'postgres:///liftoff_test'
                        when 'production'
                          'please_fill_me_in_later'
                        else
                          'postgres:///liftoff_development'
                        end
