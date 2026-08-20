# frozen_string_literal: true

require 'securerandom'

class Tectonic < Roda
  module OAuth
    # How long one consent may live no matter how often it is refreshed. Past this the
    # client has to ask the user again.
    GRANT_LIFETIME = 90 * 86_400

    # One authorization grant: the single consent a user gave, and everything every token
    # descended from it is bound to. A rotation chain shares an id, so reuse detection can
    # revoke the family rather than only the row that was replayed, and shares an absolute
    # expires_at that rotation copies forward untouched, so refreshing forever cannot
    # stretch one consent past its deadline.
    Grant = Struct.new(:id, :account_id, :client_id, :scopes, :resource, :expires_at,
                       keyword_init: true) do
      # Opens a new grant at the moment a code is redeemed.
      def self.start(account_id:, client_id:, scopes:, resource:)
        new(id: SecureRandom.urlsafe_base64(16), account_id:, client_id:, scopes:,
            resource:, expires_at: Time.now + GRANT_LIFETIME)
      end
    end
  end
end

