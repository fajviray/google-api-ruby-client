# Copyright 2015 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'addressable/uri'
require 'addressable/template'
require 'google/apis/options'
require 'google/apis/errors'
require 'retriable'
require 'google/apis/core/logging'
require 'pp'

module Google
  module Apis
    module Core
      # Command for HTTP request/response.
      class HttpCommand
        include Logging

        RETRIABLE_ERRORS = [Google::Apis::ServerError, Google::Apis::RateLimitError, Google::Apis::TransmissionError]

        # Request options
        # @return [Google::Apis::RequestOptions]
        attr_accessor :options

        # HTTP request URL
        # @return [String, Addressable::URI]
        attr_accessor :url

        # HTTP headers
        # @return [Hash]
        attr_accessor :header

        # Request body
        # @return [#read]
        attr_accessor :body

        # HTTP method
        # @return [symbol]
        attr_accessor :method

        # HTTP Client
        # @return [HTTPClient]
        attr_accessor :connection

        # Query params
        # @return [Hash]
        attr_accessor :query

        # Path params for URL Template
        # @return [Hash]
        attr_accessor :params

        # @param [symbol] method
        #   HTTP method
        # @param [String,Addressable::URI, Addressable::Template] url
        #   HTTP URL or template
        # @param [String, #read] body
        #   Request body
        def initialize(method, url, body: nil)
          self.options = Google::Apis::RequestOptions.default.dup
          self.url = url
          self.url = Addressable::Template.new(url) if url.is_a?(String)
          self.method = method
          self.header = Hash.new
          self.body = body
          self.query = {}
          self.params = {}
        end

        # Execute the command, retrying as necessary
        #
        # @param [HTTPClient] client
        #   HTTP client
        # @yield [result, err] Result or error if block supplied
        # @return [Object]
        # @raise [Google::Apis::ServerError] An error occurred on the server and the request can be retried
        # @raise [Google::Apis::ClientError] The request is invalid and should not be retried without modification
        # @raise [Google::Apis::AuthorizationError] Authorization is required
        def execute(client)
          prepare!
          begin
            Retriable.retriable tries: options.retries + 1,
                                base_interval: 1,
                                multiplier: 2,
                                on: RETRIABLE_ERRORS do |try|
              # This 2nd level retriable only catches auth errors, and supports 1 retry, which allows
              # auth to be re-attempted without having to retry all sorts of other failures like
              # NotFound, etc
              auth_tries = (try == 1 && authorization_refreshable? ? 2 : 1)
              Retriable.retriable tries: auth_tries,
                                  on: [Google::Apis::AuthorizationError],
                                  on_retry: proc { |*| refresh_authorization } do
                execute_once(client).tap do |result|
                  if block_given?
                    yield result, nil
                  end
                end
              end
            end
          rescue => e
            if block_given?
              yield nil, e
            else
              raise e
            end
          end
        ensure
          release!
        end

        # Refresh the authorization authorization after a 401 error
        #
        # @private
        # @return [void]
        def refresh_authorization
          # Handled implicitly by auth lib, here in case need to override
          logger.debug('Retrying after authentication failure')
        end

        # Check if attached credentials can be automatically refreshed
        # @return [Boolean]
        def authorization_refreshable?
          options.authorization.respond_to?(:apply!)
        end

        # Prepare the request (e.g. calculate headers, serialize data, etc) before sending
        #
        # @private
        # @return [void]
        def prepare!
          header.update(options.header) if options && options.header
          self.url = url.expand(params) if url.is_a?(Addressable::Template)
          url.query_values = query.merge(url.query_values || {})

          if [:post, :put].include?(method)  && body.nil?
            @form_encoded = true
            self.body = Addressable::URI.form_encode(url.query_values(Array))
            self.header['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8'
            self.url.query_values = {}
          else
            @form_encoded = false
          end
        end

        # Release any resources used by this command
        # @private
        # @return [void]
        def release!
        end

        # Check the response and either decode body or raise error
        #
        # @param [Fixnum] status
        #   HTTP status code of response
        # @param [Hash] header
        #   Response headers
        # @param [String, #read] body
        #  Response body
        # @return [Object]
        #   Response object
        # @raise [Google::Apis::ServerError] An error occurred on the server and the request can be retried
        # @raise [Google::Apis::ClientError] The request is invalid and should not be retried without modification
        # @raise [Google::Apis::AuthorizationError] Authorization is required
        def process_response(status, header, body)
          check_status(status, header, body)
          decode_response_body(header['Content-Type'].first, body)
        end

        # Check the response and raise error if needed
        #
        # @param [Fixnum] status
        #   HTTP status code of response
        # @param
        # @param [Hash] header
        #   HTTP response headers
        # @param [String] body
        #   HTTP response body
        # @param [String] message
        #   Error message text
        # @return [void]
        # @raise [Google::Apis::ServerError] An error occurred on the server and the request can be retried
        # @raise [Google::Apis::ClientError] The request is invalid and should not be retried without modification
        # @raise [Google::Apis::AuthorizationError] Authorization is required
        def check_status(status, header = nil, body = nil, message = nil)
          # TODO: 304 Not Modified depends on context...
          case status
          when 200...300
            nil
          when 301, 302, 303, 307
            message ||= sprintf('Redirect to %s', header['Location'])
            raise Google::Apis::RedirectError.new(message, status_code: status, header: header, body: body)
          when 401
            message ||= 'Unauthorized'
            raise Google::Apis::AuthorizationError.new(message, status_code: status, header: header, body: body)
          when 429
            message ||= 'Rate limit exceeded'
            raise Google::Apis::RateLimitError.new(message, status_code: status, header: header, body: body)
          when 304, 400, 402...500
            message ||= 'Invalid request'
            raise Google::Apis::ClientError.new(message, status_code: status, header: header, body: body)
          when 500...600
            message ||= 'Server error'
            raise Google::Apis::ServerError.new(message, status_code: status, header: header, body: body)
          else
            logger.warn(sprintf('Encountered unexpected status code %s', status))
            message ||= 'Unknown error'
            raise Google::Apis::TransmissionError.new(message, status_code: status, header: header, body: body)
          end
        end

        # Process the actual response body. Intended to be overridden by subclasses
        #
        # @param [String] _content_type
        #  Content type of body
        # @param [String, #read] body
        #  Response body
        # @return [Object]
        def decode_response_body(_content_type, body)
          body
        end

        # Process a success response
        # @param [Object] result
        #  Result object
        # @return [Object] result if no block given
        # @yield [result, nil] if block given
        def success(result, &block)
          logger.debug { sprintf('Success - %s', PP.pp(result, '')) }
          block.call(result, nil) if block_given?
          result
        end

        # Process an error response
        # @param [StandardError] err
        #  Error object
        # @param [Boolean] rethrow
        #  True if error should be raised again after handling
        # @return [void]
        # @yield [nil, err] if block given
        # @raise [StandardError] if no block
        def error(err, rethrow: false, &block)
          logger.debug { sprintf('Error - %s', PP.pp(err, '')) }
          if err.is_a?(HTTPClient::BadResponseError)
            begin
              res = err.res
              check_status(res.status.to_i, res.header, res.body)
            rescue Google::Apis::Error => e
              err = e
            end
          elsif err.is_a?(HTTPClient::TimeoutError) || err.is_a?(SocketError)
            err = Google::Apis::TransmissionError.new(err)
          end
          block.call(nil, err) if block_given?
          fail err if rethrow || block.nil?
        end

        # Execute the command once.
        #
        # @private
        # @param [HTTPClient] client
        #   HTTP client
        # @return [Object]
        # @raise [Google::Apis::ServerError] An error occurred on the server and the request can be retried
        # @raise [Google::Apis::ClientError] The request is invalid and should not be retried without modification
        # @raise [Google::Apis::AuthorizationError] Authorization is required
        def execute_once(client)
          body.rewind if body.respond_to?(:rewind)
          begin
            logger.debug { sprintf('Sending HTTP %s %s', method, url) }
            request_header = header.dup
            apply_request_options(request_header)

            http_res = client.request(method.to_s.upcase,
                                      url.to_s,
                                      query: nil,
                                      body: body,
                                      header: request_header,
                                      follow_redirect: true)
            logger.debug { http_res.status }
            logger.debug { http_res.inspect }
            response = process_response(http_res.status.to_i, http_res.header, http_res.body)
            success(response)
          rescue => e
            logger.debug { sprintf('Caught error %s', e) }
            error(e, rethrow: true)
          end
        end

        # Update the request with any specified options.
        # @param [Hash] header
        #  HTTP headers
        # @return [void]
        def apply_request_options(req_header)
          if options.authorization.respond_to?(:apply!)
            options.authorization.apply!(req_header)
          elsif options.authorization.is_a?(String)
            req_header['Authorization'] = sprintf('Bearer %s', options.authorization)
          end
          req_header.update(header)
        end

        private

        def form_encoded?
          @form_encoded
        end

        def normalize_query_value(v)
          case v
          when Array
            v.map { |v2| normalize_query_value(v2) }
          when nil
            nil
          else
            v.to_s
          end
        end
      end
    end
  end
end
