# frozen_string_literal: true

require 'tzinfo'
require_relative 'db'
require 'date'

class Tectonic < Roda
  # What day it is for the lifter, rather than for the server. #349.
  #
  # Every "today" in this app used to be `Date.today`, which is the server's, and the server is
  # UTC. A lifter in New York at 8:30pm on Monday was acting on Tuesday as far as the app was
  # concerned: signing in missed the session they came to do, asking an assistant to log
  # "today" opened a second empty workout beside the real one, and the Monday session they were
  # halfway through read as skipped.
  #
  # The fix is one question -- *whose* today -- asked in one place, so that the dozen call
  # sites that need an answer cannot each get a different one.
  #
  # **Nil is UTC and stays UTC.** An account with no zone set behaves exactly as it did before
  # this existed, which is what lets the column be added without moving anybody's sessions.
  #
  # **An unresolvable name is UTC too, and does not raise.** A zone this gem no longer knows --
  # a name retired between deploys, or a value written before a validation existed -- is a
  # reason to be an hour wrong about somebody's calendar, not a reason to refuse to serve their
  # session. Writing one is refused up front by `zone?`, which is where the complaint belongs.
  module Clock
    module_function

    # The date it is right now where this account is.
    def today(time_zone, now: Time.now)
      zone = resolve(time_zone)
      return now.to_date unless zone

      zone.to_local(now).to_date
    end

    # The same question asked by account id, which is how every caller has it -- there is no
    # Account model in this app and the two settings beside this one, bar_weight and
    # week_starts_on, are read off the dataset the same way.
    #
    # One column off one row by primary key. Cheap, and worth being plain about: it is a query
    # per call, on a screen that asks once. Somewhere that asked in a loop should read the zone
    # once and pass it to `today`, which is why that is the method this is built on rather than
    # the other way round.
    def today_for(account_id, now: Time.now)
      today(zone_of(account_id), now:)
    end

    def zone_of(account_id)
      return nil unless account_id

      DB[:accounts].where(id: account_id).get(:time_zone)
    end

    # Whether a name is one that can be resolved, which is what the settings form checks before
    # writing it. A free text box would otherwise store "EST" or "GMT+5" and be silently
    # ignored by every reader.
    def zone?(name)
      !resolve(name).nil?
    end

    def resolve(name)
      return nil if name.to_s.strip.empty?

      TZInfo::Timezone.get(name.to_s)
    rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::DataSourceNotFound
      nil
    end

    # The zones offered on the settings form.
    #
    # A curated list rather than all six hundred IANA identifiers. The full set includes every
    # historical alias and a select holding it is unusable on a phone, which is the device this
    # is set from. These are the zones a lifter using this app is plausibly in, most-populated
    # first within each region.
    OFFERED = [
      'America/Los_Angeles', 'America/Denver', 'America/Phoenix', 'America/Chicago',
      'America/New_York', 'America/Anchorage', 'Pacific/Honolulu', 'America/Toronto',
      'America/Vancouver', 'America/Mexico_City', 'America/Sao_Paulo', 'America/Bogota',
      'Europe/London', 'Europe/Dublin', 'Europe/Lisbon', 'Europe/Madrid', 'Europe/Paris',
      'Europe/Berlin', 'Europe/Rome', 'Europe/Amsterdam', 'Europe/Stockholm', 'Europe/Warsaw',
      'Europe/Athens', 'Europe/Istanbul', 'Europe/Moscow', 'Africa/Lagos', 'Africa/Cairo',
      'Africa/Johannesburg', 'Asia/Jerusalem', 'Asia/Dubai', 'Asia/Karachi', 'Asia/Kolkata',
      'Asia/Bangkok', 'Asia/Singapore', 'Asia/Hong_Kong', 'Asia/Shanghai', 'Asia/Tokyo',
      'Asia/Seoul', 'Australia/Perth', 'Australia/Brisbane', 'Australia/Sydney',
      'Australia/Adelaide', 'Pacific/Auckland', 'UTC'
    ].freeze

    # The list as the form should render it: the offerings, plus whatever is already stored if
    # that is not among them. Without the second half, saving the form would silently move an
    # account off a zone somebody set deliberately -- the select would hold no option matching
    # it, so the browser would submit the first one instead.
    def zone_options(current)
      return OFFERED if current.to_s.empty? || OFFERED.include?(current)

      ([current] + OFFERED).freeze
    end
  end
end

