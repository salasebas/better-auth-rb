# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def dub(options = {})
      config = normalize_hash(options)
      oauth_plugin = dub_oauth_plugin(config[:oauth])
      endpoints = {dub_link: dub_link_endpoint(oauth_plugin)}
      endpoints[:dub_oauth2_callback] = oauth_plugin.endpoints.fetch(:oauth2_callback) if oauth_plugin

      Plugin.new(
        id: "dub",
        endpoints: endpoints,
        init: ->(_context) {
          {
            options: {
              database_hooks: {
                user: {
                  create: {
                    after: ->(user, ctx) { dub_track_lead(config, user, ctx) }
                  }
                }
              }
            }
          }
        },
        options: config
      )
    end

    def dub_link_endpoint(oauth_plugin)
      Endpoint.new(
        path: "/dub/link",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "dubLink",
            description: "Link a Dub OAuth account",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  callbackURL: {type: "string", description: "The URL to redirect to after linking"},
                  callback_url: {type: "string", description: "The URL to redirect to after linking"}
                }
              )
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "Authorization URL generated successfully for linking a Dub account",
                OpenAPI.object_schema(
                  {
                    url: {type: "string"},
                    redirect: {type: "boolean"}
                  },
                  required: ["url", "redirect"]
                )
              )
            }
          }
        }
      ) do |ctx|
        unless oauth_plugin
          raise APIError.new("NOT_FOUND", message: "Dub OAuth is not configured")
        end

        body = normalize_hash(ctx.body)
        callback_url = body[:callback_url] || body[:callbackURL]
        if callback_url.to_s.empty?
          raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["VALIDATION_ERROR"])
        end
        Routes.validate_auth_callback_url!(ctx.context, callback_url, "callbackURL")

        ctx.body = body.merge(provider_id: "dub", callback_url: callback_url)
        oauth_plugin.endpoints.fetch(:oauth2_link_account).call(ctx)
      end
    end

    def dub_oauth_plugin(oauth_options)
      oauth = normalize_hash(oauth_options || {})
      return nil if oauth.empty?

      generic_oauth(
        config: [
          {
            provider_id: "dub",
            authorization_url: "https://app.dub.co/oauth/authorize",
            token_url: "https://api.dub.co/oauth/token",
            client_id: oauth[:client_id],
            client_secret: oauth[:client_secret],
            pkce: oauth.key?(:pkce) ? oauth[:pkce] : true
          }
        ]
      )
    end

    def dub_track_lead(config, user, ctx)
      return unless ctx

      dub_id = ctx.get_cookie("dub_id")
      return if dub_id.to_s.empty?
      return if config[:disable_lead_tracking]

      custom = config[:custom_lead_track]
      if custom.respond_to?(:call)
        custom.call(user, ctx)
      else
        dub_default_lead_track(config, user, dub_id, ctx)
      end

      ctx.set_cookie("dub_id", "", expires: Time.at(0), max_age: 0)
    end

    def dub_default_lead_track(config, user, dub_id, ctx)
      track = config[:dub_client]&.track
      return unless track&.respond_to?(:lead)

      dub_invoke_lead(
        track,
        click_id: dub_id,
        event_name: config[:lead_event_name] || "Sign Up",
        customer_external_id: fetch_value(user, "id"),
        customer_name: fetch_value(user, "name"),
        customer_email: fetch_value(user, "email"),
        customer_avatar: fetch_value(user, "image")
      )
    rescue => error
      dub_log_error(ctx, error)
    end

    def dub_log_error(ctx, error)
      logger = ctx.context.logger
      if logger.respond_to?(:error)
        logger.error(error)
      elsif logger.respond_to?(:call)
        logger.call(:error, error)
      end
    end

    def dub_invoke_lead(track, payload)
      if track.method(:lead).parameters.any? { |type, name| [:key, :keyreq].include?(type) && name == :request }
        track.lead(request: dub_lead_request_body(payload))
      else
        track.lead(payload)
      end
    end

    def dub_lead_request_body(payload)
      klass = defined?(::OpenApiSDK::Models::Operations::TrackLeadRequestBody) && ::OpenApiSDK::Models::Operations::TrackLeadRequestBody
      return payload unless klass

      klass.new(**payload)
    end
  end
end
