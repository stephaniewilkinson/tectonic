# frozen_string_literal: true

require_relative 'db'
require_relative 'withings'

class Tectonic < Roda
  # One account's standing permission to read its own Withings measurements. #472.
  #
  # Separate from the measurements themselves (041) because the two have different lifetimes:
  # tokens expire and are revoked, and disconnecting must not delete a year of bodyweight.
  module WithingsConnection
    module_function

    def of(account_id) = DB[:account_withings].where(account_id:).first
    def connected?(account_id) = !of(account_id).nil?

    # Stores what an exchange or a refresh returned. Withings answers with `expires_in`
    # seconds rather than an instant, so the instant is computed here once -- a column
    # holding "3600" would be meaningless the moment it was read.
    #
    # An upsert rather than an insert, because reconnecting is the ordinary way to recover
    # from a revoked grant and must replace the dead tokens rather than race them.
    def store(account_id, tokens)
      row = { access_token: tokens['access_token'], refresh_token: tokens['refresh_token'],
              expires_at: Time.now + tokens.fetch('expires_in', 0).to_i,
              withings_user_id: tokens['userid']&.to_s }
      DB[:account_withings].insert_conflict(target: :account_id, update: row)
                           .insert(account_id:, connected_at: Time.now, **row)
    end

    # Disconnecting forgets the permission and keeps the measurements. They are a record of
    # what the lifter weighed, which is true whether or not the app may still ask.
    def forget(account_id) = DB[:account_withings].where(account_id:).delete

    # A token good for the next call, refreshing first where the one on hand is spent.
    #
    # Nil where there is no connection, and nil where the refresh failed -- which is the case
    # that matters, because a refresh token can be revoked from Withings' own app and the
    # only way the lifter finds out is that readings stop arriving. A caller getting nil
    # should say the connection needs renewing rather than retry.
    #
    # Refreshed EARLY seconds before expiry so a call cannot be issued with a token that dies
    # in flight.
    def token(account_id)
      row = of(account_id)
      return nil unless row
      return row[:access_token] if row[:expires_at] > Time.now + Withings::EARLY

      renew(account_id, row)
    end

    def renew(account_id, row)
      tokens = Withings.refresh(row[:refresh_token])
      return nil unless tokens

      store(account_id, tokens)
      tokens['access_token']
    end

    # What the settings page says. A hash rather than the row, because the page needs to tell
    # three states apart -- never connected, connected, and connected but expired -- and the
    # third is not visible from the row's presence alone.
    def status(account_id)
      row = of(account_id)
      return { state: :absent } unless row

      { state: row[:expires_at] > Time.now ? :live : :stale,
        connected_at: row[:connected_at], synced_at: row[:synced_at] }
    end
  end
end

