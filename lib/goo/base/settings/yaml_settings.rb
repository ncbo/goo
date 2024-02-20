require 'yaml'

module Goo
  module Base
    module Settings
      module YAMLScheme
        attr_reader :yaml_settings

        def init_yaml_scheme_settings
          scheme_file_path = @model_settings[:scheme]
          @yaml_settings = read_yaml_settings_file(scheme_file_path)
        end

        def attribute_yaml_settings(attr)

          return {} if yaml_settings.nil?

          yaml_settings[attr.to_sym]
        end



        private

        def load_yaml_scheme_options(attr)
          settings = attribute_settings(attr)
          yaml_settings = attribute_yaml_settings(attr)
          settings.merge! yaml_settings unless yaml_settings.nil? || yaml_settings.empty?
        end

        def read_yaml_settings_file(scheme_file_path)
          return  if scheme_file_path.nil?

          yaml_contents = File.read(scheme_file_path) rescue return

          YAML.safe_load(yaml_contents, symbolize_names: true)
        end
      end
    end
  end
end




