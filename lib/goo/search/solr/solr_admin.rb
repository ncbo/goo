module SOLR
  module Administration

    def admin_url
      "#{@solr_url}/admin"
    end

    def solr_alive?
      collections_url = URI.parse("#{admin_url}/collections?action=CLUSTERSTATUS")
      http = Net::HTTP.new(collections_url.host, collections_url.port)
      request = Net::HTTP::Get.new(collections_url.request_uri)

      begin
        response = http.request(request)
        return response.code.eql?("200") && JSON.parse(response.body).dig("responseHeader", "status").eql?(0)
      rescue StandardError => e
        return false
      end
    end

    def fetch_all_collections
      response = admin_get('collections?action=LIST', 'fetch collections')

      collections = []
      if response.is_a?(Net::HTTPSuccess)
        collections = JSON.parse(response.body)['collections']
      end

      collections
    end

    def fetch_all_aliases
      response = admin_get('collections?action=LISTALIASES', 'fetch aliases')

      aliases = {}
      if response.is_a?(Net::HTTPSuccess)
        aliases = JSON.parse(response.body)['aliases'] || {}
      end

      aliases
    end

    def create_collection(name = @collection_name, num_shards = 1, replication_factor = 1)
      return if collection_exists?(name)
      admin_post("collections?action=CREATE&name=#{name}&numShards=#{num_shards}&replicationFactor=#{replication_factor}", 'create collection')
    end

    def delete_collection(collection_name = @collection_name)
      return unless collection_exists?(collection_name)
      admin_post("collections?action=DELETE&name=#{collection_name}", 'delete collection')
    end

    def collection_exists?(collection_name)
      fetch_all_collections.include?(collection_name.to_s)
    end

    def create_or_update_alias(alias_name, collections)
      target_collections = Array(collections).map(&:to_s).reject(&:empty?)
      raise ArgumentError, 'At least one collection must be provided to create an alias' if target_collections.empty?

      admin_post("collections?action=CREATEALIAS&name=#{alias_name}&collections=#{target_collections.join(',')}", 'create alias')
    end

    def delete_alias(alias_name)
      return unless alias_exists?(alias_name)

      admin_post("collections?action=DELETEALIAS&name=#{alias_name}", 'delete alias')
    end

    def alias_exists?(alias_name)
      fetch_all_aliases.key?(alias_name.to_s)
    end

    def resolve_alias(alias_name)
      aliased_collections = fetch_all_aliases[alias_name.to_s]
      return [] if aliased_collections.nil? || aliased_collections.empty?

      aliased_collections.split(',')
    end

    private

    def admin_get(path, action)
      admin_request(Net::HTTP::Get, path, action)
    end

    def admin_post(path, action)
      admin_request(Net::HTTP::Post, path, action)
    end

    def admin_request(request_klass, path, action)
      url = URI.parse("#{admin_url}/#{path}")
      http = Net::HTTP.new(url.host, url.port)
      request = request_klass.new(url.request_uri)

      begin
        response = http.request(request)
        raise StandardError, "Failed to #{action}. HTTP #{response.code}: #{response.message}" unless response.code.to_i == 200
      rescue StandardError => e
        raise StandardError, "Failed to #{action}. #{e.message}"
      end

      response
    end

  end
end
