# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require_relative '../backup'

module TectonicBackup
  # Getting a copy of the production database out of Render without connecting to it.
  #
  # BACKUPS.md used to say: take the external connection string off the dashboard and run
  # pg_dump. That works today only because the allow list is 0.0.0.0/0, and #559 closes it.
  # The correction in #588 is what decides this design: `render psql` does **not** tunnel
  # through Render. Its CLI asks the API for the *external* connection string, looks up your
  # public address first, and refuses before it dials if that address is not on the list. So
  # an empty allow list costs pg_dump, `render psql`, `render pgcli`, the MCP query tool and
  # every GUI client at once -- everything that opens a socket to the database from here.
  #
  # What it does not cost is an HTTPS call to Render's own API, because that is not a
  # database connection. POST /v1/postgres/{id}/export asks Render to run the pg_dump itself,
  # server-side; GET on the same path lists what it has taken, with a URL to download. Both
  # are included in the plan already being paid for. No gem, no object store, no second
  # account, no credential held by anybody but the owner -- and no interest in the allow list
  # whatsoever.
  #
  # There is a second reason to go through Render's export rather than dumping ourselves,
  # and it may be the better one: what comes back is a real pg_dump, in a format pg_restore
  # reads, taken by the people who run the server. A bespoke export is a thing to be right
  # about forever, and the day it turns out to have been subtly wrong is the day everything
  # else is also wrong.
  module RenderExport
    # api.render.com, unless something says otherwise. The override is a rehearsal seam and not
    # a setting: it is what lets the whole loop -- ask, wait, download, check -- be run against a
    # stub on localhost, which is how it was tested, because #588 says in as many words not to
    # take an export of the real database to find out whether the code works.
    HOST = ENV.fetch('RENDER_API_BASE', 'https://api.render.com')
    # The instance by name rather than by id, so this file carries no opaque string nobody
    # can check. The id is resolved at run time and the run refuses unless the name matches
    # exactly one database -- see `database_id`.
    DATABASE = 'tectonic_production'
    KEY_FILE = '~/.config/render/api-key'
    KEY_VARIABLE = 'RENDER_API_KEY'

    # The credential, from a file outside every repository, exactly as AGENTS.md handles the
    # Fathom token.
    #
    # A file rather than .env: this repository is public, it already has both .env and
    # .env.rb, and a key that never enters the tree cannot be committed by an editor that was
    # being helpful. A file rather than only an environment variable, too, because a variable
    # has to be set by something -- and that something is a dotfile, which is a file, minus
    # the mode 600 and plus the shell history.
    #
    # The variable is still read, and read first, but as the override rather than the habit:
    # it is how this runs somewhere with no home directory, and it is the seam a scheduled
    # runner would use later without any of this changing.
    #
    # Deliberately *not* read out of ~/.render/cli.yaml, which is sitting right there with an
    # api.key in it. That is the CLI's session token: it carries an expires_at and a refresh
    # token beside it, so a backup built on it works until one day it does not -- which is
    # precisely the failure being designed out. A key made in Render's account settings has
    # one owner and one rotation point.
    def self.credential(env: ENV, file: KEY_FILE)
      from_variable = env[KEY_VARIABLE].to_s.strip
      return from_variable unless from_variable.empty?

      path = File.expand_path(file)
      raise Refused, no_credential(path) unless File.exist?(path)

      key = File.read(path).strip
      raise Refused, "FAILED: #{path} is empty. It should hold the Render API key and nothing else." if key.empty?

      key
    end

    def self.no_credential(path)
      <<~REFUSAL
        FAILED: no Render API key, so no backup was taken.

        Make one at https://dashboard.render.com/settings#api-keys and write it to
        #{path} as a bare value -- no quotes, no `export`, no variable name:

          mkdir -p #{File.dirname(path)}
          printf %s 'rnd_...' > #{path} && chmod 600 #{path}

        Not into this repository's .env, and not into the repository at all: it is public.
      REFUSAL
    end

    # Which database DATABASE names. Resolved rather than written down so there is no id in
    # the tree to go stale, and refused unless exactly one database matches by exact name:
    # Render's name filter is a search, a workspace can hold both a tectonic_production and a
    # tectonic_production_replica, and a backup that quietly copied the wrong one would look
    # exactly like a backup.
    def self.database_id(key, name: DATABASE)
      query = URI.encode_www_form(name: name, limit: 50)
      body = json(call(:Get, "#{HOST}/v1/postgres?#{query}", key), "asking Render for a database called #{name}")
      matches = body.filter_map { |row| row['postgres'] }.select { |postgres| postgres['name'] == name }
      raise Refused, "FAILED: Render has no database called #{name}." if matches.empty?
      if matches.length > 1
        raise Refused, "FAILED: #{matches.length} of Render's databases are called #{name}; refusing to guess."
      end

      matches.first.fetch('id')
    end

    def self.exports(key, id)
      json(call(:Get, "#{HOST}/v1/postgres/#{id}/export", key), 'listing the exports Render has taken')
    end

    # Ask Render to take one. The response is a bare 202 with no body and, in particular, no
    # id, which is why the caller has to remember what was in the list a moment ago and watch
    # for something new. Written down rather than worked around silently: a future version of
    # the API that does return an id would make `arrived` unnecessary, and it should be
    # obvious why it was ever necessary.
    def self.ask_for_an_export(key, id)
      response = call(:Post, "#{HOST}/v1/postgres/#{id}/export", key)
      return if %w[200 201 202].include?(response.code)

      raise Refused, "FAILED: Render refused to start an export -- #{describe(response)}"
    end

    # The export that appeared since we asked, or nil while Render is still working. Newest
    # by Render's own timestamp rather than by list order, which the API does not promise.
    def self.arrived(exports, before)
      exports.reject { |export| before.include?(export['id']) }
             .max_by { |export| export['createdAt'].to_s }
    end

    # An export in the list is not a file yet: `url` is optional in Render's own schema and
    # absent until the dump has finished. So the thing to wait for is not "it exists" but
    # "it can be downloaded".
    def self.ready(export)
      url = export.to_h['url'].to_s
      url.empty? ? nil : url
    end

    # Whether the download URL is pre-signed or wants the key was the one thing #588 could
    # not settle without running it, so this answers the question at run time instead of
    # betting on it: try it bare, and only if the storage refuses, try it as us.
    #
    # The key is dropped when following a redirect. A redirect here goes to object storage,
    # and handing a Render API key -- which can read and change every service in the
    # workspace -- to whatever host a response points at is a way to lose it that has nothing
    # to do with backups.
    def self.download(url, path, key)
      code = stream(url, path, nil)
      code = stream(url, path, key) if %w[401 403].include?(code)
      return if code == '200'

      raise Refused, "FAILED: the download URL answered #{code}; no copy was written."
    end

    # Streamed to disk rather than read into a string, because this file is the whole
    # database and the point of it is to still work on the day the database is not small.
    def self.stream(url, path, key, hops: 5)
      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{key}" if key
      reaching('downloading the export') do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(request) { |response| return receive(response, path, hops) }
        end
      end
    end

    def self.receive(response, path, hops)
      moved = response.code.start_with?('3') && response['location'] && hops.positive?
      return stream(response['location'], path, nil, hops: hops - 1) if moved
      return response.code unless response.code == '200'

      File.open(path, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
      '200'
    end

    # use_ssl follows the URL rather than being true, which is not only for the localhost
    # rehearsal: hard-coding it means a plain http:// URL is answered with a TLS handshake and
    # a timeout, so the report is "Render did not answer" when the truth is "we dialled it
    # wrong". A backup tool should not be capable of lying about whose fault it was.
    def self.call(method, url, key)
      uri = URI(url)
      request = Net::HTTP.const_get(method).new(uri)
      request['Authorization'] = "Bearer #{key}"
      request['Accept'] = 'application/json'
      reaching('talking to the Render API') do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(request) }
      end
    end

    # Render being unreachable is an ordinary thing that happens -- no network, DNS, a captive
    # portal, a proxy, a timeout -- and it deserves the same sentence-and-an-exit-code as every
    # other way of not having a backup rather than a stack trace with the answer somewhere in
    # it. A refusal raised further in is already that sentence, so it passes through untouched.
    def self.reaching(what)
      yield
    rescue Refused
      raise
    rescue StandardError => e
      raise Refused, "FAILED: could not reach Render while #{what} -- #{e.class}: #{e.message}"
    end

    def self.json(response, doing)
      raise Refused, "FAILED: #{doing} -- #{describe(response)}" unless response.code == '200'

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Refused, "FAILED: #{doing} -- Render's answer was not JSON."
    end

    # Render says why in the body, and the body is worth repeating: "unauthorized" and "you
    # are not a member of this workspace" are different problems wearing the same status
    # code. Truncated, because an HTML error page is not an explanation.
    def self.describe(response)
      "HTTP #{response.code} #{response.body.to_s.strip[0, 300]}".strip
    end
  end
end

