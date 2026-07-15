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

    # Fields Solr requires (or manages itself) that must never be deleted or re-added.
    PROTECTED_FIELDS = %w[id _version_ _text_].freeze

    # Rebuild the collection schema in a SINGLE Schema API request. Solr applies
    # all commands in one request as one atomic schema update: either the new
    # schema (deletes + adds) lands completely, or nothing changes. The previous
    # implementation issued the deletes in four separate requests followed by
    # the adds in a fifth; a failure or interruption in between left the
    # collection permanently half-configured (e.g. copyField rules whose *_str
    # dest dynamicField no longer existed — fatal at document-add time in
    # data-driven mode), poisoning every later run that trusted the collection.
    def init_schema(generator = schema_generator, clear_data: false)
      clear_all_data if clear_data
      fetch_schema

      # Fields that survive the clear (see clear_schema_commands) must not be re-added.
      surviving_fields = all_fields.map { |f| f['name'] } & PROTECTED_FIELDS

      # Command order matters: within one request Solr executes commands in
      # order, so deletes go first (copy fields before the fields they
      # reference, field types last once nothing uses them) and adds follow
      # (field types before the fields that use them).
      commands = clear_schema_commands(generator)
      commands['add-field-type'] = generator.field_types_to_add
      commands['add-field'] = generator.fields_to_add.reject { |f| surviving_fields.include?(f[:name].to_s) }
      commands['add-dynamic-field'] = generator.dynamic_fields_to_add
      commands['add-copy-field'] = generator.copy_fields_to_add
      commands.reject! { |_action, list| list.nil? || list.empty? }

      update_schema(commands)
    end

    def custom_schema?
      @custom_schema
    end

    def enable_custom_schema
      @custom_schema = true
    end

    def clear_all_schema(generator = schema_generator)
      fetch_schema
      commands = clear_schema_commands(generator)
      upload_schema(commands) unless commands.empty?
      fetch_schema
    end

    # Delete commands to reset the current schema, in dependency order:
    # copy fields first (they reference fields/dynamic fields), field types
    # last (they can only be deleted once no field uses them). Returned as a
    # hash so callers can send them in ONE atomic request, alone
    # (clear_all_schema) or merged with the adds (init_schema).
    def clear_schema_commands(generator = schema_generator)
      init_ft = generator.field_types_to_add.map { |f| f[:name] }
      copy_fields = (all_copy_fields || []).map { |f| { source: f['source'], dest: f['dest'] } }
      fields = (all_fields || []).reject { |f| PROTECTED_FIELDS.include?(f['name']) }.map { |f| { name: f['name'] } }
      dynamic_fields = (all_dynamic_fields || []).map { |f| { name: f['name'] } }
      fields_types = (all_fields_types || []).select { |f| init_ft.include?(f['name']) }.map { |f| { name: f['name'] } }

      commands = {}
      commands['delete-copy-field'] = copy_fields unless copy_fields.empty?
      commands['delete-field'] = fields unless fields.empty?
      commands['delete-dynamic-field'] = dynamic_fields unless dynamic_fields.empty?
      commands['delete-field-type'] = fields_types unless fields_types.empty?
      commands
    end

    # Add anything the generator declares that is missing from the live
    # schema, in ONE atomic request, without deleting or altering anything
    # that already exists. This is the ONLY schema mutation permitted on a
    # collection that was not just created: live collections legitimately
    # carry fields the generator knows nothing about (Solr's data-driven mode
    # adds a schema field for every unknown document key), and a full rebuild
    # (init_schema) would drop them from the schema, silently breaking search
    # on them until a full reindex. Existing items with a divergent definition
    # are left untouched — that is a migration, not bootstrap repair.
    def repair_schema_additively(generator = schema_generator)
      current = fetch_schema
      fields = (current['fields'] || []).map { |f| f['name'] }
      dynamic_fields = (current['dynamicFields'] || []).map { |f| f['name'] }
      field_types = (current['fieldTypes'] || []).map { |f| f['name'] }
      copy_fields = (current['copyFields'] || []).map { |f| [f['source'], f['dest']] }

      missing_field_types = generator.field_types_to_add.reject { |f| field_types.include?(f[:name].to_s) }
      missing_fields = generator.fields_to_add.reject { |f| fields.include?(f[:name].to_s) }
      missing_dynamic_fields = generator.dynamic_fields_to_add.reject { |f| dynamic_fields.include?(f[:name].to_s) }
      missing_copy_fields = generator.copy_fields_to_add.flat_map do |cf|
        Array(cf[:dest]).reject { |dest| copy_fields.include?([cf[:source].to_s, dest.to_s]) }
                        .map { |dest| { source: cf[:source], dest: dest } }
      end

      commands = {}
      commands['add-field-type'] = missing_field_types unless missing_field_types.empty?
      commands['add-field'] = missing_fields unless missing_fields.empty?
      commands['add-dynamic-field'] = missing_dynamic_fields unless missing_dynamic_fields.empty?
      commands['add-copy-field'] = missing_copy_fields unless missing_copy_fields.empty?
      return if commands.empty?

      begin
        update_schema(commands)
      rescue StandardError
        # Several processes boot concurrently in production (API workers,
        # cron); when the same item is missing they race the same add-* and
        # the loser gets a 400 from Solr. If a concurrent repair already made
        # the schema whole, this process must not fail its boot over it.
        raise unless schema_matches_generator?(generator)
      end
    end

    # True when everything the generator declares is present in the live
    # schema (matched by name; definitions are not diffed). Diagnostic
    # counterpart of repair_schema_additively.
    def schema_matches_generator?(generator = schema_generator)
      current = fetch_schema
      fields = (current['fields'] || []).map { |f| f['name'] }
      dynamic_fields = (current['dynamicFields'] || []).map { |f| f['name'] }
      field_types = (current['fieldTypes'] || []).map { |f| f['name'] }
      copy_fields = (current['copyFields'] || []).map { |f| [f['source'], f['dest']] }

      expected_copy_fields = generator.copy_fields_to_add.flat_map do |cf|
        Array(cf[:dest]).map { |dest| [cf[:source].to_s, dest.to_s] }
      end

      generator.fields_to_add.all? { |f| fields.include?(f[:name].to_s) } &&
        generator.dynamic_fields_to_add.all? { |f| dynamic_fields.include?(f[:name].to_s) } &&
        generator.field_types_to_add.all? { |f| field_types.include?(f[:name].to_s) } &&
        expected_copy_fields.all? { |pair| copy_fields.include?(pair) }
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
