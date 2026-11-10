# frozen_string_literal: true

# A public OAuth client is registered without a secret. Found bumping rodauth-oauth.
#
# Claude and ChatGPT register here as public clients (token_endpoint_auth_method "none"): they
# run where a secret cannot be kept, which is what RFC 6749 section 2.1 means by public, and
# PKCE is what proves the token request came from whoever started the flow. Until rodauth-oauth
# 1.6.7 dynamic registration minted a client_secret for them anyway, which nothing ever checked.
# From 1.6.7 it does not -- "a client secret won't be generated for public clients"
# (doc/release_notes/1_6_7.md) -- and the insert then failed against 001's NOT NULL, refusing
# every registration. Every assistant connecting for the first time would have been turned away.
#
# So the column becomes nullable. Confidential clients still get a secret, as before; existing
# public clients keep the one they were given, which is harmless and simply never used.
Sequel.migration do
  up do
    alter_table(:oauth_applications) { set_column_allow_null :client_secret }
  end

  # Back to NOT NULL only after filling any secretless row, so a rollback cannot fail on rows the
  # newer code wrote. The filler is random and unusable: those clients never present a secret.
  down do
    from(:oauth_applications).where(client_secret: nil)
                             .update(client_secret: Sequel.function(:md5, Sequel.function(:random).cast(String)))
    alter_table(:oauth_applications) { set_column_not_null :client_secret }
  end
end

