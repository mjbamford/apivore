require 'apivore/rspec_matchers'
require 'action_controller'
require 'action_dispatch'
require 'rspec/mocks'
require 'hashie'

module Apivore
  module RspecBuilder
    include Apivore::RspecMatchers
    include ActionDispatch::Integration
    include RSpec::Mocks::ExampleMethods

    @@setups ||= {}

    @@master_swagger_uri = nil

    # Setup tests against a combination of path, method, and response.
    # - *keys -> A combination of path, method, and/or response. Blank '' for base setup.
    # - &block -> Code block to execute to setup the test. A hash of path subsitution parameters can be returned if required.
    # All matching code blocks are executed, and substitution parameters are merged in order of specificity.
    def apivore_setup(*keys, &block)
      @@setups[keys.join] = block
    end

    def get_apivore_setup(path, method, response)
      keys_to_search = [
        '', # base setup key
        response,
        method,
        path,
        method + response,
        path + response,
        path + method,
        path + method + response
      ]
      final_result = {}
      keys_to_search.each do |k|
        setup = @@setups[k]
        if setup
          result = instance_eval &setup
          final_result.merge!(result) if result.is_a?(Hash)
        end
      end
      final_result
    end

    def apivore_build_path(path, data)
      path.scan(/\{([^\}]*)\}/).each do |param|
        key = param.first
        if data && data[key]
          path = path.gsub "{#{key}}", data[key].to_s
        else
          raise URI::InvalidURIError, "No substitution data found for {#{key}} to test the path #{path}.\nAdd it via an:\n  apivore_setup '<path>', '<method>', '<response>' do\n    { '#{key}' => <value> }\n  end\nblock in your specs.", caller
        end
      end
      path + (data['_query_string'] ? "?#{data['_query_string']}" : '')
    end

    def apivore_check_consistency_with_swagger_at(uri, current_service = nil)
      @@current_service = current_service
      @@master_swagger_uri = uri
    end

    def apivore_swagger(swagger_path)
      session = ActionDispatch::Integration::Session.new(Rails.application)
      begin
        session.get swagger_path
      rescue
        # TODO: make this fail inside rspec test execution rather than immediately raise an exception.
        # ALSO, handle other scenarios where we can't get a response to generate tests, e.g 500s, invalid formats etc
        raise "Unable to perform GET request for swagger json: #{swagger_path} - #{$!}."
      end
      Apivore::Swagger.new JSON.parse(session.response.body)
    end

    def validate(swagger_path)

      describe "swagger documentation" do
        before { get swagger_path }
        subject { body }
        let(:master_swagger) {
          req = Net::HTTP.get(@@master_swagger_uri, "/swagger.json")
          master_swagger = JSON.parse(req)
        }

        it { should be_valid_swagger }
        it { should have_models_for_all_get_endpoints }
        if @@master_swagger_uri
          it { should be_consistent_with_swagger_definitions master_swagger, @@current_service }
        end
      end

      swagger = apivore_swagger(swagger_path)
      swagger.each_response do |path, method, response_code, fragment|
        describe "path #{path} method #{method} response #{response_code}" do
          it "responds with the specified models" do
            setup_data = get_apivore_setup(path, method, response_code)
            full_path = apivore_build_path(swagger.base_path + path, setup_data)
            # e.g., get(full_path)
            begin
              send(method, full_path, setup_data['_data'] || {}, setup_data['_headers'] || {})
            rescue
              raise "Unable to #{method} #{full_path} -- invalid response from server: #{$!}."
            end
            expect(response).to have_http_status(response_code), "expected #{response_code} array, got #{response.status}: #{response.body}"

            if fragment
              expect(response.body).to conform_to_the_documented_model_for(swagger, fragment)
            end

          end
        end
      end

    end
  end
end
