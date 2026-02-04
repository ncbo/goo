module SOLR
  module Schema

    def fetch_schema
      uri = URI.parse("#{@solr_url}/#{@collection_name}/schema")
      http = Net::HTTP.new(uri.host, uri.port)

      request = Net::HTTP::Get.new(uri.path, 'Content-Type' => 'application/json')
      response = http.request(request)

      if response.code.to_i == 200
        @schema = JSON.parse(response.body)["schema"]
      else
        raise StandardError, "Failed to upload schema. HTTP #{response.code}: #{response.body}"
      end
    end

    def schema
      @schema ||= fetch_schema
    end

    def all_fields
      schema["fields"]
    end

    def all_copy_fields
      schema["copyFields"]
    end

    def all_dynamic_fields
      schema["dynamicFields"]
    end

    def all_fields_types
      schema["fieldTypes"]
    end

    def fetch_all_fields
      fetch_schema["fields"]
    end

    def fetch_all_copy_fields
      fetch_schema["copyFields"]
    end

    def fetch_all_dynamic_fields
      fetch_schema["dynamicFields"]
    end

    def fetch_all_fields_types
      fetch_schema["fieldTypes"]
    end

    def schema_generator
      @schema_generator ||= SolrSchemaGenerator.new
    end

    def init_collection(num_shards = 1, replication_factor = 1)
      create_collection_url = URI.parse("#{@solr_url}/admin/collections?action=CREATE&name=#{@collection_name}&numShards=#{num_shards}&replicationFactor=#{replication_factor}")

      http = Net::HTTP.new(create_collection_url.host, create_collection_url.port)
      request = Net::HTTP::Post.new(create_collection_url.request_uri)

      begin
        response = http.request(request)
        raise StandardError, "Failed to create collection. HTTP #{response.code}: #{response.message}" unless response.code.to_i == 200
      rescue StandardError => e
        raise StandardError, "Failed to create collection. #{e.message}"
      end
    end

    def init_schema(generator = schema_generator)
      clear_all_schema(generator)
      fetch_schema
      default_fields = all_fields.map { |f| f['name'] }

      solr_schema = {
        "add-field-type": generator.field_types_to_add,
        'add-field' => generator.fields_to_add.reject { |f| default_fields.include?(f[:name]) },
        'add-dynamic-field' => generator.dynamic_fields_to_add,
        'add-copy-field' => generator.copy_fields_to_add
      }

      update_schema(solr_schema)
    end

    def custom_schema?
      @custom_schema
    end

    def enable_custom_schema
      @custom_schema = true
    end

    def clear_all_schema(generator = schema_generator)
      init_ft = generator.field_types_to_add.map { |f| f[:name] }
      dynamic_fields = all_dynamic_fields.map { |f| { name: f['name'] } }
      copy_fields = all_copy_fields.map { |f| { source: f['source'], dest: f['dest'] } }
      fields_types = all_fields_types.select { |f| init_ft.include?(f['name']) }.map { |f| { name: f['name']} }
      fields = all_fields.reject { |f| %w[id _version_ ].include?(f['name']) }.map { |f| { name: f['name'] } }
      
      upload_schema('delete-copy-field' => copy_fields) unless copy_fields.empty?
      upload_schema('delete-dynamic-field' => dynamic_fields) unless dynamic_fields.empty?
      upload_schema('delete-field' => fields) unless copy_fields.empty?
      upload_schema('delete-field-type' => fields_types) unless fields_types.empty?
    end

    def map_to_indexer_type(orm_data_type)
      case orm_data_type
      when :uri, :url
        'string' # Assuming a string field for URIs
      when :string, nil # Default to 'string' if no type is given
        'text_general' # Assuming a generic text field for strings
      when :integer
        'pint'
      when :boolean
        'boolean'
      when :date_time
        'pdate'
      when :float
        'pfloat'
      else
        # Handle unknown data types or raise an error based on your specific requirements
        raise ArgumentError, "Unsupported ORM data type: #{orm_data_type}"
      end
    end

    def delete_field(name)
      update_schema('delete-field' => [
        { name: name }
      ])
    end

    def add_field(name, type, indexed: true, stored: true, multi_valued: false)
      update_schema('add-field' => [
        { name: name, type: type, indexed: indexed, stored: stored, multiValued: multi_valued }
      ])
    end

    def add_dynamic_field(name, type, indexed: true, stored: true, multi_valued: false)
      update_schema('add-dynamic-field' => [
        { name: name, type: type, indexed: indexed, stored: stored, multiValued: multi_valued }
      ])
    end

    def add_copy_field(source, dest)
      update_schema('add-copy-field' => [
        { source: source, dest: dest }
      ])
    end

    def fetch_field(name)
      fetch_all_fields.select { |f| f['name'] == name }.first
    end

    def update_schema(schema_json)
      permitted_actions = %w[add-field add-copy-field add-dynamic-field add-field-type delete-copy-field delete-dynamic-field delete-field delete-field-type]

      unless permitted_actions.any? { |action| schema_json.key?(action) }
        raise StandardError, "The schema need to implement at least one of this actions: #{permitted_actions.join(', ')}"
      end
      upload_schema(schema_json)
      fetch_schema
    end

    private

    def upload_schema(schema_json)
      uri = URI.parse("#{@solr_url}/#{@collection_name}/schema")
      http = Net::HTTP.new(uri.host, uri.port)

      request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
      request.body = schema_json.to_json
      response = http.request(request)
      if response.code.to_i == 200
        response
      else
        raise StandardError, "Failed to upload schema. HTTP #{response.code}: #{response.body}"
      end
    end

  end
end

