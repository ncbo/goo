module Goo
  module SPARQL
    module Solution
      class  LanguageFilter

        attr_reader :requested_lang, :unmapped, :objects_by_lang

        def initialize(requested_lang: RequestStore.store[:requested_lang], unmapped: false, list_attributes: [])
          @list_attributes = list_attributes
          @objects_by_lang = {}
          @unmapped = unmapped
          @requested_lang = get_language(requested_lang)
        end

        def fill_models_with_all_languages(models_by_id)
          objects_by_lang.each do |id, predicates|
            model = models_by_id[id]
            predicates.each do |predicate, values|

              if values.values.all? { |v| v.all? { |x| literal?(x) && x.plain?} }
                pull_stored_values(model, values, predicate, @unmapped)
              end
            end
          end
        end


        def set_model_value(model, predicate, values, value)
          set_value(model, predicate, value) do
            model.send("#{predicate}=", values, on_load: true)
          end
        end

        def set_unmapped_value(model, predicate, value)
          set_value(model, predicate, value) do
            return add_unmapped_to_model(model, predicate, value)
          end
        end

        def models_unmapped_to_array(m)
          if show_all_languages?
            model_group_by_lang(m)
          else
            m.unmmaped_to_array
          end
        end

        private


        def set_value(model, predicate, value, &block)
          language = object_language(value)

          if requested_lang.eql?(:ALL) || !literal?(value) || language_match?(language)
            block.call
          end

          if requested_lang.eql?(:ALL) || requested_lang.is_a?(Array)
            language = "@none" if language.nil? || language.eql?(:no_lang)
            store_objects_by_lang(model.id, predicate, value, language)
          end
        end
        
        def model_group_by_lang(model)
          unmapped = model.unmapped
          cpy = {}

          unmapped.each do |attr, v|
            cpy[attr] = group_by_lang(v)
          end

          model.unmapped = cpy
        end

        def group_by_lang(values)

          return values.to_a if values.all?{|x| x.is_a?(RDF::URI) || !x.respond_to?(:language) }

          values = values.group_by { |x| x.respond_to?(:language) && x.language ? x.language.to_s.downcase : :none }

          no_lang = values[:none] || []
          return no_lang if !no_lang.empty? && no_lang.all? { |x| x.respond_to?(:plain?) && !x.plain? }

          values
        end


        def object_language(new_value)
          new_value.language || :no_lang if new_value.is_a?(RDF::Literal)
        end

        def language_match?(language)
          # no_lang means that the object is not a literal
          return true if language.eql?(:no_lang)

          return requested_lang.include?(language)  if requested_lang.is_a?(Array)

          language&.upcase.eql?(requested_lang)
        end

        def literal?(object)
          !object_language(object).nil?
        end

        def store_objects_by_lang(id, predicate, object, language)
          # store objects in this format: [id][predicate][language] = [objects]
          return if requested_lang.is_a?(Array) && !requested_lang.include?(language)

          language_key = language.downcase

          objects_by_lang[id] ||= {}
          objects_by_lang[id][predicate] ||= {}
          objects_by_lang[id][predicate][language_key] ||= []

          objects_by_lang[id][predicate][language_key] << object
        end


        def add_unmapped_to_model(model, predicate, value)

          if model.respond_to? :klass # struct
            model[:unmapped] ||= {}
            model[:unmapped][predicate] ||= []
            model[:unmapped][predicate]  << value unless value.nil?
          else
            model.unmapped_set(predicate, value)
          end
        end

        def pull_stored_values(model, values, predicate, unmapped)
          if unmapped
            add_unmapped_to_model(model, predicate, values)
          else
            values = values.map do  |language, values_literals|
              values_string = values_literals.map{|x| x.object}
              values_string = values_string.first unless list_attributes?(predicate)
              [language, values_string]
            end.to_h

            model.send("#{predicate}=", values, on_load: true)
          end

        end

        def unmapped_get(model, predicate)
          if model && model.respond_to?(:klass) # struct
            model[:unmapped]&.dig(predicate)
          else
            model.unmapped_get(predicate)
          end

        end

        def list_attributes?(predicate)
          @list_attributes.include?(predicate)
        end


        def show_all_languages?
          @requested_lang.is_a?(Array) || @requested_lang.eql?(:ALL)
        end

        def get_language(languages)
          languages = portal_language if languages.nil? || languages.empty?
          lang = languages.to_s.split(',').map { |l| l.upcase.to_sym }
          lang.length == 1 ? lang.first : lang
        end

        def portal_language
          Goo.main_languages.first
        end

      end
    end
  end
end
