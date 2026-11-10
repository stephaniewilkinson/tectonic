# frozen_string_literal: true

require 'http'
require 'roda'

class Tectonic < Roda
  # Tells Bing, and the other engines that share IndexNow, that the public pages may have
  # changed. #692.
  #
  # Bing is the one engine that reports AI citations to a site owner (its AI Performance
  # report, Feb 2026), and ChatGPT's search is believed to draw partly on Bing's index. A
  # changed /docs that waits for the next crawl to be noticed is a week of assistants citing
  # the old one. IndexNow is the documented way to say "look again" the day it changes.
  #
  # The key is public by design. The protocol proves ownership by the engine fetching
  # https://tectonicplates.app/<key>.txt and finding the key in it, so the file is committed
  # to assets/ and served by the public plugin like robots.txt. It grants nothing beyond
  # asking for a recrawl of this host, which is why it can sit in a public repository.
  #
  # Never fatal. Every outcome -- accepted, refused, timed out, unreachable -- comes back as a
  # line of text to log, because a search engine being unavailable is no reason for a deploy
  # or a boot to be any different.
  module IndexNow
    KEY = '2126af69c6781de81290637c01707244'
    HOST = 'tectonicplates.app'
    ENDPOINT = 'https://api.indexnow.org/indexnow'
    SITEMAP = File.expand_path('../../assets/sitemap.xml', __dir__)
    TIMEOUT = 10
    # 200 is "received"; 202 is "received, key validation pending", which is what a first
    # submission gets while the engine fetches the key file.
    ACCEPTED = [200, 202].freeze

    module_function

    # The pages the sitemap lists, so the two cannot drift: a page added there is announced
    # here without anybody remembering this file.
    def urls(sitemap = File.read(SITEMAP)) = sitemap.scan(%r{<loc>\s*([^<\s]+)\s*</loc>}).flatten

    def payload(urls = self.urls)
      { host: HOST, key: KEY, keyLocation: "https://#{HOST}/#{KEY}.txt", urlList: urls }
    end

    # Returns a sentence saying what happened, for whoever reads the log.
    def ping(urls = self.urls)
      response = HTTP.timeout(TIMEOUT).post(ENDPOINT, json: payload(urls))
      status = response.status.code
      return "IndexNow accepted #{urls.size} URL(s): #{status}" if ACCEPTED.include?(status)

      "IndexNow refused #{urls.size} URL(s): #{status} #{response.body.to_s[0, 200]}"
    rescue StandardError => e
      "IndexNow could not be reached: #{e.class}: #{e.message}"
    end
  end
end

