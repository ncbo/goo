module SOLR

  class SolrSchemaGenerator

    attr_reader :schema

    def initialize
      @schema = {}
    end

    def add_field(name, type, indexed: true, stored: true, multi_valued: false, omit_norms: nil, default: nil)
      @schema['add-field'] ||= []
      af = { name: name.to_s, type: type, indexed: indexed, stored: stored, multiValued: multi_valued}
      af[:omitNorms] = omit_norms unless omit_norms.nil?
      # Solr Schema API expects `default` as a STRING value; sending JSON booleans/numbers
      # can trigger ClassCastException on Solr side.
      af[:default] = default.is_a?(String) ? default : default.to_s unless default.nil?
      @schema['add-field'] << af
    end

    def add_dynamic_field(name, type, indexed: true, stored: true, multi_valued: false, omit_norms: nil)
      @schema['add-dynamic-field'] ||= []
      df = { name: name.to_s, type: type, indexed: indexed, stored: stored, multiValued: multi_valued }
      df[:omitNorms] = omit_norms unless omit_norms.nil?
      @schema['add-dynamic-field'] << df
    end

    def add_copy_field(source, dest)
      @schema['add-copy-field'] ||= []
      @schema['add-copy-field'] << { source: source, dest: dest }
    end

    def add_field_type(type_definition)
      @schema['add-field-type'] ||= []
      @schema['add-field-type'] << type_definition
    end

    def fields_to_add
      custom_fields = @schema['add-field'] || []
      custom_fields + init_fields
    end

    def dynamic_fields_to_add
      custom_fields = @schema['add-dynamic-field'] || []
      custom_fields + init_dynamic_fields
    end

    def copy_fields_to_add
      custom_fields = @schema['add-copy-field'] || []
      custom_fields + init_copy_fields
    end

    def field_types_to_add
      custom_fields = @schema['add-field-type'] || []
      custom_fields + init_fields_types
    end

    def init_fields_types
      [
        {
          "name": "string_ci",
          "class": "solr.TextField",
          "sortMissingLast": true,
          "omitNorms": true,
          "queryAnalyzer":
            {
              "tokenizer": {
                "class": "solr.KeywordTokenizerFactory"
              },
              "filters": [
                {
                  "class": "solr.LowerCaseFilterFactory"
                }
              ]
            }
        },
        {
          "name": "text_suggest_ngram",
          "class": "solr.TextField",
          "positionIncrementGap": "100",
          "indexAnalyzer": {
            "tokenizer": {
              "class": "solr.StandardTokenizerFactory"
            },
            "filters": [
              {
                "class": "solr.LowerCaseFilterFactory"
              },
              {
                "class": "solr.ASCIIFoldingFilterFactory"
              },
              {
                "class": "solr.WordDelimiterGraphFilterFactory",
                "generateWordParts": "1",
                "generateNumberParts": "1",
                "catenateWords": "0",
                "catenateNumbers": "0",
                "catenateAll": "0",
                "splitOnCaseChange": "1"
              },
              {
                "class": "solr.EdgeNGramFilterFactory",
                "minGramSize": 1,
                "maxGramSize": 20
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "([^\\w\\d\\*æøåÆØÅ ])",
                "replacement": "",
                "replace": "all"
              }
            ]
          },
          "queryAnalyzer": {
            "tokenizer": {
              "class": "solr.StandardTokenizerFactory"
            },
            "filters": [
              {
                "class": "solr.WordDelimiterGraphFilterFactory",
                "generateWordParts": "0",
                "generateNumberParts": "0",
                "catenateWords": "0",
                "catenateNumbers": "0",
                "catenateAll": "0",
                "splitOnCaseChange": "0"
              },
              {
                "class": "solr.LowerCaseFilterFactory"
              },
              {
                "class": "solr.ASCIIFoldingFilterFactory"
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "([^\\w\\d\\*æøåÆØÅ ])",
                "replacement": "",
                "replace": "all"
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "^(.{20})(.*)?",
                "replacement": "$1",
                "replace": "all"
              }
            ]
          }
        },
        {
          "name": "text_suggest_edge",
          "class": "solr.TextField",
          "positionIncrementGap": "100",
          "indexAnalyzer": {
            "tokenizer": {
              "class": "solr.KeywordTokenizerFactory"
            },
            "char_filters": [
              {
                "class": "solr.MappingCharFilterFactory",
                "mapping": "solr/resources/org/apache/lucene/analysis/miscellaneous/MappingCharFilter.greekaccent"
              }
            ],
            "filters": [
              {
                "class": "solr.LowerCaseFilterFactory"
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "([\\.,;:-_])",
                "replacement": " ",
                "replace": "all"
              },
              {
                "class": "solr.EdgeNGramFilterFactory",
                "minGramSize": 1,
                "maxGramSize": 30,
                "preserveOriginal": true
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "([^\\w\\d\\*æøåÆØÅ ])",
                "replacement": "",
                "replace": "all"
              }
            ]
          },
          "queryAnalyzer": {
            "tokenizer": {
              "class": "solr.KeywordTokenizerFactory"
            },
            "char_filters": [
              {
                "class": "solr.MappingCharFilterFactory",
                "mapping": "solr/resources/org/apache/lucene/analysis/miscellaneous/MappingCharFilter.greekaccent"
              }
            ],
            "filters": [
              {
                "class": "solr.LowerCaseFilterFactory"
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "([\\.,;:-_])",
                "replacement": " ",
                "replace": "all"
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "([^\\w\\d\\*æøåÆØÅ ])",
                "replacement": "",
                "replace": "all"
              }
            ]
          }
        },
        {
          "name": "text_suggest",
          "class": "solr.TextField",
          "positionIncrementGap": 100,
          indexAnalyzer: {
            "char_filters": [
              {
                "class": "solr.MappingCharFilterFactory",
                "mapping": "solr/resources/org/apache/lucene/analysis/miscellaneous/MappingCharFilter.greekaccent"
              }
            ],
            "tokenizer": {
              "class": "solr.StandardTokenizerFactory"
            },
            "filters": [
              {
                "class": "solr.WordDelimiterGraphFilterFactory",
                "generateWordParts": "1",
                "generateNumberParts": "1",
                "catenateWords": "1",
                "catenateNumbers": "1",
                "catenateAll": "1",
                "splitOnCaseChange": "1",
                "splitOnNumerics": "1",
                "preserveOriginal": "1"
              },
              {
                "class": "solr.LowerCaseFilterFactory"
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "([^\w\d*æøåÆØÅ ])",
                "replacement": " ",
                "replace": "all"
              }
            ]
          },
          queryAnalyzer: {
            "char_filters": [
              {
                "class": "solr.MappingCharFilterFactory",
                "mapping": "solr/resources/org/apache/lucene/analysis/miscellaneous/MappingCharFilter.greekaccent"
              }
            ],
            "tokenizer": {
              "class": "solr.StandardTokenizerFactory"
            },
            "filters": [
              {
                "class": "solr.WordDelimiterGraphFilterFactory",
                "generateWordParts": "0",
                "generateNumberParts": "0",
                "catenateWords": "0",
                "catenateNumbers": "0",
                "catenateAll": "0",
                "splitOnCaseChange": "0"
              },
              {
                "class": "solr.LowerCaseFilterFactory"
              },
              {
                "class": "solr.PatternReplaceFilterFactory",
                "pattern": "([^\w\d*æøåÆØÅ ])",
                "replacement": " ",
                "replace": "all"
              }
            ]
          }
        }
      ]
    end

    def init_fields
      [
        #{ name: "_version_", type: "plong", indexed: true, stored: true, multiValued: false },
        { name: "resource_id", type: "string_ci", indexed: true, multiValued: false, required: true, stored: true },
        { name: "resource_model", type: "string", indexed: true, multiValued: false, required: true, stored: false },
        { name: "_text_", type: "text_general", indexed: true, multiValued: true, stored: false },
      ]
    end

    def init_dynamic_fields
      [
        {"name": "*_t", "type": "text_general", stored: true, "multiValued": false },
        {"name": "*_txt", "type": "text_general", stored: true, "multiValued": true},
        {"name": "*_i", "type": "pint", stored: true },
        {"name": "*_is", "type": "pints", stored: true },
        {"name": "*_f", "type": "pfloat", stored: true },
        {"name": "*_fs", "type": "pfloats", stored: true },
        {"name": "*_b", "type": "boolean", stored: true },
        {"name": "*_bs", "type": "booleans", stored: true },
        {"name": "*_dt", "type": "pdate", stored: true },
        {"name": "*_dts", "type": "pdate", stored: true , multiValued: true},
        { "name": "*Exact", "type": "string_ci", "multiValued": true, stored: false },
        { "name": "*Suggest", "type": "text_suggest", "omitNorms": true, stored: false, "multiValued": true },
        { "name": "*SuggestEdge", "type": "text_suggest_edge", stored: false, "multiValued": true },
        { "name": "*SuggestNgram", "type": "text_suggest_ngram", stored: false, "omitNorms": true, "multiValued": true },
        { "name": "*_text", "type": "text_general", stored: true, "multiValued": false },
        { "name": "*_texts", "type": "text_general", stored: true, "multiValued": true },
        {"name": "*_sort", "type": "string", stored: false },
        {"name": "*_sorts", "type": "strings", stored: false , "multiValued": true},
      ]
    end

    def init_copy_fields
      [
        { source: "*_text", dest: %w[_text_ *Exact *Suggest *SuggestEdge *SuggestNgram *_sort] },
        { source: "*_texts", dest: %w[_text_ *Exact *Suggest *SuggestEdge *SuggestNgram *_sorts] },
      ]
    end
  end
end
