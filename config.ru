# frozen_string_literal: true

require 'dotenv/load'
require 'http'
require 'rack'
require 'rack/auth/basic'
require 'roda'
require 'tilt'
require_relative 'lib/db'

class App < Roda
  PASSWORD = ENV.fetch 'PASSWORD'
  USERNAME = ENV.fetch 'USERNAME'

  plugin :assets, css: 'tailwind.css'
  plugin :default_headers, 'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains'
  plugin :head
  plugin :http_auth
  plugin :public, root: 'assets'
  plugin :render
  plugin :route_csrf
  plugin :slash_path_empty

  route do |r|
    r.assets
    r.public

    # GET /
    r.root do
      view 'welcome'
    end
    r.get 'home' do
      http_auth do |username, password|
        username == USERNAME && password == PASSWORD
      end
      view 'home'
    end

    r.on 'workout' do
      r.post do
      end
    end
  end
end

run App.freeze.app
